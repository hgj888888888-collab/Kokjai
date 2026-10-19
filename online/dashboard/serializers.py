# -*- coding: utf-8 -*-
"""DRF 序列化器，用于在线预警查询与工单处置接口。"""

from rest_framework import serializers

from .models import (
    ConversionWarning,
    DelayWarning,
    DimWarning,
    HandleStats,
    OrderRiskScore,
    RiskBoard,
    TrafficWarning,
    WarningTicket,
)


class DelayWarningSerializer(serializers.ModelSerializer):
    class Meta:
        model = DelayWarning
        fields = "__all__"


class DimWarningSerializer(serializers.ModelSerializer):
    class Meta:
        model = DimWarning
        fields = "__all__"


class ConversionWarningSerializer(serializers.ModelSerializer):
    class Meta:
        model = ConversionWarning
        fields = "__all__"


class TrafficWarningSerializer(serializers.ModelSerializer):
    class Meta:
        model = TrafficWarning
        fields = "__all__"


class OrderRiskScoreSerializer(serializers.ModelSerializer):
    class Meta:
        model = OrderRiskScore
        fields = "__all__"


class WarningTicketSerializer(serializers.ModelSerializer):
    class Meta:
        model = WarningTicket
        fields = "__all__"


class HandleStatsSerializer(serializers.ModelSerializer):
    class Meta:
        model = HandleStats
        fields = "__all__"


class RiskBoardSerializer(serializers.ModelSerializer):
    class Meta:
        model = RiskBoard
        fields = "__all__"


class TicketHandleSerializer(serializers.Serializer):
    """工单处置入参：状态、处理人、处置动作、备注与误报标记。"""

    handle_status = serializers.ChoiceField(
        choices=["待处理", "处理中", "已处置", "已关闭"], required=False
    )
    handler = serializers.CharField(required=False, allow_blank=True, max_length=32)
    handle_action = serializers.CharField(required=False, allow_blank=True, max_length=128)
    remark = serializers.CharField(required=False, allow_blank=True)
    is_false_alarm = serializers.IntegerField(required=False, min_value=0, max_value=1)


class PredictSerializer(serializers.Serializer):
    """实时预测入参，只暴露业务上可填的字段，其余特征由服务端派生。"""

    order_datetime = serializers.CharField()
    shipping_mode = serializers.CharField(required=False, allow_blank=True)
    payment_type = serializers.CharField(required=False, allow_blank=True)
    main_category_name = serializers.CharField(required=False, allow_blank=True)
    main_department_name = serializers.CharField(required=False, allow_blank=True)
    market = serializers.CharField(required=False, allow_blank=True)
    order_region = serializers.CharField(required=False, allow_blank=True)
    item_line_cnt = serializers.IntegerField(required=False, min_value=1, max_value=20)
    product_cnt = serializers.IntegerField(required=False, min_value=1, max_value=20)
    category_cnt = serializers.IntegerField(required=False, min_value=1, max_value=20)
    department_cnt = serializers.IntegerField(required=False, min_value=1, max_value=20)
    total_quantity = serializers.IntegerField(required=False, min_value=1, max_value=100)
    total_sales = serializers.FloatField(required=False)
    total_discount = serializers.FloatField(required=False)
    total_net_amount = serializers.FloatField(required=False)
    benefit_per_order = serializers.FloatField(required=False)
