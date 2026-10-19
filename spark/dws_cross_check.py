# -*- coding: utf-8 -*-
"""
跨域关联与流量维度的 Spark 复算脚本。

用途：
  1. 用 PySpark 独立复算 Hive 已落地的两张跨域表与 W5 日均访问量，
     与 Hive 结果逐项比对，形成双引擎互验（同一口径、两套引擎、结果一致）。
  2. 记录各阶段耗时，供任务书 8.5 节 Spark 与单机 pandas 耗时对比实验引用。

口径与 hive/03_dws.sql 完全一致：
  - dws_product_traffic    粒度为商品乘日期，时段按访问小时划分，不限定时间窗口
  - dws_product_conversion 限定两源共同窗口 2017-09 至 2018-01；
                           分子取含该商品的唯一订单数，禁止先按订单号去重只留首行；
                           商品名在订单侧做 lower(trim()) 归一，与访问侧 product_key 对齐
  - W5 日均访问量          先按全部日期算基线，剔除越限日后重算基线；
                           标准差用样本口径（除以 n-1），与 Hive 的 STDDEV_SAMP 对齐

注意：本脚本只做复算与核对，不覆盖 Hive 的落库结果，也不参与 W1 建模。

运行方式（在 spark 容器内）：
  spark-submit --master local[2] --driver-memory 1g --conf spark.sql.shuffle.partitions=4 \
      /bishe/spark/dws_cross_check.py
"""

import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

HDFS_ROOT = "hdfs://namenode:9000/user/hive/warehouse/bishe_dwd.db"
ACCESS_PATH = HDFS_ROOT + "/dwd_access_log"
DETAIL_PATH = HDFS_ROOT + "/dwd_order_detail"
WINDOW_START = "2017-09"
WINDOW_END = "2018-01"

STAGE_TIME = []


def stage(name):
    """记录阶段耗时的简单上下文管理器。"""
    return _Stage(name)


class _Stage(object):
    def __init__(self, name):
        self.name = name

    def __enter__(self):
        self.t0 = time.time()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        cost = time.time() - self.t0
        STAGE_TIME.append((self.name, cost))
        print("[耗时] %-28s %8.2f 秒" % (self.name, cost))
        return False


def show(title, df, n=30):
    print("\n===== " + title + " =====")
    df.show(n, truncate=False)


def main():
    spark = (
        SparkSession.builder.appName("bishe_dws_cross_check")
        .config("spark.sql.shuffle.partitions", "4")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    total_t0 = time.time()

    with stage("读取访问日志与订单明细"):
        access = spark.read.parquet(ACCESS_PATH)
        detail = spark.read.parquet(DETAIL_PATH)
        print("访问日志列：", access.columns)
        print("订单明细列：", detail.columns)

    # ---------- 一、商品流量维度 ----------
    with stage("复算商品流量维度"):
        traffic = (
            access.groupBy("product_key", "access_date")
            .agg(
                F.max("product").alias("product"),
                F.max("category").alias("category"),
                F.max("department").alias("department"),
                F.max("access_month").alias("access_month"),
                F.max("access_weekday").alias("access_weekday"),
                F.max("is_weekend").alias("is_weekend"),
                F.count("*").alias("views"),
                F.countDistinct("ip").alias("unique_ip_cnt"),
                F.sum(F.when(F.col("access_hour").between(0, 5), 1).otherwise(0)).alias("views_dawn"),
                F.sum(F.when(F.col("access_hour").between(6, 11), 1).otherwise(0)).alias("views_morning"),
                F.sum(F.when(F.col("access_hour").between(12, 17), 1).otherwise(0)).alias("views_afternoon"),
                F.sum(F.when(F.col("access_hour").between(18, 23), 1).otherwise(0)).alias("views_evening"),
            )
        )

    show(
        "校验一：商品流量维度（对齐 Hive：76 个商品、469977 次浏览、11450 行）",
        traffic.agg(
            F.countDistinct("product_key").alias("product_cnt"),
            F.sum("views").alias("total_views"),
            F.count("*").alias("row_cnt"),
        ),
    )

    # ---------- 二、跨域商品宽表 ----------
    with stage("复算跨域商品宽表"):
        views_win = (
            access.filter(F.col("dt").between(WINDOW_START, WINDOW_END))
            .groupBy("product_key")
            .agg(
                F.max("product").alias("product"),
                F.max("category").alias("category"),
                F.max("department").alias("department"),
                F.count("*").alias("views"),
                F.countDistinct("ip").alias("unique_ip_cnt"),
                F.countDistinct("access_date").alias("active_days"),
                F.min("access_date").alias("first_access_date"),
                F.max("access_date").alias("last_access_date"),
            )
        )
        orders_win = (
            detail.filter(F.col("dt").between(WINDOW_START, WINDOW_END))
            .withColumn("product_key", F.lower(F.trim(F.col("product_name"))))
            .groupBy("product_key")
            .agg(F.countDistinct("order_id").alias("orders"))
        )
        conv = (
            views_win.join(orders_win, "product_key", "left_outer")
            .withColumn("orders", F.coalesce(F.col("orders"), F.lit(0)))
            .withColumn("conv_rate", F.round(F.col("orders") / F.col("views") * 100, 6))
        )
        conv.cache()
        conv.count()

    show(
        "校验二：跨域商品宽表（对齐 Hive：76 个商品、其中可关联 36 个）",
        conv.agg(
            F.count("*").alias("product_cnt"),
            F.sum(F.when(F.col("orders") > 0, 1).otherwise(0)).alias("matched_products"),
            F.round(F.sum("orders") / F.sum("views") * 100, 4).alias("overall_conv_rate_all"),
            F.round(F.avg("conv_rate"), 4).alias("avg_conv_rate_all"),
        ),
    )

    show(
        "校验三：可关联商品（orders > 0，对齐 Hive：36 个、全站 1.646%、逐商品均值 1.0968%）",
        conv.filter(F.col("orders") > 0).agg(
            F.count("*").alias("matched_products"),
            F.round(F.avg("conv_rate"), 4).alias("avg_product_conv_rate"),
            F.sum("orders").alias("total_orders"),
            F.sum("views").alias("total_views"),
        ),
    )

    big = conv.filter((F.col("orders") > 0) & (F.col("views") > 1000))
    show(
        "校验四：极差（浏览量大于 1000 的可关联商品，对齐 Hive：32 个、极差 122.7 倍）",
        big.agg(
            F.count("*").alias("n"),
            F.round(F.max("conv_rate") / F.min("conv_rate"), 1).alias("ratio"),
            F.min("conv_rate").alias("min_conv_rate"),
            F.max("conv_rate").alias("max_conv_rate"),
        ),
    )

    lowest8 = big.orderBy(F.col("conv_rate").asc()).limit(8)
    show(
        "校验五：异常组（最低四分位 8 个，对齐 Hive：浏览 58440、成交 26、组内 0.0445%）",
        lowest8.agg(
            F.count("*").alias("n"),
            F.sum("views").alias("sum_views"),
            F.sum("orders").alias("sum_orders"),
            F.round(F.sum("orders") / F.sum("views") * 100, 4).alias("group_conv_rate"),
        ),
    )
    show("异常组明细（最低四分位 8 个商品）", lowest8.select("product", "views", "orders", "conv_rate"), 8)

    conv.unpersist()

    # ---------- 三、W5 日均访问量 ----------
    with stage("复算 W5 日均访问量"):
        daily = (
            access.groupBy("access_date")
            .agg(F.count("*").alias("daily_views"))
            .orderBy("access_date")
        )
        # 第一轮基线：全部日期（标准差用样本口径 stddev_samp，与 Hive 的 STDDEV_SAMP 对齐）
        base1 = daily.agg(F.avg("daily_views").alias("m"), F.stddev_samp("daily_views").alias("s")).first()
        first_round = (
            daily.withColumn("dev", F.round((F.col("daily_views") - F.lit(base1["m"])) / F.lit(base1["s"]), 2))
            .filter(F.abs(F.col("dev")) >= 3)
        )
        # 剔除越限日后重算基线
        normal = daily.join(first_round.select("access_date"), on="access_date", how="left_anti")
        base2 = normal.agg(F.avg("daily_views").alias("m"), F.stddev_samp("daily_views").alias("s")).first()
        final = (
            daily.withColumn(
                "dev",
                F.round((F.col("daily_views") - F.lit(base2["m"])) / F.lit(base2["s"]), 2),
            )
        )
        alert_days = final.filter(F.abs(F.col("dev")) >= 3).orderBy(F.col("dev").desc())

    show(
        "校验六：W5 基线（对齐 Hive：日均 2791.64、标准差 271.99）",
        spark.createDataFrame(
            [(round(base1["m"], 2), round(base1["s"], 2), round(base2["m"], 2), round(base2["s"], 2))],
            ["第一轮均值", "第一轮标准差", "最终均值", "最终标准差"],
        ),
    )
    show(
        "校验七：W5 告警日（对齐 Hive：命中 6 天，全部突增，极端日 2017-09-14 访问 45648、偏离 157.57）",
        alert_days.select("access_date", "daily_views", "dev"),
        10,
    )
    show(
        "校验八：W5 告警日计数与极端日",
        final.filter(F.abs(F.col("dev")) >= 3).agg(
            F.count("*").alias("alert_days"),
            F.max("daily_views").alias("max_views"),
            F.max("dev").alias("max_dev"),
        ),
    )

    total = time.time() - total_t0
    print("\n===== 各阶段耗时 =====")
    for name, cost in STAGE_TIME:
        print("%-30s %8.2f 秒" % (name, cost))
    print("%-30s %8.2f 秒" % ("整作业总耗时", total))

    spark.stop()


if __name__ == "__main__":
    main()
