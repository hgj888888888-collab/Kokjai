# -*- coding: utf-8 -*-
r"""
W1 延迟交付风险预警，机器学习模型训练脚本。

输入：bishe_dws.dws_order_wide 的 TSV 导出文件（订单宽表，一个订单一行）。
导出 SQL（在虚拟机内执行，字段顺序必须与本文件 COLUMNS 一致）：

    USE bishe_dws;
    INSERT OVERWRITE LOCAL DIRECTORY '/tmp/w1_export'
    ROW FORMAT DELIMITED FIELDS TERMINATED BY '\001'
    STORED AS TEXTFILE
    SELECT order_id, order_datetime, ... , days_for_shipping_real, dt
    FROM dws_order_wide;

导出文件落在 hive-server 容器内，用 docker cp 取出后再 scp 到本机。

硬约束：
  1. 按 order_datetime 时序切分，2015 至 2016 年训练，2017 至 2018 年测试，严禁随机切分。
  2. 剔除 Late_delivery_risk、Delivery Status、Days for shipping (real) 三个结果字段，防止泄露。
  3. 类别不平衡，须设置类别权重；评估以 AUC、F1、Recall、Precision 为主，不看 Accuracy。
  4. 模型只会挑一份真正有区分度的信号，实测唯一有效信号是物流方式。
"""

import argparse
import os
import pickle
import sys

import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from xgboost import XGBClassifier

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# dws_order_wide 导出时的字段顺序，顺序不可改动
COLUMNS = [
    "order_id", "order_datetime", "order_year", "order_month", "order_day",
    "order_hour", "order_week", "order_weekday", "is_weekend", "time_period",
    "payment_type", "shipping_mode", "days_for_shipment_scheduled",
    "item_line_cnt", "product_cnt", "category_cnt", "department_cnt",
    "total_quantity", "total_sales", "total_discount", "total_net_amount",
    "avg_item_price", "benefit_per_order", "main_category_name",
    "main_department_name", "customer_id", "market", "order_region",
    "order_country", "order_state", "order_city", "latitude", "longitude",
    "amount_level", "late_delivery_risk", "days_for_shipping_real", "dt",
]

TARGET = "late_delivery_risk"

# 泄露字段与不可用字段：标签本身、结果字段、时间切分变量、纯标识
LEAK_COLUMNS = ["late_delivery_risk", "days_for_shipping_real", "delivery_status"]
ID_COLUMNS = ["order_id", "customer_id", "order_datetime", "order_year", "dt"]

# days_for_shipment_scheduled 与 shipping_mode 一一映射，只保留 shipping_mode
# order_country、order_state、order_city 为高基数类别（独热后 2779 列），
# 实测对 AUC 无正贡献（2016 验证集 0.7640 对 0.7666），不纳入模型特征，仅用于看板展示
CATEGORICAL = [
    "time_period", "payment_type", "shipping_mode", "main_category_name",
    "main_department_name", "market", "order_region", "amount_level",
]
NUMERIC = [
    "order_month", "order_day", "order_hour", "order_week", "order_weekday",
    "is_weekend", "item_line_cnt", "product_cnt", "category_cnt",
    "department_cnt", "total_quantity", "total_sales", "total_discount",
    "total_net_amount", "avg_item_price", "benefit_per_order", "latitude",
    "longitude",
]

TRAIN_END = "2017-01-01"

# 仓库回写用的滚动向前区间划分。
# 主指标仍取严格时序切分（2015 至 2016 训练、2017 至 2018 测试），
# 但要把概率写回全量 65,752 个订单时，不能直接用那一个模型：
# 它见过 2015 至 2016 年订单的答案，给这些订单打出的概率是过拟合值（接近 0 或 1），
# 会让下游预警命中率虚高。改为滚动向前，每个区间只用它之前的数据训练，
# 最早 3 个月没有更早的历史可用，记为冷启动，由 ADS 层用物流方式历史延迟率兜底。
COLD_START_END = "2015-04-01"
WALK_FORWARD_BOUNDS = [
    "2015-04-01", "2015-10-01", "2016-04-01", "2016-10-01",
    "2017-04-01", "2017-10-01", "2018-02-01",
]


def load_orders(path):
    """读取订单宽表导出文件。空值在 Hive 侧写成反斜杠加 N。"""
    df = pd.read_csv(
        path,
        sep="\x01",
        header=None,
        names=COLUMNS,
        engine="python",
        na_values=["\\N"],
        dtype={"order_id": str, "customer_id": str, "dt": str},
    )
    df["order_datetime"] = pd.to_datetime(df["order_datetime"], errors="coerce")
    return df


def build_pipeline(model):
    return Pipeline([
        ("prep", ColumnTransformer([
            ("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=True), CATEGORICAL),
            ("num", "passthrough", NUMERIC),
        ])),
        ("clf", model),
    ])


def evaluate(name, model, x_train, y_train, x_test, y_test):
    pipeline = build_pipeline(model)
    pipeline.fit(x_train, y_train)
    prob = pipeline.predict_proba(x_test)[:, 1]
    pred = (prob >= 0.5).astype(int)
    row = {
        "model": name,
        "auc": roc_auc_score(y_test, prob),
        "f1": f1_score(y_test, pred, zero_division=0),
        "precision": precision_score(y_test, pred, zero_division=0),
        "recall": recall_score(y_test, pred, zero_division=0),
    }
    print("  {model:<20} AUC {auc:.4f}  F1 {f1:.4f}  Precision {precision:.4f}  Recall {recall:.4f}".format(**row))
    return pipeline, row


def walk_forward_probabilities(df, features):
    """滚动向前打分，返回全量订单的延迟概率，冷启动区间的值为空。"""
    prob = np.full(len(df), np.nan)
    dt = df["order_datetime"].values
    bounds = [pd.Timestamp(x).to_datetime64() for x in WALK_FORWARD_BOUNDS]
    print("")
    print("滚动向前打分（每个区间只用它之前的数据训练）")
    for a, b in zip(bounds[:-1], bounds[1:]):
        fit_mask = dt < a
        pred_mask = (dt >= a) & (dt < b)
        if not pred_mask.any():
            continue
        model = build_pipeline(RandomForestClassifier(
            n_estimators=300, min_samples_leaf=2,
            class_weight="balanced_subsample", n_jobs=-1, random_state=42,
        ))
        model.fit(df.loc[fit_mask, features], df.loc[fit_mask, TARGET])
        prob[pred_mask] = model.predict_proba(df.loc[pred_mask, features])[:, 1]
        print("  {0} 至 {1}：训练 {2} 单，打分 {3} 单，概率均值 {4:.4f}".format(
            pd.Timestamp(a).strftime("%Y-%m"), pd.Timestamp(b).strftime("%Y-%m"),
            int(fit_mask.sum()), int(pred_mask.sum()), prob[pred_mask].mean()))
    cold = int((df["order_datetime"].values < np.datetime64(COLD_START_END)).sum())
    print("  冷启动区间（{0} 之前）{1} 单无历史模型可用，概率留空交由 ADS 层兜底".format(
        COLD_START_END[:7], cold))
    return prob


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        default=r"C:\Users\23916\AppData\Local\Temp\bishe_analysis\w1_order_wide.tsv",
    )
    parser.add_argument("--model-out", default=r"d:\bishe\w1_model.pkl")
    parser.add_argument(
        "--prob-out",
        default=r"C:\Users\23916\AppData\Local\Temp\bishe_analysis\w1_order_prob.csv",
    )
    args = parser.parse_args()

    df = load_orders(args.input)
    print("订单宽表读取完成，共 {0} 行 {1} 列".format(len(df), len(df.columns)))
    print("空标签行 {0} 行".format(int(df[TARGET].isna().sum())))
    df = df.dropna(subset=[TARGET])
    df[TARGET] = df[TARGET].astype(int)

    train_df = df[df["order_datetime"] < TRAIN_END]
    test_df = df[df["order_datetime"] >= TRAIN_END]
    print("训练集 {0} 单（{1} 至 {2}），延迟占比 {3:.1%}".format(
        len(train_df),
        train_df["order_datetime"].min().date(),
        train_df["order_datetime"].max().date(),
        train_df[TARGET].mean(),
    ))
    print("测试集 {0} 单（{1} 至 {2}），延迟占比 {3:.1%}".format(
        len(test_df),
        test_df["order_datetime"].min().date(),
        test_df["order_datetime"].max().date(),
        test_df[TARGET].mean(),
    ))

    features = CATEGORICAL + NUMERIC
    x_train, y_train = train_df[features], train_df[TARGET]
    x_test, y_test = test_df[features], test_df[TARGET]

    pos = int(y_train.sum())
    neg = int(len(y_train) - pos)
    scale_pos_weight = neg / pos

    print("")
    print("模型对比（训练集拟合、测试集评估）")
    results = []
    pipelines = {}

    pipeline, row = evaluate(
        "Logistic Regression",
        LogisticRegression(max_iter=2000, class_weight="balanced", random_state=42),
        x_train, y_train, x_test, y_test,
    )
    pipelines[row["model"]] = pipeline
    results.append(row)

    pipeline, row = evaluate(
        "Random Forest",
        RandomForestClassifier(
            n_estimators=300, max_depth=None, min_samples_leaf=2,
            class_weight="balanced_subsample", n_jobs=-1, random_state=42,
        ),
        x_train, y_train, x_test, y_test,
    )
    pipelines[row["model"]] = pipeline
    results.append(row)

    pipeline, row = evaluate(
        "XGBoost",
        XGBClassifier(
            n_estimators=300, max_depth=6, learning_rate=0.1,
            subsample=0.9, colsample_bytree=0.9, scale_pos_weight=scale_pos_weight,
            eval_metric="logloss", n_jobs=-1, random_state=42,
        ),
        x_train, y_train, x_test, y_test,
    )
    pipelines[row["model"]] = pipeline
    results.append(row)

    best = max(results, key=lambda r: r["auc"])
    # 与基线的选取口径保持一致：差距小于 0.005 视为噪声，优选可解释性更好的 Random Forest
    rf = next(r for r in results if r["model"] == "Random Forest")
    if rf["auc"] >= best["auc"] - 0.005:
        chosen = rf
    else:
        chosen = best

    print("")
    print("最优模型：{0}（AUC {1:.4f}，F1 {2:.4f}）".format(
        chosen["model"], chosen["auc"], chosen["f1"]))

    model = pipelines[chosen["model"]]
    with open(args.model_out, "wb") as fh:
        pickle.dump(
            {
                "model_name": chosen["model"],
                "pipeline": model,
                "features": features,
                "categorical": CATEGORICAL,
                "numeric": NUMERIC,
                "train_period": "2015-01-01 至 2016-12-31",
                "test_period": "2017-01-01 至 2018-01-31",
                "metrics": {r["model"]: {k: round(v, 4) for k, v in r.items() if k != "model"} for r in results},
            },
            fh,
        )
    print("模型已保存：{0}".format(args.model_out))

    prob = walk_forward_probabilities(df, features)
    filled = ~np.isnan(prob)
    out = pd.DataFrame({
        "order_id": df["order_id"].values,
        "late_prob": np.round(prob, 6),
        "y_true": df[TARGET].values,
        "split": np.where(df["order_datetime"].values < np.datetime64(TRAIN_END), "train", "test"),
    })
    out.to_csv(args.prob_out, index=False, encoding="utf-8")
    print("全量延迟概率已导出：{0}（{1} 行，其中 {2} 行有模型概率）".format(
        args.prob_out, len(out), int(filled.sum())))
    print("模型概率分布：均值 {0:.4f}，最小值 {1:.4f}，最大值 {2:.4f}".format(
        np.nanmean(prob), np.nanmin(prob), np.nanmax(prob)))


if __name__ == "__main__":
    main()
