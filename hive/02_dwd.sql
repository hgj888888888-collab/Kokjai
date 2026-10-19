-- ============================================================
-- DWD 层：清洗明细层（订单域 + 流量域）
-- 上游：bishe_ods.ods_order_raw / bishe_ods.ods_access_log_raw
-- 建 3 张表：
--   1. dwd_order_detail   清洗后订单明细（行粒度，一行一条订单明细）
--   2. dwd_order_main     订单级主表（按 Order Id 聚合，供 W1 W2 W3 W6）
--   3. dwd_access_log     清洗后访问日志（供 W4 W5）
--
-- 清洗规则：
--   1. 粒度统一：原始表一行不等于一单，平均每单 2.75 行，
--      所有订单级统计统一在 dwd_order_main 中按 Order Id 聚合。
--   2. 折扣率修复：Order Item Discount Rate 标注值有误，
--      统一改用 Order Item Discount 除以 Sales 重算，标注值仅留档。
--   3. 利润字段去冗余：三列利润字段仅保留 Benefit per order。
--   4. 无效列剔除：商品描述（空值率 100%）、客户邮箱与密码（脱敏单值）、
--      商品状态（常量）、订单邮编（缺失率 86.2%）、客户街道、客户姓名、
--      订单客户号（与客户号重复），以上不再向下游传递。
--   5. 日期解析：源格式为 M/d/yyyy H:mm，统一转为 TIMESTAMP，
--      并派生出年、月、周、日、小时、星期、是否周末。
--   6. 商品名归一：订单侧 Product Name 与流量侧 Product 统一小写去首尾空格，
--      作为跨域关联键，两个数据源在共同窗口内重叠商品 72 个。
--   7. 结果字段保留：Late_delivery_risk、Delivery Status、
--      Days for shipping (real) 在明细与主表中保留（W2 W3 需要标签），
--      但建模时必须从特征中剔除，不得进入训练矩阵。
--
-- 主类目口径：一个订单有 67.8% 的概率横跨多个商品类目，
--   订单级聚合时主类目与主部门取该订单内销售额最大的那条明细，
--   平序时按类目名与明细号兜底，保证结果可确定性复现。
--
-- 执行：LANG=C.UTF-8 hive -f 02_dwd.sql
-- ============================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
SET hive.exec.max.dynamic.partitions = 2000;
SET hive.exec.max.dynamic.partitions.pernode = 2000;

CREATE DATABASE IF NOT EXISTS bishe_dwd COMMENT '跨境电商订单预警系统 清洗明细层';

USE bishe_dwd;

-- ------------------------------------------------------------
-- 1. 清洗后订单明细（行粒度）
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dwd_order_detail;

CREATE TABLE IF NOT EXISTS dwd_order_detail (
    order_id                    STRING    COMMENT '订单号',
    order_item_id               STRING    COMMENT '订单明细编号',
    order_datetime              TIMESTAMP COMMENT '下单时间',
    shipping_datetime           TIMESTAMP COMMENT '发货时间',
    order_year                  INT       COMMENT '下单年份',
    order_month                 INT       COMMENT '下单月份',
    order_day                   INT       COMMENT '下单日',
    order_hour                  INT       COMMENT '下单小时',
    order_week                  INT       COMMENT '下单周序号',
    order_weekday               INT       COMMENT '下单星期(0=周一,6=周日)',
    is_weekend                  INT       COMMENT '是否周末(1=是)',
    payment_type                STRING    COMMENT '支付方式',
    order_status                STRING    COMMENT '订单状态(派生标签)',
    shipping_mode               STRING    COMMENT '物流方式',
    days_for_shipment_scheduled INT       COMMENT '计划发货天数',
    days_for_shipping_real      INT       COMMENT '实际发货天数(结果字段,不得入特征)',
    delivery_status             STRING    COMMENT '交付状态(结果字段,不得入特征)',
    late_delivery_risk          INT       COMMENT '延迟交付标签(1=延迟)',
    benefit_per_order           DOUBLE    COMMENT '每单利润',
    category_id                 STRING    COMMENT '商品类目编号',
    category_name               STRING    COMMENT '商品类目',
    department_id               STRING    COMMENT '商品部门编号',
    department_name             STRING    COMMENT '商品部门',
    product_card_id             STRING    COMMENT '商品卡编号',
    product_name                STRING    COMMENT '商品名称',
    product_price               DOUBLE    COMMENT '商品标价',
    order_item_product_price    DOUBLE    COMMENT '明细商品单价',
    order_item_quantity         INT       COMMENT '明细数量',
    sales                       DOUBLE    COMMENT '明细销售额(未扣折扣)',
    order_item_discount         DOUBLE    COMMENT '折扣金额',
    order_item_discount_rate    DOUBLE    COMMENT '折扣率标注值(有误,仅留档)',
    discount_rate_calc          DOUBLE    COMMENT '折扣率重算值=折扣金额除以销售额',
    order_item_total            DOUBLE    COMMENT '明细净额=销售额减折扣',
    customer_id                 STRING    COMMENT '客户号',
    customer_segment            STRING    COMMENT '客户分群(模拟字段,不入特征)',
    customer_city               STRING    COMMENT '客户城市',
    customer_state              STRING    COMMENT '客户州省',
    customer_country            STRING    COMMENT '客户国家',
    market                      STRING    COMMENT '市场大区',
    order_region                STRING    COMMENT '订单区域',
    order_country               STRING    COMMENT '目的国',
    order_state                 STRING    COMMENT '目的州省',
    order_city                  STRING    COMMENT '目的城市',
    latitude                    DOUBLE    COMMENT '目的国纬度',
    longitude                   DOUBLE    COMMENT '目的国经度'
)
COMMENT '清洗后订单明细，行粒度'
PARTITIONED BY (dt STRING COMMENT '分区月份 yyyy-MM')
STORED AS PARQUET;

INSERT OVERWRITE TABLE dwd_order_detail PARTITION (dt)
SELECT
    order_id,
    order_item_id,
    from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm'))         AS order_datetime,
    from_unixtime(unix_timestamp(shipping_date_raw, 'M/d/yyyy H:mm'))      AS shipping_datetime,
    YEAR(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))   AS order_year,
    MONTH(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))  AS order_month,
    DAY(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))    AS order_day,
    HOUR(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))   AS order_hour,
    WEEKOFYEAR(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm'))) AS order_week,
    PMOD(DATEDIFF(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')),
                  '1970-01-05'), 7)                                        AS order_weekday,
    CASE WHEN PMOD(DATEDIFF(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')),
                            '1970-01-05'), 7) >= 5 THEN 1 ELSE 0 END       AS is_weekend,
    payment_type,
    order_status,
    shipping_mode,
    CAST(days_for_shipment_scheduled AS INT)                               AS days_for_shipment_scheduled,
    CAST(days_for_shipping_real AS INT)                                    AS days_for_shipping_real,
    delivery_status,
    CAST(late_delivery_risk AS INT)                                        AS late_delivery_risk,
    CAST(benefit_per_order AS DOUBLE)                                      AS benefit_per_order,
    category_id,
    category_name,
    department_id,
    department_name,
    product_card_id,
    product_name,
    CAST(product_price AS DOUBLE)                                          AS product_price,
    CAST(order_item_product_price AS DOUBLE)                               AS order_item_product_price,
    CAST(order_item_quantity AS INT)                                       AS order_item_quantity,
    CAST(sales AS DOUBLE)                                                  AS sales,
    CAST(order_item_discount AS DOUBLE)                                    AS order_item_discount,
    CAST(order_item_discount_rate AS DOUBLE)                               AS order_item_discount_rate,
    ROUND(CAST(order_item_discount AS DOUBLE) / CAST(sales AS DOUBLE), 6)  AS discount_rate_calc,
    CAST(order_item_total AS DOUBLE)                                       AS order_item_total,
    customer_id,
    customer_segment,
    customer_city,
    customer_state,
    customer_country,
    market,
    order_region,
    order_country,
    order_state,
    order_city,
    CAST(latitude AS DOUBLE)                                               AS latitude,
    CAST(longitude AS DOUBLE)                                              AS longitude,
    date_format(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')), 'yyyy-MM') AS dt
FROM bishe_ods.ods_order_raw
WHERE order_date_raw IS NOT NULL
  AND trim(order_date_raw) <> ''
  AND order_id IS NOT NULL
  AND trim(order_id) <> '';

-- ------------------------------------------------------------
-- 2. 订单级主表（按 Order Id 聚合，一个订单一行）
--    聚合口径：物流方式与计划发货天数在订单内恒定，取一值即可；
--    数量求和、单价均值、销售额求和；
--    主类目与主部门取订单内销售额最大的那条明细；
--    标签与结果字段取最大值（订单内恒定，取最大只为容错）。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dwd_order_main;

CREATE TABLE IF NOT EXISTS dwd_order_main (
    order_id                    STRING    COMMENT '订单号',
    order_datetime              TIMESTAMP COMMENT '下单时间',
    order_year                  INT       COMMENT '下单年份',
    order_month                 INT       COMMENT '下单月份',
    order_day                   INT       COMMENT '下单日',
    order_hour                  INT       COMMENT '下单小时',
    order_week                  INT       COMMENT '下单周序号',
    order_weekday               INT       COMMENT '下单星期(0=周一,6=周日)',
    is_weekend                  INT       COMMENT '是否周末(1=是)',
    payment_type                STRING    COMMENT '支付方式',
    order_status                STRING    COMMENT '订单状态(派生标签)',
    shipping_mode               STRING    COMMENT '物流方式',
    days_for_shipment_scheduled INT       COMMENT '计划发货天数',
    days_for_shipping_real      INT       COMMENT '实际发货天数(结果字段,不得入特征)',
    delivery_status             STRING    COMMENT '交付状态(结果字段,不得入特征)',
    late_delivery_risk          INT       COMMENT '延迟交付标签(1=延迟)',
    benefit_per_order           DOUBLE    COMMENT '每单利润',
    item_line_cnt               INT       COMMENT '订单明细行数',
    product_cnt                 INT       COMMENT '订单内商品种类数',
    category_cnt                INT       COMMENT '订单内类目数',
    department_cnt              INT       COMMENT '订单内部门数',
    total_quantity              INT       COMMENT '订单总件数',
    total_sales                 DOUBLE    COMMENT '订单销售额合计(未扣折扣)',
    total_discount              DOUBLE    COMMENT '订单折扣合计',
    total_net_amount            DOUBLE    COMMENT '订单净额合计',
    avg_item_price              DOUBLE    COMMENT '订单内明细单价均值',
    main_category_name          STRING    COMMENT '主类目(订单内销售额最大的类目)',
    main_department_name        STRING    COMMENT '主部门(订单内销售额最大的部门)',
    customer_id                 STRING    COMMENT '客户号',
    customer_segment            STRING    COMMENT '客户分群(模拟字段,不入特征)',
    customer_city               STRING    COMMENT '客户城市',
    customer_state              STRING    COMMENT '客户州省',
    customer_country            STRING    COMMENT '客户国家',
    market                      STRING    COMMENT '市场大区',
    order_region                STRING    COMMENT '订单区域',
    order_country               STRING    COMMENT '目的国',
    order_state                 STRING    COMMENT '目的州省',
    order_city                  STRING    COMMENT '目的城市',
    latitude                    DOUBLE    COMMENT '目的国纬度',
    longitude                   DOUBLE    COMMENT '目的国经度'
)
COMMENT '订单级主表，一个订单一行'
PARTITIONED BY (dt STRING COMMENT '分区月份 yyyy-MM')
STORED AS PARQUET;

INSERT OVERWRITE TABLE dwd_order_main PARTITION (dt)
SELECT
    d.order_id                                                  AS order_id,
    MAX(d.order_datetime)                                       AS order_datetime,
    MAX(d.order_year)                                           AS order_year,
    MAX(d.order_month)                                          AS order_month,
    MAX(d.order_day)                                            AS order_day,
    MAX(d.order_hour)                                           AS order_hour,
    MAX(d.order_week)                                           AS order_week,
    MAX(d.order_weekday)                                        AS order_weekday,
    MAX(d.is_weekend)                                           AS is_weekend,
    MAX(d.payment_type)                                         AS payment_type,
    MAX(d.order_status)                                         AS order_status,
    MAX(d.shipping_mode)                                        AS shipping_mode,
    MAX(d.days_for_shipment_scheduled)                          AS days_for_shipment_scheduled,
    MAX(d.days_for_shipping_real)                               AS days_for_shipping_real,
    MAX(d.delivery_status)                                      AS delivery_status,
    MAX(d.late_delivery_risk)                                   AS late_delivery_risk,
    MAX(d.benefit_per_order)                                    AS benefit_per_order,
    COUNT(*)                                                    AS item_line_cnt,
    size(collect_set(d.product_name))                           AS product_cnt,
    size(collect_set(d.category_name))                          AS category_cnt,
    size(collect_set(d.department_name))                        AS department_cnt,
    CAST(SUM(d.order_item_quantity) AS INT)                     AS total_quantity,
    ROUND(SUM(d.sales), 4)                                      AS total_sales,
    ROUND(SUM(d.order_item_discount), 4)                        AS total_discount,
    ROUND(SUM(d.order_item_total), 4)                           AS total_net_amount,
    ROUND(AVG(d.order_item_product_price), 4)                   AS avg_item_price,
    MAX(m.main_category_name)                                   AS main_category_name,
    MAX(m.main_department_name)                                 AS main_department_name,
    MAX(d.customer_id)                                          AS customer_id,
    MAX(d.customer_segment)                                     AS customer_segment,
    MAX(d.customer_city)                                        AS customer_city,
    MAX(d.customer_state)                                       AS customer_state,
    MAX(d.customer_country)                                     AS customer_country,
    MAX(d.market)                                               AS market,
    MAX(d.order_region)                                         AS order_region,
    MAX(d.order_country)                                        AS order_country,
    MAX(d.order_state)                                          AS order_state,
    MAX(d.order_city)                                           AS order_city,
    MAX(d.latitude)                                             AS latitude,
    MAX(d.longitude)                                            AS longitude,
    date_format(MAX(d.order_datetime), 'yyyy-MM')               AS dt
FROM bishe_dwd.dwd_order_detail d
LEFT JOIN (
    SELECT order_id,
           MAX(category_name)   AS main_category_name,
           MAX(department_name) AS main_department_name
    FROM (
        SELECT order_id,
               category_name,
               department_name,
               ROW_NUMBER() OVER (PARTITION BY order_id
                                  ORDER BY sales DESC, category_name ASC, order_item_id ASC) AS rn
        FROM bishe_dwd.dwd_order_detail
    ) r
    WHERE r.rn = 1
    GROUP BY order_id
) m ON d.order_id = m.order_id
GROUP BY d.order_id;

-- ------------------------------------------------------------
-- 3. 清洗后访问日志
--    源文件自带的 Month 与 Hour 两列，经核对与解析时间完全一致，
--    属冗余列，此处只保留由访问时间派生的字段。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dwd_access_log;

CREATE TABLE IF NOT EXISTS dwd_access_log (
    product_key    STRING    COMMENT '商品键(小写去首尾空格)',
    product        STRING    COMMENT '商品名(原始)',
    category       STRING    COMMENT '商品类目',
    department     STRING    COMMENT '商品部门(已去首尾空格)',
    ip             STRING    COMMENT '访问IP',
    url            STRING    COMMENT '访问链接',
    access_time    TIMESTAMP COMMENT '访问时间(精确到分钟)',
    access_date    STRING    COMMENT '访问日期 yyyy-MM-dd',
    access_year    INT       COMMENT '访问年份',
    access_month   INT       COMMENT '访问月份',
    access_day     INT       COMMENT '访问日',
    access_hour    INT       COMMENT '访问小时',
    access_weekday INT       COMMENT '访问星期(0=周一,6=周日)',
    is_weekend     INT       COMMENT '是否周末(1=是)'
)
COMMENT '清洗后访问日志'
PARTITIONED BY (dt STRING COMMENT '分区月份 yyyy-MM')
STORED AS PARQUET;

INSERT OVERWRITE TABLE dwd_access_log PARTITION (dt)
SELECT
    lower(trim(product))                                                      AS product_key,
    product,
    category,
    trim(department)                                                          AS department,
    ip,
    url,
    from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm'))            AS access_time,
    date_format(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')), 'yyyy-MM-dd') AS access_date,
    YEAR(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))      AS access_year,
    MONTH(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))     AS access_month,
    DAY(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))       AS access_day,
    HOUR(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))      AS access_hour,
    PMOD(DATEDIFF(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')),
                  '1970-01-05'), 7)                                            AS access_weekday,
    CASE WHEN PMOD(DATEDIFF(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')),
                            '1970-01-05'), 7) >= 5 THEN 1 ELSE 0 END           AS is_weekend,
    date_format(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')), 'yyyy-MM') AS dt
FROM bishe_ods.ods_access_log_raw
WHERE access_time_raw IS NOT NULL
  AND trim(access_time_raw) <> '';

-- ============================================================
-- 加载校验
-- ============================================================

-- 校验一：订单明细行数与订单数，预期 180519 行、65752 单、每单 2.75 行
SELECT
    COUNT(*)                                       AS line_cnt,
    COUNT(DISTINCT order_id)                       AS order_cnt,
    ROUND(COUNT(*) / COUNT(DISTINCT order_id), 4)  AS lines_per_order
FROM dwd_order_detail;

-- 校验二：订单级主表行数，预期与订单数一致（65752）
SELECT COUNT(*) AS order_cnt FROM dwd_order_main;

-- 校验三：主类目口径检验，多类目订单占比应约 67.8%
SELECT
    SUM(CASE WHEN category_cnt > 1 THEN 1 ELSE 0 END)                             AS multi_category_orders,
    ROUND(SUM(CASE WHEN category_cnt > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2)   AS multi_category_pct
FROM dwd_order_main;

-- 校验四：W2 物流方式延迟率，预期 First Class 95.3%、Second Class 76.7%、
--         Same Day 46.2%、Standard Class 38.1%，全站 54.8%
SELECT
    shipping_mode,
    COUNT(*)                                AS order_cnt,
    ROUND(AVG(late_delivery_risk) * 100, 2) AS delay_rate_pct
FROM dwd_order_main
GROUP BY shipping_mode
ORDER BY delay_rate_pct DESC;

-- 校验五：跨域重叠商品数。
--   全时段（订单表 2015-01 起、访问表 2017-09 起）重叠 72 个；
--   限定共同窗口 2017-09 至 2018-01 后重叠 36 个，W4 用的是后者。
--   两表商品名口径不同：订单侧为原样 product_name，访问侧为小写去空格的 product_key，
--   故匹配时对订单侧统一做 lower(trim()) 归一。
SELECT COUNT(*) AS overlap_all_time
FROM (
    SELECT DISTINCT lower(trim(product_name)) AS product_key FROM dwd_order_detail
) o
JOIN (
    SELECT DISTINCT product_key FROM dwd_access_log
) a
ON o.product_key = a.product_key;

SELECT COUNT(*) AS overlap_in_window
FROM (
    SELECT DISTINCT lower(trim(product_name)) AS product_key FROM dwd_order_detail
    WHERE dt BETWEEN '2017-09' AND '2018-01'
) o
JOIN (
    SELECT DISTINCT product_key FROM dwd_access_log
    WHERE dt BETWEEN '2017-09' AND '2018-01'
) a
ON o.product_key = a.product_key;
