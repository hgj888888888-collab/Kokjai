/* 跨境电商订单预警系统 看板前端 */

const API = "/api";
const PALETTE = ["#0B3B8C", "#1E6BD6", "#7FB3F0", "#EFA3B6", "#5A8FD8", "#C2607C"];

const AXIS_LABEL = { color: "#6C7C96", fontSize: 11 };
const AXIS_LINE = { lineStyle: { color: "#D6E0EF" } };
const SPLIT_LINE = { lineStyle: { color: "#EDF2F9" } };

const charts = {};
let dashboardData = null;
const orderState = { page: 1, size: 12, risk: "", shipping: "", q: "" };
const ticketState = { page: 1, size: 12, warn_type: "", handle_status: "", q: "" };

/* 五个页面用 hash 路由切换，图表按进入该页时才渲染。
   隐藏的容器宽高为 0，提前渲染会让图表量不到尺寸，故必须懒渲染。 */
const VIEWS = ["overview", "risk", "traffic", "orders", "tickets"];
const VIEW_CHARTS = {
  overview: ["chart-risk-pie", "chart-monthly", "chart-map"],
  risk: ["chart-ship-pie", "chart-ship-bar", "chart-cat-bar"],
  traffic: ["chart-traffic"],
  orders: [],
  tickets: [],
};
const rendered = {};

async function getJSON(url) {
  const resp = await fetch(url, { headers: { Accept: "application/json" } });
  if (!resp.ok) throw new Error("请求失败 " + resp.status + " " + url);
  return resp.json();
}

async function postJSON(url, body) {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.detail || JSON.stringify(data));
  return data;
}

function fmtNumber(value) {
  if (value === null || value === undefined) return "-";
  return Number(value).toLocaleString("zh-CN");
}

function fmtPercent(value, digits) {
  if (value === null || value === undefined) return "-";
  return Number(value).toFixed(digits === undefined ? 2 : digits) + "%";
}

function riskBadge(level) {
  const cls = level === "高" ? "badge-high" : level === "中" ? "badge-mid" : "badge-low";
  return '<span class="badge ' + cls + '">' + level + "</span>";
}

function initChart(id) {
  const dom = document.getElementById(id);
  if (!dom) return null;
  if (!charts[id]) charts[id] = echarts.init(dom);
  return charts[id];
}

function baseGrid(extra) {
  return Object.assign({ left: 48, right: 24, top: 30, bottom: 36, containLabel: true }, extra || {});
}

/* ---------------- 看板 ---------------- */

function renderKpi(ov) {
  const cards = [
    { label: "订单总量", value: fmtNumber(ov.total_orders), unit: "单" },
    { label: "全站延迟率", value: fmtPercent(ov.delay_rate, 1), cls: "accent-pink" },
    { label: "预警订单量", value: fmtNumber(ov.alert_orders), unit: "单", cls: "accent-sky" },
    { label: "高风险订单", value: fmtNumber(ov.high_orders), unit: "单", cls: "accent-pink" },
    { label: "预警命中率", value: fmtPercent(ov.hit_rate, 1) },
    { label: "误报率", value: fmtPercent(ov.false_alarm_rate, 1), cls: "accent-sky" },
    { label: "工单总量", value: fmtNumber(ov.ticket_cnt), unit: "张" },
    { label: "已处置工单", value: fmtNumber(ov.handled_cnt), unit: "张" },
  ];
  document.getElementById("kpi-row").innerHTML = cards
    .map(function (c) {
      return (
        '<div class="kpi ' + (c.cls || "") + '">' +
        '<div class="kpi-label">' + c.label + "</div>" +
        '<div class="kpi-value">' + c.value + (c.unit ? "<small>" + c.unit + "</small>" : "") + "</div>" +
        "</div>"
      );
    })
    .join("");
}

function renderModelMeta(model, ov) {
  /* 接口里的 metrics 是按模型名分层的字典，要取出当前模型自己那一档指标 */
  const m = (model.metrics && model.metrics[model.model_name]) || {};
  const auc = m.auc === undefined ? "-" : Number(m.auc).toFixed(4);
  const f1 = m.f1 === undefined ? "-" : Number(m.f1).toFixed(4);
  document.getElementById("model-meta").innerHTML =
    '<span class="tag">模型 ' + model.model_name +
    "　测试期 AUC " + auc +
    "　F1 " + f1 +
    "　平均延迟概率 " + fmtPercent(ov.avg_prob * 100, 1) + "</span>";
}

function drawRiskPie(data) {
  const chart = initChart("chart-risk-pie");
  if (!chart) return;
  const colors = { 高: "#C2607C", 中: "#1E6BD6", 低: "#7FB3F0" };
  chart.setOption({
    tooltip: { trigger: "item", formatter: "{b}风险　{c} 单（{d}%）" },
    legend: { bottom: 0, icon: "circle", textStyle: { color: "#6C7C96", fontSize: 12 } },
    series: [{
      type: "pie",
      radius: ["38%", "58%"],
      center: ["50%", "46%"],
      avoidLabelOverlap: true,
      itemStyle: { borderColor: "#fff", borderWidth: 2 },
      label: { formatter: "{b}\n{d}%", color: "#16233A", fontSize: 11 },
      labelLine: { length: 10, length2: 8 },
      data: data.map(function (d) {
        return { name: d.name, value: d.value, itemStyle: { color: colors[d.name] || "#7FB3F0" } };
      }),
    }],
  });
}

function drawShipPie(data) {
  const chart = initChart("chart-ship-pie");
  if (!chart) return;
  chart.setOption({
    tooltip: { trigger: "item", formatter: "{b}　{d}%" },
    legend: { bottom: 0, icon: "circle", textStyle: { color: "#6C7C96", fontSize: 12 } },
    series: [{
      type: "pie",
      radius: ["34%", "56%"],
      center: ["50%", "46%"],
      avoidLabelOverlap: true,
      minShowLabelAngle: 6,
      itemStyle: { borderColor: "#fff", borderWidth: 2 },
      label: { formatter: "{d}%", color: "#16233A", fontSize: 11 },
      labelLine: { length: 12, length2: 8 },
      data: data.map(function (d, i) {
        return { name: d.name, value: d.order_cnt, itemStyle: { color: PALETTE[i % PALETTE.length] } };
      }),
    }],
  });
}

function drawShipBar(data) {
  const chart = initChart("chart-ship-bar");
  if (!chart) return;
  const baseline = data.length ? data[0].baseline_rate : 0;
  /* 基线数值改放副标题，避免标记线文字与柱顶数值标签重叠 */
  const note = document.getElementById("ship-note");
  if (note) note.textContent = "虚线为全站基线 " + baseline + "%，柱高为各方式延迟率";
  chart.setOption({
    tooltip: {
      trigger: "axis",
      formatter: function (params) {
        const p = params[0];
        const row = data[p.dataIndex];
        return p.name + "<br/>延迟率 " + row.delay_rate + "%" +
          "<br/>基线 " + row.baseline_rate + "%" +
          "<br/>偏离 " + row.deviation_pp + " 个百分点" +
          "<br/>订单量 " + fmtNumber(row.order_cnt) + " 单";
      },
    },
    grid: baseGrid({ bottom: 48 }),
    xAxis: {
      type: "category",
      data: data.map(function (d) { return d.name; }),
      /* 四个物流方式名称较长，拆成两行写，避免横轴标签互相挤压被自动隐藏 */
      axisLabel: Object.assign({}, AXIS_LABEL, { interval: 0, formatter: function (v) { return v.replace(" ", "\n"); } }),
      axisLine: AXIS_LINE,
    },
    yAxis: { type: "value", name: "延迟率 %", nameTextStyle: AXIS_LABEL, axisLabel: AXIS_LABEL, axisLine: AXIS_LINE, splitLine: SPLIT_LINE },
    series: [{
      type: "bar",
      barWidth: "46%",
      data: data.map(function (d) {
        return { value: d.delay_rate, itemStyle: { color: d.alert_flag ? "#EFA3B6" : "#1E6BD6", borderRadius: [6, 6, 0, 0] } };
      }),
      label: { show: true, position: "top", formatter: "{c}%", color: "#6C7C96", fontSize: 11 },
      markLine: {
        silent: true,
        symbol: "none",
        lineStyle: { type: "dashed", color: "#0B3B8C" },
        label: { show: false },
        data: [{ yAxis: baseline }],
      },
    }],
  });
}

function drawCatBar(data) {
  const chart = initChart("chart-cat-bar");
  if (!chart) return;
  const rows = data.slice().sort(function (a, b) { return a.delay_rate - b.delay_rate; });
  const baseline = rows.length ? rows[0].baseline_rate : 0;
  /* 十五个类目全部显示，基线数值挪到副标题，避免图内文字挤压 */
  const note = document.getElementById("cat-note");
  if (note) note.textContent = "按订单量取前十五个类目，虚线为全站基线 " + baseline + "%，类目效应经检验不显著，仅作描述性监控";
  chart.setOption({
    tooltip: {
      trigger: "axis",
      formatter: function (params) {
        const row = rows[params[0].dataIndex];
        return row.name + "<br/>延迟率 " + row.delay_rate + "%<br/>基线 " + row.baseline_rate +
          "%<br/>订单量 " + fmtNumber(row.order_cnt) + " 单";
      },
    },
    grid: baseGrid({ left: 140, right: 56, top: 20, bottom: 42 }),
    xAxis: {
      type: "value",
      name: "延迟率 %",
      nameLocation: "middle",
      nameGap: 24,
      nameTextStyle: AXIS_LABEL,
      axisLabel: AXIS_LABEL,
      axisLine: AXIS_LINE,
      splitLine: SPLIT_LINE,
    },
    yAxis: { type: "category", data: rows.map(function (d) { return d.name; }), axisLabel: Object.assign({}, AXIS_LABEL, { fontSize: 10 }), axisLine: AXIS_LINE, interval: 0 },
    series: [{
      type: "bar",
      barWidth: "55%",
      data: rows.map(function (d) {
        return { value: d.delay_rate, itemStyle: { color: d.alert_flag ? "#EFA3B6" : "#7FB3F0", borderRadius: [0, 6, 6, 0] } };
      }),
      label: { show: true, position: "right", formatter: "{c}%", color: "#6C7C96", fontSize: 10 },
      markLine: {
        silent: true,
        symbol: "none",
        lineStyle: { type: "dashed", color: "#0B3B8C" },
        label: { show: false },
        data: [{ xAxis: baseline }],
      },
    }],
  });
}

function drawMonthly(data) {
  const chart = initChart("chart-monthly");
  if (!chart) return;
  chart.setOption({
    tooltip: { trigger: "axis" },
    legend: { bottom: 0, icon: "circle", textStyle: { color: "#6C7C96", fontSize: 12 } },
    grid: baseGrid({ bottom: 46 }),
    xAxis: {
      type: "category",
      data: data.map(function (d) { return d.month; }),
      axisLabel: Object.assign({}, AXIS_LABEL, { rotate: 45 }),
      axisLine: AXIS_LINE,
    },
    yAxis: [
      { type: "value", name: "订单量", nameTextStyle: AXIS_LABEL, axisLabel: AXIS_LABEL, axisLine: AXIS_LINE, splitLine: SPLIT_LINE },
      { type: "value", name: "延迟概率 %", nameTextStyle: AXIS_LABEL, axisLabel: AXIS_LABEL, axisLine: AXIS_LINE, splitLine: { show: false } },
    ],
    series: [
      {
        name: "订单量",
        type: "line",
        smooth: true,
        symbolSize: 6,
        lineStyle: { width: 2, color: "#1E6BD6" },
        itemStyle: { color: "#1E6BD6" },
        areaStyle: { color: "rgba(30,107,214,0.10)" },
        data: data.map(function (d) { return d.order_cnt; }),
      },
      {
        name: "平均延迟概率",
        type: "line",
        yAxisIndex: 1,
        smooth: true,
        symbolSize: 6,
        lineStyle: { width: 2, color: "#EFA3B6" },
        itemStyle: { color: "#EFA3B6" },
        data: data.map(function (d) { return Number((d.avg_prob * 100).toFixed(2)); }),
      },
    ],
  });
}

function drawTraffic(data) {
  const chart = initChart("chart-traffic");
  if (!chart) return;
  const first = data[0] || { avg_visits: 0, std_visits: 0 };
  const upper = Number((first.avg_visits + 3 * first.std_visits).toFixed(2));
  const lower = Number(Math.max(0, first.avg_visits - 3 * first.std_visits).toFixed(2));
  chart.setOption({
    tooltip: {
      trigger: "axis",
      formatter: function (params) {
        const row = data[params[0].dataIndex];
        return row.date + "<br/>访问量 " + fmtNumber(row.visits) +
          "<br/>偏离倍数 " + row.z_score + "<br/>状态 " + row.alert_level;
      },
    },
    grid: baseGrid({ bottom: 40 }),
    xAxis: { type: "category", data: data.map(function (d) { return d.date; }), axisLabel: Object.assign({}, AXIS_LABEL, { rotate: 45 }), axisLine: AXIS_LINE },
    yAxis: { type: "value", name: "访问量", nameTextStyle: AXIS_LABEL, axisLabel: AXIS_LABEL, axisLine: AXIS_LINE, splitLine: SPLIT_LINE },
    series: [{
      name: "日访问量",
      type: "line",
      smooth: true,
      lineStyle: { width: 2, color: "#0B3B8C" },
      itemStyle: { color: "#0B3B8C" },
      areaStyle: { color: "rgba(11,59,140,0.08)" },
      data: data.map(function (d) {
        return { value: d.visits, itemStyle: { color: d.alert_flag ? "#EFA3B6" : "#0B3B8C" } };
      }),
      markLine: {
        silent: true,
        symbol: "none",
        lineStyle: { type: "dashed", color: "#EFA3B6" },
        label: { color: "#C2607C", fontSize: 11, formatter: function (p) { return p.name; } },
        data: [
          { yAxis: upper, name: "上限 " + upper },
          { yAxis: lower, name: "下限 " + lower },
        ],
      },
    }],
  });
}

function drawMap(data) {
  const chart = initChart("chart-map");
  if (!chart) return;
  const rates = data.map(function (d) { return d.delay_rate; });
  const minRate = Math.min.apply(null, rates);
  const maxRate = Math.max.apply(null, rates);
  chart.setOption({
    tooltip: {
      trigger: "item",
      formatter: function (p) {
        if (!p.data) return p.name || "";
        return p.data.origin + "<br/>延迟率 " + p.data.value +
          "%<br/>订单量 " + fmtNumber(p.data.cnt) + " 单<br/>订单占比 " + p.data.share + "%";
      },
    },
    visualMap: {
      type: "continuous",
      min: Math.floor(minRate),
      max: Math.ceil(maxRate),
      left: 16,
      bottom: 24,
      text: ["高延迟率", "低延迟率"],
      textStyle: { color: "#6C7C96", fontSize: 11 },
      inRange: { color: ["#7FB3F0", "#1E6BD6", "#0B3B8C", "#EFA3B6"] },
      calculable: true,
    },
    series: [{
      name: "目的国延迟率",
      type: "map",
      map: "world",
      roam: true,
      zoom: 1.15,
      label: { show: false },
      itemStyle: { areaColor: "#F0F5FD", borderColor: "#D6E0EF" },
      emphasis: { itemStyle: { areaColor: "#E2EDFC" }, label: { show: false } },
      data: data.map(function (d) {
        return { name: d.map_name, value: d.delay_rate, origin: d.name, cnt: d.order_cnt, share: d.order_share };
      }),
    }],
  });
}

function annotateMap(unmapped) {
  const note = document.getElementById("map-note");
  if (!note || !unmapped.length) return;
  const total = unmapped.reduce(function (sum, d) { return sum + d.order_cnt; }, 0);
  note.textContent = note.textContent + "；" +
    unmapped.map(function (d) { return d.name; }).join("、") +
    " 在底图无对应区域，合计 " + total + " 单未着色";
}

function renderConversion(rows) {
  const box = document.getElementById("conversion-list");
  if (!rows.length) { box.innerHTML = '<div class="empty">暂无转化异常记录</div>'; return; }
  box.innerHTML = rows.map(function (r) {
    return (
      '<div class="mini-row">' +
      '<div><div class="mini-name">' + r.product + "</div>" +
      '<div class="mini-meta">' + r.category + "　浏览 " + fmtNumber(r.views) + "　成单 " + fmtNumber(r.orders) + "</div></div>" +
      '<div><span class="badge ' + (r.alert_level === "严重" ? "badge-high" : "badge-mid") + '">' +
      Number(r.conv_rate).toFixed(3) + "%</span></div>" +
      "</div>"
    );
  }).join("");
}

function renderHandleStats(rows) {
  const box = document.getElementById("handle-stats");
  if (!rows.length) { box.innerHTML = '<div class="empty">暂无处置统计</div>'; return; }
  box.innerHTML = rows.map(function (r) {
    const hit = r.hit_rate === null ? "-" : Number(r.hit_rate).toFixed(2) + "%";
    const falseRate = r.false_alarm_rate === null ? "-" : Number(r.false_alarm_rate).toFixed(2) + "%";
    return (
      '<div class="mini-row">' +
      '<div><div class="mini-name">' + r.stat_scope + "　" + r.warn_type + "</div>" +
      '<div class="mini-meta">工单 ' + fmtNumber(r.ticket_cnt) + "　已处理 " + fmtNumber(r.handled_cnt) +
      "　平均处理时长 " + (r.avg_handle_hours === null ? "-" : Number(r.avg_handle_hours).toFixed(2) + " 小时") + "</div></div>" +
      '<div><span class="badge badge-mid">命中 ' + hit + "</span> " +
      '<span class="badge badge-low">误报 ' + falseRate + "</span></div>" +
      "</div>"
    );
  }).join("");
}

async function loadDashboard() {
  const data = await getJSON(API + "/dashboard/");
  dashboardData = data;

  renderKpi(data.overview);
  renderModelMeta(data.model, data.overview);

  const shippingSelect = document.getElementById("order-shipping");
  shippingSelect.innerHTML = '<option value="">全部物流方式</option>' +
    data.shipping.map(function (s) { return '<option value="' + s.name + '">' + s.name + "</option>"; }).join("");

  const worldGeo = await fetch("/static/vendor/world.json").then(function (r) { return r.json(); });
  echarts.registerMap("world", worldGeo);
}

/* ---------------- 页面路由与懒渲染 ---------------- */

function currentView() {
  const hash = (location.hash || "").replace("#", "");
  return VIEWS.indexOf(hash) === -1 ? "overview" : hash;
}

async function renderView(name) {
  const sec = document.getElementById("view-" + name);
  if (!sec || !sec.classList.contains("active")) return;
  if (!dashboardData) return;
  if (rendered[name]) { resizeView(name); return; }
  rendered[name] = true;

  if (name === "overview") {
    drawRiskPie(dashboardData.risk_pie);
    drawMonthly(dashboardData.monthly);
    drawMap(dashboardData.country);
    annotateMap(dashboardData.unmapped_country);
  } else if (name === "risk") {
    drawShipPie(dashboardData.shipping);
    drawShipBar(dashboardData.shipping);
    drawCatBar(dashboardData.category);
  } else if (name === "traffic") {
    drawTraffic(dashboardData.traffic);
    renderConversion(dashboardData.conversion);
  } else if (name === "orders") {
    await loadOrders();
  } else if (name === "tickets") {
    renderHandleStats(await getJSON(API + "/handle-stats/"));
    await loadTickets();
  }
  resizeView(name);
}

function resizeView(name) {
  (VIEW_CHARTS[name] || []).forEach(function (id) {
    if (charts[id]) charts[id].resize();
  });
}

function showView(name) {
  VIEWS.forEach(function (v) {
    const sec = document.getElementById("view-" + v);
    if (sec) sec.classList.toggle("active", v === name);
  });
  Array.prototype.forEach.call(document.querySelectorAll(".tab"), function (t) {
    t.classList.toggle("active", t.dataset.view === name);
  });
  renderView(name);
}

/* ---------------- 订单查询 ---------------- */

function renderOrders(payload) {
  const box = document.getElementById("order-list");
  if (!payload.rows.length) { box.innerHTML = '<div class="empty">没有符合条件的订单</div>'; }
  else {
    box.innerHTML = payload.rows.map(function (r) {
      return (
        '<div class="item">' +
        '<div class="item-head"><span class="item-title">' + r.order_id + "</span>" + riskBadge(r.risk_level) + "</div>" +
        '<div class="item-meta">' + r.order_month + "　" + r.shipping_mode + "　" + r.order_country + "　" + r.main_category_name + "</div>" +
        '<div class="item-foot"><span class="item-meta">延迟概率 ' + Number(r.delay_prob).toFixed(4) +
        "　风险分 " + Number(r.risk_score).toFixed(4) + "</span>" +
        '<span class="badge badge-low">净额 ' + Number(r.total_net_amount).toFixed(2) + "</span></div>" +
        '<div class="item-meta">建议　' + r.suggestion + "</div>" +
        "</div>"
      );
    }).join("");
  }
  const pages = Math.max(1, Math.ceil(payload.total / payload.page_size));
  document.getElementById("order-pager").innerHTML =
    '<button class="btn btn-ghost" id="order-prev">上一页</button>' +
    "<span>第 " + payload.page + " 页　共 " + pages + " 页　合计 " + fmtNumber(payload.total) + " 条</span>" +
    '<button class="btn btn-ghost" id="order-next">下一页</button>';
  document.getElementById("order-prev").addEventListener("click", function () {
    if (orderState.page > 1) { orderState.page -= 1; loadOrders(); }
  });
  document.getElementById("order-next").addEventListener("click", function () {
    if (orderState.page < pages) { orderState.page += 1; loadOrders(); }
  });
}

async function loadOrders() {
  const query = new URLSearchParams({
    page: orderState.page,
    page_size: orderState.size,
    risk: orderState.risk,
    shipping: orderState.shipping,
    q: orderState.q,
  });
  renderOrders(await getJSON(API + "/orders/?" + query.toString()));
}

/* ---------------- 工单查询与处置 ---------------- */

function renderTickets(payload) {
  const box = document.getElementById("ticket-list");
  if (!payload.rows.length) { box.innerHTML = '<div class="empty">没有符合条件的工单</div>'; }
  else {
    box.innerHTML = payload.rows.map(function (t) {
      return (
        '<div class="item" data-ticket="' + t.ticket_id + '">' +
        '<div class="item-head"><span class="item-title">' + t.ticket_id + "</span>" +
        '<span class="badge ' + (t.handle_status === "已处置" ? "badge-mid" : t.handle_status === "待处理" ? "badge-high" : "badge-low") + '">' +
        t.handle_status + "</span></div>" +
        '<div class="item-meta">' + t.warn_type + "　风险等级 " + t.risk_level + "　处理人 " + t.handler + "</div>" +
        '<div class="item-meta">预警对象　' + t.target_id + "</div>" +
        '<div class="item-foot"><span class="item-meta">' + t.create_time + "</span>" +
        '<button class="btn" data-action="handle">' + (t.handle_status === "待处理" ? "处置" : "修改处置") + "</button></div>" +
        '<div class="handle-form" style="display:none;margin-top:12px"></div>' +
        "</div>"
      );
    }).join("");
    Array.prototype.forEach.call(box.querySelectorAll('[data-action="handle"]'), function (btn) {
      btn.addEventListener("click", function () {
        const item = btn.closest(".item");
        const ticket = payload.rows.filter(function (t) { return t.ticket_id === item.dataset.ticket; })[0];
        openHandleForm(item, ticket);
      });
    });
  }
  const pages = Math.max(1, Math.ceil(payload.total / payload.page_size));
  document.getElementById("ticket-pager").innerHTML =
    '<button class="btn btn-ghost" id="ticket-prev">上一页</button>' +
    "<span>第 " + payload.page + " 页　共 " + pages + " 页　合计 " + fmtNumber(payload.total) + " 条</span>" +
    '<button class="btn btn-ghost" id="ticket-next">下一页</button>';
  document.getElementById("ticket-prev").addEventListener("click", function () {
    if (ticketState.page > 1) { ticketState.page -= 1; loadTickets(); }
  });
  document.getElementById("ticket-next").addEventListener("click", function () {
    if (ticketState.page < pages) { ticketState.page += 1; loadTickets(); }
  });
}

function openHandleForm(item, ticket) {
  const box = item.querySelector(".handle-form");
  if (box.style.display !== "none") { box.style.display = "none"; return; }
  box.style.display = "";
  box.innerHTML =
    '<div class="filters" style="margin:0">' +
    '<select class="h-status">' +
    ["待处理", "处理中", "已处置", "已关闭"].map(function (s) {
      return '<option value="' + s + '"' + (s === ticket.handle_status ? " selected" : "") + ">" + s + "</option>";
    }).join("") +
    "</select>" +
    '<input class="h-handler" placeholder="处理人" value="' + (ticket.handler === "未分配" ? "" : ticket.handler) + '">' +
    '<input class="h-action" placeholder="处置动作，如联系承运商" value="' + (ticket.handle_action || "") + '">' +
    '<input class="h-remark" placeholder="备注" value="' + (ticket.remark || "") + '">' +
    '<select class="h-false"><option value="0">非误报</option><option value="1"' + (ticket.is_false_alarm ? " selected" : "") + ">标记为误报</option></select>" +
    "</div>" +
    '<div class="filters" style="margin:10px 0 0"><button class="btn btn-primary" data-action="submit">提交处置</button>' +
    '<span class="h-msg item-meta"></span></div>';
  box.querySelector('[data-action="submit"]').addEventListener("click", async function () {
    const msg = box.querySelector(".h-msg");
    msg.textContent = "提交中";
    const payload = {
      handle_status: box.querySelector(".h-status").value,
      handler: box.querySelector(".h-handler").value,
      handle_action: box.querySelector(".h-action").value,
      remark: box.querySelector(".h-remark").value,
      is_false_alarm: Number(box.querySelector(".h-false").value),
    };
    try {
      await postJSON(API + "/tickets/" + ticket.ticket_id + "/handle/", payload);
      msg.textContent = "已提交";
      await loadTickets();
      renderHandleStats(await getJSON(API + "/handle-stats/"));
    } catch (err) {
      msg.textContent = "提交失败：" + err.message;
    }
  });
}

async function loadTickets() {
  const query = new URLSearchParams({
    page: ticketState.page,
    page_size: ticketState.size,
    warn_type: ticketState.warn_type,
    handle_status: ticketState.handle_status,
    q: ticketState.q,
  });
  const data = await getJSON(API + "/tickets/?" + query.toString());
  const typeSelect = document.getElementById("ticket-type");
  if (typeSelect.options.length <= 1) {
    typeSelect.innerHTML = '<option value="">全部预警类型</option>' +
      data.types.map(function (t) { return '<option value="' + t + '">' + t + "</option>"; }).join("");
  }
  renderTickets(data);
}

/* ---------------- 实时预测 ---------------- */

function renderPredict(res) {
  const level = res.risk_level;
  const cls = level === "高" ? "#C2607C" : level === "中" ? "#1E6BD6" : "#7FB3F0";
  const box = document.getElementById("predict-result");
  box.innerHTML =
    '<div class="result-card">' +
    '<div class="result-label">延迟概率</div>' +
    '<div class="result-value" style="color:' + cls + '">' + (res.delay_prob * 100).toFixed(2) + "%</div>" +
    '<div class="result-label">风险等级 ' + riskBadge(level) + "　预警标记 " + (res.alert_flag ? "触发" : "未触发") + "</div>" +
    '<div class="result-label" style="margin-top:10px">' + res.mode + "　模型 " + res.model_name + "</div>" +
    '<div class="result-features">' +
    Object.keys(res.features).map(function (k) { return "<span>" + k + "：" + res.features[k] + "</span>"; }).join("") +
    "</div></div>";
}

/* ---------------- 事件绑定与启动 ---------------- */

document.getElementById("order-search").addEventListener("click", function () {
  orderState.risk = document.getElementById("order-risk").value;
  orderState.shipping = document.getElementById("order-shipping").value;
  orderState.q = document.getElementById("order-keyword").value.trim();
  orderState.page = 1;
  loadOrders();
});

document.getElementById("ticket-search").addEventListener("click", function () {
  ticketState.warn_type = document.getElementById("ticket-type").value;
  ticketState.handle_status = document.getElementById("ticket-status").value;
  ticketState.q = document.getElementById("ticket-keyword").value.trim();
  ticketState.page = 1;
  loadTickets();
});

document.getElementById("predict-form").addEventListener("submit", async function (event) {
  event.preventDefault();
  const form = event.target;
  const payload = {};
  Array.prototype.forEach.call(form.elements, function (el) {
    if (el.name) payload[el.name] = el.value;
  });
  const box = document.getElementById("predict-result");
  box.innerHTML = '<div class="empty">预测中</div>';
  try {
    renderPredict(await postJSON(API + "/predict/", payload));
  } catch (err) {
    box.innerHTML = '<div class="error">预测失败：' + err.message + "</div>";
  }
});

Array.prototype.forEach.call(document.querySelectorAll(".tab"), function (tab) {
  tab.addEventListener("click", function () {
    const name = tab.dataset.view;
    if (currentView() === name) showView(name);
    else location.hash = name;
  });
});

window.addEventListener("hashchange", function () { showView(currentView()); });

window.addEventListener("resize", function () {
  resizeView(currentView());
});

(async function start() {
  try {
    await loadDashboard();
    showView(currentView());
  } catch (err) {
    console.error(err);
    document.getElementById("kpi-row").innerHTML = '<div class="error">数据加载失败：' + err.message + "</div>";
  }
})();
