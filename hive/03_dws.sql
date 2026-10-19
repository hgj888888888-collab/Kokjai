-- ============================================================
-- DWS 层：多维主题汇总表
-- 表名与任务书 6.3 节一致，共六张：
--   1. dws_order_wide          订单宽表（订单、商品、物流与时间特征）
--   2. dws_country_risk        国别与市场维度（订单量、营收、延迟率），仅用于描述性看板
--   3. dws_shipping_risk       物流方式维度（订单量、延迟率），支撑 W2
--   4. dws_category_risk       商品类目与部门维度（订单量、延迟率），支撑 W3
--   5. dws_product_traffic     商品流量维度（日访问量与访问时段分布），支撑 W5
--   6. dws_product_conversion  跨域商品宽表（浏览量、下单量、转化率），支撑 W4
--
-- 前置条件：
--   1) 01_ods.sql 与 02_dwd.sql 已在真实 Hive 上执行通过
--   2) 执行本脚本，Hive 命令必须加 LANG=C.UTF-8，否则中文注释乱码：
--        docker cp 03_dws.sql hive-server:/tmp/
--        docker exec hive-server bash -c "LANG=C.UTF-8 hive -f /tmp/03_dws.sql"
--
-- 说明：
--   - 全部 INSERT 使用 OVERWRITE，可安全重跑
--   - 订单级统计一律来自 dwd_order_main（已按 Order Id 聚合到订单粒度）
--   - dws_order_wide 按月分区，与 DWD 一致，便于按 2015 至 2016、2017 至 2018 做时序划分
--   - 延迟标签 late_delivery_risk 在宽表中保留，供告警与建模取标签；
--     但它连同 days_for_shipping_real、delivery_status 都是结果字段，建模时不得作为特征
-- ============================================================

CREATE DATABASE IF NOT EXISTS bishe_dws COMMENT '跨境电商订单预警系统 汇总层';

USE bishe_dws;

-- 动态分区设置。dws_order_wide 按 dt 动态分区写入，
-- 不设 nonstrict 会报 Error 10096（strict 模式要求至少一个静态分区列）。
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
SET hive.exec.max.dynamic.partitions = 2000;
SET hive.exec.max.dynamic.partitions.pernode = 2000;

-- ------------------------------------------------------------
-- 1. 订单宽表（订单粒度，一个订单一行）
--    在 dwd_order_main 基础上补充金额档位与下单时段，
--    金额档位供 W6 风险分级区分高金额与低金额订单，
--    时段仅用于趋势展示（订单时间字段已实测分布均匀、无季节性）。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_order_wide;

CREATE TABLE IF NOT EXISTS dws_order_wide (
    order_id                    STRING    COMMENT '订单号',
    order_datetime              TIMESTAMP COMMENT '下单时间',
    order_year                  INT       COMMENT '下单年份',
    order_month                 INT       COMMENT '下单月份',
    order_day                   INT       COMMENT '下单日',
    order_hour                  INT       COMMENT '下单小时',
    order_week                  INT       COMMENT '下单周序号',
    order_weekday               INT       COMMENT '下单星期(0=周一,6=周日)',
    is_weekend                  INT       COMMENT '是否周末(1=是)',
    time_period                 STRING    COMMENT '下单时段(凌晨/上午/下午/晚间)',
    payment_type                STRING    COMMENT '支付方式',
    shipping_mode               STRING    COMMENT '物流方式(核心特征)',
    days_for_shipment_scheduled INT       COMMENT '计划发货天数(核心特征)',
    item_line_cnt               INT       COMMENT '订单明细行数',
    product_cnt                 INT       COMMENT '订单内商品种类数',
    category_cnt                INT       COMMENT '订单内类目数',
    department_cnt              INT       COMMENT '订单内部门数',
    total_quantity              INT       COMMENT '订单总件数',
    total_sales                 DOUBLE    COMMENT '订单销售额合计(未扣折扣)',
    total_discount              DOUBLE    COMMENT '订单折扣合计',
    total_net_amount            DOUBLE    COMMENT '订单净额合计',
    avg_item_price              DOUBLE    COMMENT '明细单价均值',
    benefit_per_order           DOUBLE    COMMENT '每单利润',
    main_category_name          STRING    COMMENT '主类目(销售额最大的类目)',
    main_department_name        STRING    COMMENT '主部门(销售额最大的部门)',
    customer_id                 STRING    COMMENT '客户号',
    market                      STRING    COMMENT '市场大区',
    order_region                STRING    COMMENT '订单区域',
    order_country               STRING    COMMENT '目的国',
    order_state                 STRING    COMMENT '目的州省',
    order_city                  STRING    COMMENT '目的城市',
    latitude                    DOUBLE    COMMENT '目的国纬度',
    longitude                   DOUBLE    COMMENT '目的国经度',
    amount_level                STRING    COMMENT '订单金额档位(按净额三分位取低/中/高)',
    late_delivery_risk          INT       COMMENT '延迟交付标签(1=延迟,供取标签,不得作特征)',
    days_for_shipping_real      INT       COMMENT '实际发货天数(结果字段,不得作特征)'
)
COMMENT '订单宽表，含订单、商品、物流与时间特征，一个订单一行'
PARTITIONED BY (dt STRING COMMENT '分区月份 yyyy-MM')
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_order_wide PARTITION (dt)
SELECT
    order_id,
    order_datetime,
    order_year,
    order_month,
    order_day,
    order_hour,
    order_week,
    order_weekday,
    is_weekend,
    CASE WHEN order_hour BETWEEN 0  AND 5  THEN '凌晨'
         WHEN order_hour BETWEEN 6  AND 11 THEN '上午'
         WHEN order_hour BETWEEN 12 AND 17 THEN '下午'
         ELSE '晚间' END                                          AS time_period,
    payment_type,
    shipping_mode,
    days_for_shipment_scheduled,
    item_line_cnt,
    product_cnt,
    category_cnt,
    department_cnt,
    total_quantity,
    total_sales,
    total_discount,
    total_net_amount,
    avg_item_price,
    benefit_per_order,
    main_category_name,
    main_department_name,
    customer_id,
    market,
    order_region,
    order_country,
    order_state,
    order_city,
    latitude,
    longitude,
    CASE amount_tile WHEN 1 THEN '低' WHEN 2 THEN '中' ELSE '高' END   AS amount_level,
    late_delivery_risk,
    days_for_shipping_real,
    dt
FROM (
    SELECT
        m.*,
        NTILE(3) OVER (ORDER BY m.total_net_amount ASC, m.order_id ASC) AS amount_tile
    FROM bishe_dwd.dwd_order_main m
) t;

-- ------------------------------------------------------------
-- 2. 国别与市场维度（描述性看板，用于地图与营收分布）
--    目的国延迟率经检验统计不显著（p 值 0.09 至 0.11），
--    故本表只承载订单量与营收分布，不参与告警。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_country_risk;

CREATE TABLE IF NOT EXISTS dws_country_risk (
    market           STRING  COMMENT '市场大区',
    order_country    STRING  COMMENT '目的国',
    order_cnt        BIGINT  COMMENT '订单数',
    total_revenue    DOUBLE  COMMENT '营收合计(订单净额)',
    avg_order_amount DOUBLE  COMMENT '平均单笔金额',
    delay_rate       DOUBLE  COMMENT '延迟率百分比',
    order_share      DOUBLE  COMMENT '订单量占全站比例百分比',
    latitude         DOUBLE  COMMENT '目的国纬度',
    longitude        DOUBLE  COMMENT '目的国经度'
)
COMMENT '国别与市场维度汇总，仅用于描述性看板'
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_country_risk
SELECT
    market,
    order_country,
    order_cnt,
    total_revenue,
    avg_order_amount,
    delay_rate,
    ROUND(order_cnt / SUM(order_cnt) OVER () * 100, 4) AS order_share,
    latitude,
    longitude
FROM (
    SELECT
        market,
        order_country,
        COUNT(*)                                     AS order_cnt,
        ROUND(SUM(total_net_amount), 2)              AS total_revenue,
        ROUND(AVG(total_net_amount), 2)              AS avg_order_amount,
        ROUND(AVG(late_delivery_risk) * 100, 2)      AS delay_rate,
        MAX(latitude)                                AS latitude,
        MAX(longitude)                               AS longitude
    FROM bishe_dwd.dwd_order_main
    GROUP BY market, order_country
) t;

-- ------------------------------------------------------------
-- 3. 物流方式维度（支撑 W2）
--    实测 First Class 95.3%、Second Class 76.7%、Same Day 46.2%、
--    Standard Class 38.1%，极差 57.1 个百分点，全站 54.8%
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_shipping_risk;

CREATE TABLE IF NOT EXISTS dws_shipping_risk (
    shipping_mode        STRING  COMMENT '物流方式',
    scheduled_days       INT     COMMENT '承诺发货天数',
    order_cnt            BIGINT  COMMENT '订单数',
    total_revenue        DOUBLE  COMMENT '营收合计',
    avg_actual_days      DOUBLE  COMMENT '实际发货天数均值',
    delay_rate           DOUBLE  COMMENT '延迟率百分比',
    order_share          DOUBLE  COMMENT '订单量占全站比例百分比',
    dlt_scheduled_days   DOUBLE  COMMENT '实际天数减承诺天数'
)
COMMENT '物流方式维度汇总，支撑 W2 物流方式履约风险告警'
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_shipping_risk
SELECT
    shipping_mode,
    scheduled_days,
    order_cnt,
    total_revenue,
    avg_actual_days,
    delay_rate,
    ROUND(order_cnt / SUM(order_cnt) OVER () * 100, 4) AS order_share,
    ROUND(avg_actual_days - scheduled_days, 4)         AS dlt_scheduled_days
FROM (
    SELECT
        shipping_mode,
        MAX(days_for_shipment_scheduled)          AS scheduled_days,
        COUNT(*)                                  AS order_cnt,
        ROUND(SUM(total_net_amount), 2)           AS total_revenue,
        ROUND(AVG(days_for_shipping_real), 4)     AS avg_actual_days,
        ROUND(AVG(late_delivery_risk) * 100, 2)   AS delay_rate
    FROM bishe_dwd.dwd_order_main
    GROUP BY shipping_mode
) t;

-- ------------------------------------------------------------
-- 4. 商品类目与部门维度（支撑 W3）
--    粒度为商品类目（主类目口径，一个订单只计入其销售额最大的那个类目），共 50 个类目。
--    注意不能按「部门+类目」分组：Category Id 与 Category Name 并非一一对应，
--    实测 51 个编号对 50 个名称，Electronics 一个名称挂在两个编号下，
--    按部门加类目会多出一行变成 51 个，且订单量与占比会重复计算。
--    部门字段取该类目下订单量最大的那个部门。
--    实测延迟率区间 44.44% 至 70.0%。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_category_risk;

CREATE TABLE IF NOT EXISTS dws_category_risk (
    department_name    STRING  COMMENT '商品部门(该类目下订单量最大的部门)',
    category_name      STRING  COMMENT '商品类目(主类目口径)',
    order_cnt          BIGINT  COMMENT '订单数',
    total_revenue      DOUBLE  COMMENT '营收合计',
    avg_order_amount   DOUBLE  COMMENT '平均单笔金额',
    delay_rate         DOUBLE  COMMENT '延迟率百分比',
    order_share        DOUBLE  COMMENT '订单量占全站比例百分比'
)
COMMENT '商品类目与部门维度汇总，支撑 W3 商品类目履约风险告警'
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_category_risk
SELECT
    d.department_name,
    t.category_name,
    t.order_cnt,
    t.total_revenue,
    t.avg_order_amount,
    t.delay_rate,
    ROUND(t.order_cnt / SUM(t.order_cnt) OVER () * 100, 4) AS order_share
FROM (
    SELECT
        main_category_name                       AS category_name,
        COUNT(*)                                 AS order_cnt,
        ROUND(SUM(total_net_amount), 2)          AS total_revenue,
        ROUND(AVG(total_net_amount), 2)          AS avg_order_amount,
        ROUND(AVG(late_delivery_risk) * 100, 2)  AS delay_rate
    FROM bishe_dwd.dwd_order_main
    GROUP BY main_category_name
) t
LEFT JOIN (
    SELECT category_name, department_name
    FROM (
        SELECT category_name,
               department_name,
               ROW_NUMBER() OVER (PARTITION BY category_name ORDER BY dept_cnt DESC, department_name ASC) AS rn
        FROM (
            SELECT main_category_name   AS category_name,
                   main_department_name AS department_name,
                   COUNT(*)             AS dept_cnt
            FROM bishe_dwd.dwd_order_main
            GROUP BY main_category_name, main_department_name
        ) g
    ) x
    WHERE rn = 1
) d ON t.category_name = d.category_name;

-- ------------------------------------------------------------
-- 5. 商品流量维度（支撑 W5 与看板）
--    粒度为商品乘日期，同时承载日访问量与四个时段分布。
--    时段按访问小时划分，凌晨 0 至 5、上午 6 至 11、下午 12 至 17、晚间 18 至 23。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_product_traffic;

CREATE TABLE IF NOT EXISTS dws_product_traffic (
    product_key       STRING  COMMENT '商品键(小写去首尾空格)',
    product           STRING  COMMENT '商品名(原始)',
    category          STRING  COMMENT '商品类目',
    department        STRING  COMMENT '商品部门',
    access_date       STRING  COMMENT '访问日期 yyyy-MM-dd',
    access_month      INT     COMMENT '访问月份',
    access_weekday    INT     COMMENT '访问星期(0=周一,6=周日)',
    is_weekend        INT     COMMENT '是否周末(1=是)',
    views             BIGINT  COMMENT '当日访问量',
    unique_ip_cnt     BIGINT  COMMENT '当日独立IP数',
    views_dawn        BIGINT  COMMENT '凌晨0至5点访问量',
    views_morning     BIGINT  COMMENT '上午6至11点访问量',
    views_afternoon   BIGINT  COMMENT '下午12至17点访问量',
    views_evening     BIGINT  COMMENT '晚间18至23点访问量'
)
COMMENT '商品流量维度汇总，含日访问量与访问时段分布，支撑 W5 与看板'
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_product_traffic
SELECT
    product_key,
    MAX(product)      AS product,
    MAX(category)     AS category,
    MAX(department)   AS department,
    access_date,
    MAX(access_month) AS access_month,
    MAX(access_weekday) AS access_weekday,
    MAX(is_weekend)   AS is_weekend,
    COUNT(*)          AS views,
    COUNT(DISTINCT ip) AS unique_ip_cnt,
    SUM(CASE WHEN access_hour BETWEEN 0  AND 5  THEN 1 ELSE 0 END) AS views_dawn,
    SUM(CASE WHEN access_hour BETWEEN 6  AND 11 THEN 1 ELSE 0 END) AS views_morning,
    SUM(CASE WHEN access_hour BETWEEN 12 AND 17 THEN 1 ELSE 0 END) AS views_afternoon,
    SUM(CASE WHEN access_hour BETWEEN 18 AND 23 THEN 1 ELSE 0 END) AS views_evening
FROM bishe_dwd.dwd_access_log
GROUP BY product_key, access_date;

-- ------------------------------------------------------------
-- 6. 跨域商品宽表（支撑 W4）
--    必须截取两源共同时间窗口 2017-09 至 2018-01，否则分子分母时间口径不一致。
--    分子用含该商品的唯一订单数，直接取明细表统计，
--    严禁先把订单按 Order Id 去重留首行，否则多商品订单会被误算给首个商品，
--    转化率将被系统性低估约 2.6 倍。
--    商品名匹配：订单侧做 lower(trim()) 归一，与流量侧 product_key 对齐。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dws_product_conversion;

CREATE TABLE IF NOT EXISTS dws_product_conversion (
    product_key       STRING  COMMENT '商品键(小写去首尾空格)',
    product           STRING  COMMENT '商品名',
    category          STRING  COMMENT '商品类目',
    department        STRING  COMMENT '商品部门',
    views             BIGINT  COMMENT '浏览量(共同窗口内)',
    unique_ip_cnt     BIGINT  COMMENT '独立IP数',
    active_days       BIGINT  COMMENT '有访问的天数',
    orders            BIGINT  COMMENT '含该商品的唯一订单数',
    conv_rate         DOUBLE  COMMENT '转化率百分比=下单量除以浏览量乘100',
    first_access_date STRING  COMMENT '首次访问日期',
    last_access_date  STRING  COMMENT '最近访问日期'
)
COMMENT '跨域商品宽表，含浏览量、下单量与转化率，支撑 W4 订单转化异常预警'
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_product_conversion
SELECT
    v.product_key,
    v.product,
    v.category,
    v.department,
    v.views,
    v.unique_ip_cnt,
    v.active_days,
    NVL(o.orders, 0)                                    AS orders,
    ROUND(NVL(o.orders, 0) / v.views * 100, 6)          AS conv_rate,
    v.first_access_date,
    v.last_access_date
FROM (
    SELECT
        product_key,
        MAX(product)                          AS product,
        MAX(category)                         AS category,
        MAX(department)                       AS department,
        COUNT(*)                              AS views,
        COUNT(DISTINCT ip)                    AS unique_ip_cnt,
        COUNT(DISTINCT access_date)           AS active_days,
        MIN(access_date)                      AS first_access_date,
        MAX(access_date)                      AS last_access_date
    FROM bishe_dwd.dwd_access_log
    WHERE dt BETWEEN '2017-09' AND '2018-01'
    GROUP BY product_key
) v
LEFT JOIN (
    SELECT
        lower(trim(product_name)) AS product_key,
        COUNT(DISTINCT order_id)  AS orders
    FROM bishe_dwd.dwd_order_detail
    WHERE dt BETWEEN '2017-09' AND '2018-01'
    GROUP BY lower(trim(product_name))
) o ON v.product_key = o.product_key;

-- ============================================================
-- 加载校验
-- ============================================================

-- 校验一：订单宽表行数与分区覆盖，预期 65752 行、37 个月份
SELECT
    COUNT(*)          AS order_cnt,
    COUNT(DISTINCT dt) AS month_cnt
FROM dws_order_wide;

-- 校验二：金额档位分布，预期低中高各约三分之一
SELECT amount_level, COUNT(*) AS order_cnt
FROM dws_order_wide
GROUP BY amount_level
ORDER BY amount_level;

-- 校验三：W2 物流方式维度，延迟率应与 DWD 一致
SELECT shipping_mode, scheduled_days, order_cnt, avg_actual_days, delay_rate
FROM dws_shipping_risk
ORDER BY delay_rate DESC;

-- 校验四：W3 类目维度，预期 50 个类目，延迟率区间 44.44% 至 70.0%
--         （文档旧记的 40.0% 至 65.5% 在多种口径下均不可复现，以本次实测为准）
SELECT
    COUNT(*)                       AS category_cnt,
    ROUND(MIN(delay_rate), 2)      AS min_delay_rate,
    ROUND(MAX(delay_rate), 2)      AS max_delay_rate,
    ROUND(SUM(order_share), 2)     AS share_sum
FROM dws_category_risk;

-- 校验五：国别维度，预期 164 个目的国、5 个市场大区
SELECT
    COUNT(DISTINCT order_country) AS country_cnt,
    COUNT(DISTINCT market)        AS market_cnt,
    COUNT(*)                      AS row_cnt
FROM dws_country_risk;

-- 校验六：商品流量维度，预期 76 个商品、日访问量合计 469977
SELECT
    COUNT(DISTINCT product_key) AS product_cnt,
    SUM(views)                  AS total_views,
    COUNT(*)                    AS row_cnt
FROM dws_product_traffic;

-- 校验七：跨域商品宽表
--   本表保留全部有流量的商品共 76 个（含零成交商品，orders 为 0）。
--   W4 的「可关联商品」指其中在订单侧也有成交的，即 orders > 0，共 36 个。
--   预期：可关联 36 个、全站平均转化率 1.646%、逐商品均值 1.0968%
SELECT
    COUNT(*)                                                   AS traffic_products,
    SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END)                AS matched_products,
    ROUND(SUM(orders) / SUM(views) * 100, 4)                   AS overall_conv_rate_all,
    ROUND(AVG(conv_rate), 4)                                   AS avg_conv_rate_all
FROM dws_product_conversion;

SELECT
    COUNT(*)                                                   AS matched_products,
    ROUND(SUM(orders) / SUM(views) * 100, 4)                   AS overall_conv_rate,
    ROUND(AVG(conv_rate), 4)                                   AS avg_product_conv_rate,
    SUM(orders)                                                AS total_orders,
    SUM(views)                                                 AS total_views
FROM dws_product_conversion
WHERE orders > 0;

-- 校验七之二：W4 极差与异常组，预期极差 122.7 倍、异常组 8 个商品
--             合计浏览 58440 次、成交 26 单、组内转化率 0.0445%
SELECT '极差(浏览量大于1000的可关联商品)' AS k;
SELECT COUNT(*) AS n, ROUND(MAX(conv_rate)/MIN(conv_rate), 1) AS ratio
FROM dws_product_conversion WHERE orders > 0 AND views > 1000;

SELECT '异常组(最低四分位8个)' AS k;
SELECT COUNT(*) AS n, SUM(views) AS sum_views, SUM(orders) AS sum_orders,
       ROUND(SUM(orders)/SUM(views)*100, 4) AS group_conv_rate
FROM (
    SELECT * FROM dws_product_conversion
    WHERE orders > 0 AND views > 1000
    ORDER BY conv_rate ASC
    LIMIT 8
) t;

-- 校验八：W5 全站日访问量与异常日，预期 2017-09-14 为 45648 次
SELECT
    access_date,
    SUM(views) AS daily_views
FROM dws_product_traffic
GROUP BY access_date
ORDER BY daily_views DESC
LIMIT 5;
