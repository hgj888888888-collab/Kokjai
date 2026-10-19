# -*- coding: utf-8 -*-
"""把离线层导出的 ADS 结果装载进在线业务库。

用法（在 django-app 容器内执行）：
    python manage.py load_ads
    python manage.py load_ads --only ads_traffic_warning

数据来源为共享目录下的 ads_export，每张表一个制表符分隔的文本文件，
路径与列顺序见下方配置。装载前先清空目标表，可安全重跑。
Hive 的空值写作反斜杠加 N，MySQL 的 LOAD DATA 默认即以该记号表示空值，
两端约定一致，不需要额外做空值转换。
"""

import os

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db import connection

# 表名、导出文件所在子目录、列顺序（与 Hive 表字段顺序一致，不可调换）
TABLES = [
    (
        "ads_delay_warning",
        "order_id, order_datetime, order_month, shipping_mode, main_category_name, "
        "order_country, market, amount_level, total_net_amount, delay_prob, "
        "prob_source, risk_level, alert_flag",
    ),
    (
        "ads_dim_warning",
        "dim_type, dim_value, order_cnt, late_cnt, delay_rate, baseline_rate, "
        "deviation_pp, std_error_pp, z_score, sample_enough, alert_flag",
    ),
    (
        "ads_conversion_warning",
        "product, category, department, views, orders, conv_rate, "
        "baseline_conv_rate, deviation_ratio, alert_flag, alert_level",
    ),
    (
        "ads_traffic_warning",
        "access_date, visits, avg_visits, std_visits, z_score, alert_flag, alert_level",
    ),
    (
        "ads_order_risk_score",
        "order_id, order_datetime, order_month, shipping_mode, main_category_name, "
        "order_country, market, amount_level, total_net_amount, delay_prob, "
        "shipping_risk, risk_score, risk_level, suggestion",
    ),
    (
        "ads_warning_ticket",
        "ticket_id, target_id, warn_type, risk_level, handle_status, handler, "
        "handle_action, create_time, handle_time, remark, is_false_alarm",
    ),
    (
        "ads_handle_stats",
        "stat_scope, warn_type, ticket_cnt, labeled_cnt, hit_rate, "
        "false_alarm_rate, handled_cnt, avg_handle_hours",
    ),
    (
        "ads_risk_board",
        "board_dim, board_key, order_cnt, order_share, total_revenue, "
        "avg_order_amount, delay_rate",
    ),
]


class Command(BaseCommand):
    help = "把离线层 ADS 导出文件装载进 MySQL 业务库"

    def add_arguments(self, parser):
        parser.add_argument(
            "--only",
            default="",
            help="只装载指定表，留空表示装载全部八张表",
        )

    def handle(self, *args, **options):
        only = options["only"].strip()
        base_dir = settings.ADS_EXPORT_DIR
        self.stdout.write("导出目录：{0}".format(base_dir))

        for table, columns in TABLES:
            if only and only != table:
                continue
            path = os.path.join(base_dir, table, "000000_0")
            if not os.path.exists(path):
                self.stderr.write("跳过 {0}：导出文件不存在 {1}".format(table, path))
                continue
            with connection.cursor() as cur:
                cur.execute("TRUNCATE TABLE {0}".format(table))
                sql = (
                    "LOAD DATA LOCAL INFILE %s INTO TABLE {0} "
                    "FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' "
                    "LINES TERMINATED BY '\\n' ({1})".format(table, columns)
                )
                cur.execute(sql, [path])
                loaded = cur.rowcount
                cur.execute("SELECT COUNT(*) FROM {0}".format(table))
                total = cur.fetchone()[0]
            self.stdout.write(
                "装载 {0}：本次写入 {1} 行，表内合计 {2} 行".format(table, loaded, total)
            )

        self.stdout.write(self.style.SUCCESS("ADS 装载完成"))
