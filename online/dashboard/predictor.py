# -*- coding: utf-8 -*-
"""W1 延迟交付风险模型的在线加载与实时预测。

模型文件由离线层的训练脚本 train_w1.py 序列化产出，内含完整管道
（类别独热加数值直通 + 随机森林），在线层直接加载该管道对单笔订单打分。
类别编码器设置了忽略未知类别，因此前端传入的新取值不会报错，
只会退化为该类别全部取零。

金额档位无法在单笔订单上复现离线层的三分位切分，故改用离线层实测出的
档位边界做常量判定，边界取自订单宽表各档取值范围。
"""

import pickle
import threading

from django.conf import settings

_lock = threading.Lock()
_cache = {"bundle": None}

# 订单金额档位边界，取自离线层订单宽表各档的取值范围（净额）
# 低档 7.49 至 314.25，中档 314.25 至 624.44，高档 624.44 至 2768.41
AMOUNT_BOUND_LOW = 314.25
AMOUNT_BOUND_HIGH = 624.44

# 与离线层一致的时段划分：凌晨 0 至 5、上午 6 至 11、下午 12 至 17、晚间 18 至 23
TIME_PERIOD_BANDS = [(0, 5, "凌晨"), (6, 11, "上午"), (12, 17, "下午"), (18, 23, "晚间")]

# 前端未填字段的兜底值，全部取自数据集的常见取值；
# 类别编码器忽略未知类别，故这些兜底值不会影响预测的健壮性
DEFAULTS = {
    "payment_type": "DEBIT",
    "shipping_mode": "Standard Class",
    "main_category_name": "Fishing",
    "main_department_name": "Fan Shop",
    "market": "Europe",
    "order_region": "Western Europe",
    "latitude": 0.0,
    "longitude": 0.0,
    "item_line_cnt": 1,
    "product_cnt": 1,
    "category_cnt": 1,
    "department_cnt": 1,
    "total_quantity": 1,
    "total_discount": 0.0,
    "benefit_per_order": 0.0,
}

SHIPPING_MODES = ["Standard Class", "Second Class", "First Class", "Same Day"]
PAYMENT_TYPES = ["DEBIT", "TRANSFER", "PAYMENT", "CASH"]


def load_bundle():
    """惰性加载模型文件，进程内只加载一次。"""
    if _cache["bundle"] is None:
        with _lock:
            if _cache["bundle"] is None:
                with open(settings.W1_MODEL_PATH, "rb") as fh:
                    _cache["bundle"] = pickle.load(fh)
    return _cache["bundle"]


def model_info():
    """模型概况，供前端展示模型来源与指标。"""
    bundle = load_bundle()
    return {
        "model_name": bundle["model_name"],
        "train_period": bundle["train_period"],
        "test_period": bundle["test_period"],
        "feature_cnt": len(bundle["features"]),
        "metrics": bundle["metrics"],
    }


def _to_float(value, fallback):
    try:
        if value is None or value == "":
            return float(fallback)
        return float(value)
    except (TypeError, ValueError):
        return float(fallback)


def _time_period(hour):
    for low, high, name in TIME_PERIOD_BANDS:
        if low <= hour <= high:
            return name
    return "晚间"


def _amount_level(net_amount):
    if net_amount <= AMOUNT_BOUND_LOW:
        return "低"
    if net_amount <= AMOUNT_BOUND_HIGH:
        return "中"
    return "高"


def build_features(payload):
    """把前端提交的业务字段展开成模型所需的特征表。

    前端只提交下单时间、物流方式、支付方式、市场、类目与金额数量等少数字段，
    其余特征由本函数按离线层的口径派生，保证在线与离线口径一致。
    """
    import pandas as pd

    dt = pd.to_datetime(payload.get("order_datetime"), errors="coerce")
    if dt is pd.NaT or dt is None or str(payload.get("order_datetime", "")).strip() == "":
        raise ValueError("下单时间不能为空，格式示例 2017-12-05 14:30:00")

    hour = int(dt.hour)
    weekday = int(dt.weekday())  # 0 为周一
    total_quantity = max(1, int(_to_float(payload.get("total_quantity"), DEFAULTS["total_quantity"])))
    discount = _to_float(payload.get("total_discount"), DEFAULTS["total_discount"])
    sales = _to_float(payload.get("total_sales"), None) if payload.get("total_sales") not in (None, "") else None
    net = _to_float(payload.get("total_net_amount"), None) if payload.get("total_net_amount") not in (None, "") else None
    if net is None and sales is None:
        sales = 100.0
    if net is None:
        net = sales - discount
    if sales is None:
        sales = net + discount

    row = {
        "time_period": _time_period(hour),
        "payment_type": payload.get("payment_type") or DEFAULTS["payment_type"],
        "shipping_mode": payload.get("shipping_mode") or DEFAULTS["shipping_mode"],
        "main_category_name": payload.get("main_category_name") or DEFAULTS["main_category_name"],
        "main_department_name": payload.get("main_department_name") or DEFAULTS["main_department_name"],
        "market": payload.get("market") or DEFAULTS["market"],
        "order_region": payload.get("order_region") or DEFAULTS["order_region"],
        "amount_level": _amount_level(net),
        "order_month": int(dt.month),
        "order_day": int(dt.day),
        "order_hour": hour,
        "order_week": int(dt.isocalendar()[1]),
        "order_weekday": weekday,
        "is_weekend": 1 if weekday >= 5 else 0,
        "item_line_cnt": int(_to_float(payload.get("item_line_cnt"), DEFAULTS["item_line_cnt"])),
        "product_cnt": int(_to_float(payload.get("product_cnt"), DEFAULTS["product_cnt"])),
        "category_cnt": int(_to_float(payload.get("category_cnt"), DEFAULTS["category_cnt"])),
        "department_cnt": int(_to_float(payload.get("department_cnt"), DEFAULTS["department_cnt"])),
        "total_quantity": total_quantity,
        "total_sales": round(sales, 4),
        "total_discount": round(discount, 4),
        "total_net_amount": round(net, 4),
        "avg_item_price": round(sales / total_quantity, 4),
        "benefit_per_order": _to_float(payload.get("benefit_per_order"), DEFAULTS["benefit_per_order"]),
        "latitude": _to_float(payload.get("latitude"), DEFAULTS["latitude"]),
        "longitude": _to_float(payload.get("longitude"), DEFAULTS["longitude"]),
    }
    return row


def predict(payload):
    """对单笔订单给出延迟概率与风险等级。"""
    import pandas as pd

    bundle = load_bundle()
    features = bundle["features"]
    row = build_features(payload)
    frame = pd.DataFrame([{name: row[name] for name in features}])
    prob = float(bundle["pipeline"].predict_proba(frame)[0][1])
    if prob >= 0.8:
        level = "高"
    elif prob >= 0.5:
        level = "中"
    else:
        level = "低"
    return {
        "delay_prob": round(prob, 6),
        "risk_level": level,
        "alert_flag": 1 if prob >= 0.5 else 0,
        "features": row,
        "feature_order": features,
    }
