# -*- coding: utf-8 -*-
"""在线预警服务的接口层。

页面一：看板首页，汇总展示预警结果
接口一：GET  /api/dashboard/  看板全部图表数据，一次返回，减少前端往返
接口二：GET  /api/orders/     订单级预警与风险分查询，支持筛选与分页
接口三：GET  /api/tickets/    风险工单查询
接口四：POST /api/tickets/<工单号>/handle/  工单处置，处置后回写统计表
接口五：GET  /api/handle-stats/  处置结果统计
接口六：POST /api/predict/    实时预测，加载离线层模型文件对单笔订单打分
"""

from django.db.models import Avg, Count, Max, Q, Sum
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.cache import never_cache
from rest_framework import status
from rest_framework.decorators import api_view
from rest_framework.response import Response

from . import geo, predictor
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
from .serializers import (
    ConversionWarningSerializer,
    DimWarningSerializer,
    HandleStatsSerializer,
    TrafficWarningSerializer,
    TicketHandleSerializer,
    WarningTicketSerializer,
)


@never_cache
def index(request):
    """看板首页。禁缓存，避免前端改版后浏览器仍拿旧的 HTML 与静态资源。"""
    return render(request, "dashboard/index.html")


def _page_params(request):
    try:
        page = max(1, int(request.query_params.get("page", 1)))
    except (TypeError, ValueError):
        page = 1
    try:
        size = min(100, max(1, int(request.query_params.get("page_size", 20))))
    except (TypeError, ValueError):
        size = 20
    return page, size


def _slice(request, queryset):
    page, size = _page_params(request)
    total = queryset.count()
    start = (page - 1) * size
    return queryset[start:start + size], total, page, size


@api_view(["GET"])
def dashboard(request):
    """看板首页所需的全部分析数据。"""
    delay = DelayWarning.objects.all()
    total_orders = delay.count()
    risk_rows = delay.values("risk_level").annotate(cnt=Count("order_id"))
    risk_map = {row["risk_level"]: row["cnt"] for row in risk_rows}
    prob_avg = delay.aggregate(v=Avg("delay_prob"))["v"] or 0.0

    overall = RiskBoard.objects.filter(board_dim="总体").first()
    handle_all = HandleStats.objects.filter(stat_scope="全部").first()

    overview = {
        "total_orders": total_orders,
        "alert_orders": delay.filter(alert_flag=1).count(),
        "high_orders": risk_map.get("高", 0),
        "mid_orders": risk_map.get("中", 0),
        "low_orders": risk_map.get("低", 0),
        "avg_prob": round(prob_avg, 4),
        "delay_rate": overall.delay_rate if overall else None,
        "alert_share": round(delay.filter(alert_flag=1).count() / total_orders * 100, 2) if total_orders else 0.0,
        "ticket_cnt": handle_all.ticket_cnt if handle_all else 0,
        "hit_rate": handle_all.hit_rate if handle_all else None,
        "false_alarm_rate": handle_all.false_alarm_rate if handle_all else None,
        "handled_cnt": handle_all.handled_cnt if handle_all else 0,
        "total_revenue": overall.total_revenue if overall else None,
    }

    # 饼图一：风险等级分布
    risk_pie = [
        {"name": level, "value": risk_map.get(level, 0)}
        for level in ["高", "中", "低"]
    ]

    # 柱状图一与饼图二：物流方式
    shipping_rows = list(
        DimWarning.objects.filter(dim_type="物流方式").order_by("-order_cnt")
    )
    ship_total = sum(row.order_cnt for row in shipping_rows) or 1
    shipping = [
        {
            "name": row.dim_value,
            "order_cnt": row.order_cnt,
            "order_share": round(row.order_cnt / ship_total * 100, 2),
            "delay_rate": row.delay_rate,
            "baseline_rate": row.baseline_rate,
            "deviation_pp": row.deviation_pp,
            "z_score": row.z_score,
            "alert_flag": row.alert_flag,
        }
        for row in shipping_rows
    ]

    # 柱状图二：商品类目延迟率，按订单量取前十五个，保证样本量可比
    category_rows = list(
        DimWarning.objects.filter(dim_type="商品类目").order_by("-order_cnt")[:15]
    )
    category = [
        {
            "name": row.dim_value,
            "order_cnt": row.order_cnt,
            "delay_rate": row.delay_rate,
            "baseline_rate": row.baseline_rate,
            "deviation_pp": row.deviation_pp,
            "sample_enough": row.sample_enough,
            "alert_flag": row.alert_flag,
        }
        for row in category_rows
    ]

    # 折线图一：月度订单量与平均延迟概率
    monthly = list(
        delay.values("order_month")
        .annotate(
            order_cnt=Count("order_id"),
            alert_cnt=Sum("alert_flag"),
            avg_prob=Avg("delay_prob"),
        )
        .order_by("order_month")
    )
    monthly_line = [
        {
            "month": row["order_month"],
            "order_cnt": row["order_cnt"],
            "alert_cnt": row["alert_cnt"] or 0,
            "avg_prob": round(row["avg_prob"] or 0, 4),
        }
        for row in monthly
    ]

    # 折线图二：日访问量与三倍标准差基线
    traffic_rows = list(TrafficWarning.objects.all().order_by("access_date"))
    traffic = [
        {
            "date": row.access_date,
            "visits": row.visits,
            "avg_visits": row.avg_visits,
            "std_visits": row.std_visits,
            "z_score": row.z_score,
            "alert_flag": row.alert_flag,
            "alert_level": row.alert_level,
        }
        for row in traffic_rows
    ]

    # 世界地图：目的国维度。订单表国名为西班牙语，底图为英文，
    # 经名称映射维表对齐后再交给前端着色
    country_rows = list(
        RiskBoard.objects.filter(board_dim="目的国").order_by("-order_cnt")
    )
    country = [
        {
            "name": row.board_key,
            "map_name": geo.to_map_name(row.board_key),
            "order_cnt": row.order_cnt,
            "order_share": row.order_share,
            "revenue": row.total_revenue,
            "delay_rate": row.delay_rate,
        }
        for row in country_rows
    ]
    unmapped_country = [
        {"name": item["name"], "order_cnt": item["order_cnt"]}
        for item in country
        if not geo.is_mapped(item["name"])
    ]
    market = [
        row.board_key
        for row in RiskBoard.objects.filter(board_dim="市场大区").order_by("-order_cnt")
    ]

    # 转化异常：32 个高浏览商品，按转化率升序
    conversion = ConversionWarningSerializer(
        ConversionWarning.objects.all().order_by("conv_rate"), many=True
    ).data

    time_period = [
        {
            "name": row.board_key,
            "order_cnt": row.order_cnt,
            "order_share": row.order_share,
            "delay_rate": row.delay_rate,
        }
        for row in RiskBoard.objects.filter(board_dim="下单时段").order_by("-order_cnt")
    ]

    return Response({
        "overview": overview,
        "risk_pie": risk_pie,
        "shipping": shipping,
        "category": category,
        "monthly": monthly_line,
        "traffic": traffic,
        "country": country,
        "unmapped_country": unmapped_country,
        "market": market,
        "conversion": conversion,
        "time_period": time_period,
        "model": predictor.model_info(),
    })


@api_view(["GET"])
def orders(request):
    """订单级预警查询，支持按风险等级、物流方式、月份与关键词筛选。"""
    qs = OrderRiskScore.objects.all().order_by("-risk_score", "-total_net_amount")
    risk = request.query_params.get("risk", "").strip()
    shipping = request.query_params.get("shipping", "").strip()
    month = request.query_params.get("month", "").strip()
    keyword = request.query_params.get("q", "").strip()
    if risk:
        qs = qs.filter(risk_level=risk)
    if shipping:
        qs = qs.filter(shipping_mode=shipping)
    if month:
        qs = qs.filter(order_month=month)
    if keyword:
        qs = qs.filter(
            Q(order_id__icontains=keyword)
            | Q(order_country__icontains=keyword)
            | Q(main_category_name__icontains=keyword)
        )
    rows, total, page, size = _slice(request, qs)
    data = [
        {
            "order_id": row.order_id,
            "order_month": row.order_month,
            "shipping_mode": row.shipping_mode,
            "main_category_name": row.main_category_name,
            "order_country": row.order_country,
            "market": row.market,
            "amount_level": row.amount_level,
            "total_net_amount": row.total_net_amount,
            "delay_prob": row.delay_prob,
            "risk_score": row.risk_score,
            "risk_level": row.risk_level,
            "suggestion": row.suggestion,
        }
        for row in rows
    ]
    return Response({"total": total, "page": page, "page_size": size, "rows": data})


@api_view(["GET"])
def tickets(request):
    """风险工单查询。"""
    qs = WarningTicket.objects.all().order_by("warn_type", "ticket_id")
    warn_type = request.query_params.get("warn_type", "").strip()
    handle_status = request.query_params.get("handle_status", "").strip()
    risk_level = request.query_params.get("risk_level", "").strip()
    keyword = request.query_params.get("q", "").strip()
    if warn_type:
        qs = qs.filter(warn_type=warn_type)
    if handle_status:
        qs = qs.filter(handle_status=handle_status)
    if risk_level:
        qs = qs.filter(risk_level=risk_level)
    if keyword:
        qs = qs.filter(Q(ticket_id__icontains=keyword) | Q(target_id__icontains=keyword))
    rows, total, page, size = _slice(request, qs)
    counts = {
        row["handle_status"]: row["cnt"]
        for row in WarningTicket.objects.values("handle_status").annotate(cnt=Count("ticket_id"))
    }
    types = [
        row["warn_type"]
        for row in WarningTicket.objects.values("warn_type").annotate(cnt=Count("ticket_id")).order_by("-cnt")
    ]
    return Response({
        "total": total,
        "page": page,
        "page_size": size,
        "status_counts": counts,
        "types": types,
        "rows": WarningTicketSerializer(rows, many=True).data,
    })


def _refresh_handle_stats():
    """按工单实际处置情况回写处置统计表，形成处置闭环的反馈。"""

    def calc(queryset):
        handled = queryset.filter(handle_status__in=["已处置", "已关闭"])
        cnt = handled.count()
        pairs = handled.exclude(handle_time=None).values_list("create_time", "handle_time")
        hours = [
            (handle - create).total_seconds() / 3600
            for create, handle in pairs
            if create and handle
        ]
        return cnt, (round(sum(hours) / len(hours), 2) if hours else None)

    # 工单表 Meta 里带默认排序，做 DISTINCT 时 Django 会把排序字段一并塞进 SELECT，
    # 去重因此失效，循环次数会等于工单总数而不是预警类型数，故先清空排序。
    for warn_type in WarningTicket.objects.order_by().values_list("warn_type", flat=True).distinct():
        cnt, avg_hours = calc(WarningTicket.objects.filter(warn_type=warn_type))
        HandleStats.objects.filter(warn_type=warn_type).update(
            handled_cnt=cnt, avg_handle_hours=avg_hours
        )
    cnt, avg_hours = calc(WarningTicket.objects.all())
    HandleStats.objects.filter(stat_scope="全部").update(
        handled_cnt=cnt, avg_handle_hours=avg_hours
    )


@api_view(["POST"])
def handle_ticket(request, ticket_id):
    """工单处置，处置后同步刷新统计表。"""
    serializer = TicketHandleSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
    try:
        ticket = WarningTicket.objects.get(ticket_id=ticket_id)
    except WarningTicket.DoesNotExist:
        return Response({"detail": "工单不存在"}, status=status.HTTP_404_NOT_FOUND)

    payload = serializer.validated_data
    if "handler" in payload and payload["handler"]:
        ticket.handler = payload["handler"]
    if "handle_action" in payload and payload["handle_action"]:
        ticket.handle_action = payload["handle_action"]
    if "remark" in payload:
        ticket.remark = payload["remark"]
    if "is_false_alarm" in payload:
        ticket.is_false_alarm = payload["is_false_alarm"]
    if "handle_status" in payload and payload["handle_status"]:
        ticket.handle_status = payload["handle_status"]
    if ticket.handle_status in ["已处置", "已关闭"]:
        ticket.handle_time = timezone.now()
    else:
        ticket.handle_time = None
    ticket.save()
    _refresh_handle_stats()
    return Response(WarningTicketSerializer(ticket).data)


@api_view(["GET"])
def handle_stats(request):
    """处置结果统计。"""
    rows = HandleStats.objects.all().order_by("-ticket_cnt")
    return Response(HandleStatsSerializer(rows, many=True).data)


@api_view(["POST"])
def predict(request):
    """实时预测：加载离线层模型文件，对单笔订单给出延迟概率与风险等级。"""
    try:
        result = predictor.predict(request.data)
    except ValueError as exc:
        return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
    except FileNotFoundError:
        return Response(
            {"detail": "模型文件未找到，请确认共享目录下存在 w1_model.pkl"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )
    result["model_name"] = predictor.load_bundle()["model_name"]
    result["mode"] = "实时预测：按离线层训练的随机森林管道对单笔订单打分"
    return Response(result)
