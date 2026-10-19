# -*- coding: utf-8 -*-
"""在线业务库的八张表，与离线层 ADS 层表名与字段一一对应。

离线层在 Hive 中产出结果并导出为制表符分隔文本，在线层用这些模型建立
MySQL 库表结构，再由 load_ads 命令装载数据。字段顺序与 Hive 表完全一致，
装载时按同序读取，避免错列。
"""

from django.db import models


class DelayWarning(models.Model):
    """延迟交付预警，对应 ADS 表 ads_delay_warning。"""

    order_id = models.CharField(max_length=32, primary_key=True)
    order_datetime = models.DateTimeField(null=True)
    order_month = models.CharField(max_length=7, db_index=True)
    shipping_mode = models.CharField(max_length=32, db_index=True)
    main_category_name = models.CharField(max_length=64)
    order_country = models.CharField(max_length=64)
    market = models.CharField(max_length=32)
    amount_level = models.CharField(max_length=8)
    total_net_amount = models.FloatField()
    delay_prob = models.FloatField(db_index=True)
    prob_source = models.CharField(max_length=64)
    risk_level = models.CharField(max_length=8, db_index=True)
    alert_flag = models.IntegerField(db_index=True)

    class Meta:
        db_table = "ads_delay_warning"
        verbose_name = "延迟交付预警"


class DimWarning(models.Model):
    """维度告警，对应 ADS 表 ads_dim_warning。"""

    dim_type = models.CharField(max_length=16, db_index=True)
    dim_value = models.CharField(max_length=128)
    order_cnt = models.BigIntegerField()
    late_cnt = models.BigIntegerField()
    delay_rate = models.FloatField()
    baseline_rate = models.FloatField()
    deviation_pp = models.FloatField()
    std_error_pp = models.FloatField()
    z_score = models.FloatField()
    sample_enough = models.IntegerField()
    alert_flag = models.IntegerField(db_index=True)

    class Meta:
        db_table = "ads_dim_warning"
        verbose_name = "维度告警"


class ConversionWarning(models.Model):
    """转化异常告警，对应 ADS 表 ads_conversion_warning。"""

    product = models.CharField(max_length=160, primary_key=True)
    category = models.CharField(max_length=64)
    department = models.CharField(max_length=64)
    views = models.BigIntegerField()
    orders = models.BigIntegerField()
    conv_rate = models.FloatField()
    baseline_conv_rate = models.FloatField()
    deviation_ratio = models.FloatField()
    alert_flag = models.IntegerField(db_index=True)
    alert_level = models.CharField(max_length=16)

    class Meta:
        db_table = "ads_conversion_warning"
        verbose_name = "转化异常告警"


class TrafficWarning(models.Model):
    """流量异常告警，对应 ADS 表 ads_traffic_warning。"""

    access_date = models.CharField(max_length=10, primary_key=True)
    visits = models.BigIntegerField()
    avg_visits = models.FloatField()
    std_visits = models.FloatField()
    z_score = models.FloatField()
    alert_flag = models.IntegerField(db_index=True)
    alert_level = models.CharField(max_length=16)

    class Meta:
        db_table = "ads_traffic_warning"
        ordering = ["access_date"]
        verbose_name = "流量异常告警"


class OrderRiskScore(models.Model):
    """综合风险评分，对应 ADS 表 ads_order_risk_score。"""

    order_id = models.CharField(max_length=32, primary_key=True)
    order_datetime = models.DateTimeField(null=True)
    order_month = models.CharField(max_length=7, db_index=True)
    shipping_mode = models.CharField(max_length=32, db_index=True)
    main_category_name = models.CharField(max_length=64)
    order_country = models.CharField(max_length=64)
    market = models.CharField(max_length=32)
    amount_level = models.CharField(max_length=8)
    total_net_amount = models.FloatField()
    delay_prob = models.FloatField()
    shipping_risk = models.FloatField()
    risk_score = models.FloatField(db_index=True)
    risk_level = models.CharField(max_length=8, db_index=True)
    suggestion = models.CharField(max_length=128)

    class Meta:
        db_table = "ads_order_risk_score"
        verbose_name = "综合风险评分"


class WarningTicket(models.Model):
    """风险工单，对应 ADS 表 ads_warning_ticket，是在线层可写的处置闭环表。"""

    STATUS_CHOICES = [
        ("待处理", "待处理"),
        ("处理中", "处理中"),
        ("已处置", "已处置"),
        ("已关闭", "已关闭"),
    ]

    ticket_id = models.CharField(max_length=32, primary_key=True)
    target_id = models.CharField(max_length=160, db_index=True)
    warn_type = models.CharField(max_length=32, db_index=True)
    risk_level = models.CharField(max_length=8, db_index=True)
    handle_status = models.CharField(max_length=8, default="待处理", db_index=True)
    handler = models.CharField(max_length=32, default="未分配")
    handle_action = models.CharField(max_length=128)
    create_time = models.DateTimeField(null=True, db_index=True)
    handle_time = models.DateTimeField(null=True)
    remark = models.TextField(null=True)
    is_false_alarm = models.IntegerField(default=0)

    class Meta:
        db_table = "ads_warning_ticket"
        ordering = ["ticket_id"]
        verbose_name = "风险工单"


class HandleStats(models.Model):
    """处置结果统计，对应 ADS 表 ads_handle_stats。"""

    stat_scope = models.CharField(max_length=16)
    warn_type = models.CharField(max_length=32, db_index=True)
    ticket_cnt = models.BigIntegerField()
    labeled_cnt = models.BigIntegerField()
    hit_rate = models.FloatField(null=True)
    false_alarm_rate = models.FloatField(null=True)
    handled_cnt = models.BigIntegerField(default=0)
    avg_handle_hours = models.FloatField(null=True)

    class Meta:
        db_table = "ads_handle_stats"
        verbose_name = "处置结果统计"


class RiskBoard(models.Model):
    """看板汇总指标，对应 ADS 表 ads_risk_board。"""

    board_dim = models.CharField(max_length=16, db_index=True)
    board_key = models.CharField(max_length=128)
    order_cnt = models.BigIntegerField()
    order_share = models.FloatField()
    total_revenue = models.FloatField()
    avg_order_amount = models.FloatField()
    delay_rate = models.FloatField()

    class Meta:
        db_table = "ads_risk_board"
        indexes = [models.Index(fields=["board_dim", "board_key"])]
        verbose_name = "看板汇总指标"
