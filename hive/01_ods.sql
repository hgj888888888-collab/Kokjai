-- ============================================================
-- ODS 层：原始数据外部表（指向 HDFS 上的 CSV 文件）
-- 数据源 1：DataCo Supply Chain Dataset  订单域（180,519 行 × 53 列）
-- 数据源 2：tokenized_access_logs        流量域（469,977 行 × 8 列）
--
-- 前置操作（在 Ubuntu 虚拟机内执行，项目目录按实际挂载位置替换）：
--   1) 编码转换。订单表源文件为 Latin-1 编码，含带重音的地名，
--      进 HDFS 前一次性转存为 UTF-8，否则中文与重音字符会乱码：
--        iconv -f LATIN1 -t UTF-8 DataCoSupplyChainDataset.csv > dataco_orders_utf8.csv
--      流量表源文件本身为 UTF-8，无需转换。
--   2) 上传 HDFS（先建目录再放文件，避免自动建表时落到默认路径）：
--        hdfs dfs -mkdir -p /user/hive/warehouse/ods/order_raw
--        hdfs dfs -mkdir -p /user/hive/warehouse/ods/access_log_raw
--        hdfs dfs -put -f dataco_orders_utf8.csv       /user/hive/warehouse/ods/order_raw/
--        hdfs dfs -put -f tokenized_access_logs.csv    /user/hive/warehouse/ods/access_log_raw/
--   3) 执行本脚本。Hive 命令必须加 LANG=C.UTF-8，否则中文注释乱码：
--        LANG=C.UTF-8 hive -f 01_ods.sql
--      若走 Docker 容器：
--        docker cp 01_ods.sql hive-server:/tmp/
--        docker exec -it hive-server bash -c "LANG=C.UTF-8 hive -f /tmp/01_ods.sql"
--
-- 建表约定：
--   ODS 层不做类型转换、不做清洗、不做过滤，全部按 STRING 原样落地，
--   类型转换与清洗在 DWD 层完成。字段顺序与源文件列顺序严格一致，
--   原始列名写在 COMMENT 中，便于与论文数据字典逐条对照。
-- ============================================================

CREATE DATABASE IF NOT EXISTS bishe_ods COMMENT '跨境电商订单预警系统 原始数据层';

USE bishe_ods;

-- ------------------------------------------------------------
-- 1. 订单域原始表（DataCo Supply Chain Dataset）
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_raw;

CREATE EXTERNAL TABLE IF NOT EXISTS ods_order_raw (
    payment_type               STRING COMMENT 'Type 支付方式',
    days_for_shipping_real     STRING COMMENT 'Days for shipping (real) 实际发货天数',
    days_for_shipment_scheduled STRING COMMENT 'Days for shipment (scheduled) 计划发货天数',
    benefit_per_order          STRING COMMENT 'Benefit per order 每单利润',
    sales_per_customer         STRING COMMENT 'Sales per customer 客户累计销售额',
    delivery_status            STRING COMMENT 'Delivery Status 交付状态',
    late_delivery_risk         STRING COMMENT 'Late_delivery_risk 延迟交付标签',
    category_id                STRING COMMENT 'Category Id 商品类目编号',
    category_name              STRING COMMENT 'Category Name 商品类目名称',
    customer_city              STRING COMMENT 'Customer City 客户城市',
    customer_country           STRING COMMENT 'Customer Country 客户国家',
    customer_email             STRING COMMENT 'Customer Email 客户邮箱(脱敏)',
    customer_fname             STRING COMMENT 'Customer Fname 客户名',
    customer_id                STRING COMMENT 'Customer Id 客户号',
    customer_lname             STRING COMMENT 'Customer Lname 客户姓',
    customer_password          STRING COMMENT 'Customer Password 客户密码(脱敏)',
    customer_segment           STRING COMMENT 'Customer Segment 客户分群',
    customer_state             STRING COMMENT 'Customer State 客户州省',
    customer_street            STRING COMMENT 'Customer Street 客户街道',
    customer_zipcode           STRING COMMENT 'Customer Zipcode 客户邮编',
    department_id              STRING COMMENT 'Department Id 商品部门编号',
    department_name            STRING COMMENT 'Department Name 商品部门名称',
    latitude                   STRING COMMENT 'Latitude 目的国纬度',
    longitude                  STRING COMMENT 'Longitude 目的国经度',
    market                     STRING COMMENT 'Market 市场大区',
    order_city                 STRING COMMENT 'Order City 目的城市',
    order_country              STRING COMMENT 'Order Country 目的国',
    order_customer_id          STRING COMMENT 'Order Customer Id 订单客户号',
    order_date_raw             STRING COMMENT 'order date (DateOrders) 下单时间原始字符串',
    order_id                   STRING COMMENT 'Order Id 订单号',
    order_item_cardprod_id     STRING COMMENT 'Order Item Cardprod Id 明细商品卡编号',
    order_item_discount        STRING COMMENT 'Order Item Discount 折扣金额',
    order_item_discount_rate   STRING COMMENT 'Order Item Discount Rate 折扣率标注值(有误,仅留档)',
    order_item_id              STRING COMMENT 'Order Item Id 订单明细编号',
    order_item_product_price   STRING COMMENT 'Order Item Product Price 明细商品单价',
    order_item_profit_ratio    STRING COMMENT 'Order Item Profit Ratio 利润率',
    order_item_quantity        STRING COMMENT 'Order Item Quantity 明细数量',
    sales                      STRING COMMENT 'Sales 销售额(未扣折扣)',
    order_item_total           STRING COMMENT 'Order Item Total 明细净额(销售额减折扣)',
    order_profit_per_order     STRING COMMENT 'Order Profit Per Order 订单利润(与每单利润恒等)',
    order_region               STRING COMMENT 'Order Region 订单区域',
    order_state                STRING COMMENT 'Order State 目的州省',
    order_status               STRING COMMENT 'Order Status 订单状态(派生标签)',
    order_zipcode              STRING COMMENT 'Order Zipcode 订单邮编(缺失率86.2%)',
    product_card_id            STRING COMMENT 'Product Card Id 商品卡编号',
    product_category_id        STRING COMMENT 'Product Category Id 商品类目编号(商品侧)',
    product_description        STRING COMMENT 'Product Description 商品描述(空值率100%)',
    product_image              STRING COMMENT 'Product Image 商品图片链接',
    product_name               STRING COMMENT 'Product Name 商品名称',
    product_price              STRING COMMENT 'Product Price 商品标价',
    product_status             STRING COMMENT 'Product Status 商品状态(常量)',
    shipping_date_raw          STRING COMMENT 'shipping date (DateOrders) 发货时间原始字符串',
    shipping_mode              STRING COMMENT 'Shipping Mode 物流方式'
)
COMMENT 'DataCo Supply Chain 原始订单明细表，一行不等于一单，平均每单 2.75 行'
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    "separatorChar" = ",",
    "quoteChar"     = "\"",
    "escapeChar"    = "\\"
)
STORED AS TEXTFILE
LOCATION '/user/hive/warehouse/ods/order_raw'
TBLPROPERTIES ("skip.header.line.count" = "1");

-- ------------------------------------------------------------
-- 2. 流量域原始表（tokenized_access_logs）
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_access_log_raw;

CREATE EXTERNAL TABLE IF NOT EXISTS ods_access_log_raw (
    product        STRING COMMENT 'Product 商品名',
    category       STRING COMMENT 'Category 商品类目',
    access_time_raw STRING COMMENT 'Date 访问时间原始字符串',
    month_name     STRING COMMENT 'Month 访问月份(英文缩写)',
    hour_of_day    STRING COMMENT 'Hour 访问小时(0-23)',
    department     STRING COMMENT 'Department 商品部门',
    ip             STRING COMMENT 'ip 访问IP',
    url            STRING COMMENT 'url 访问链接'
)
COMMENT 'tokenized_access_logs 原始访问日志表'
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    "separatorChar" = ",",
    "quoteChar"     = "\"",
    "escapeChar"    = "\\"
)
STORED AS TEXTFILE
LOCATION '/user/hive/warehouse/ods/access_log_raw'
TBLPROPERTIES ("skip.header.line.count" = "1");

-- ============================================================
-- 加载校验
-- ============================================================

-- 校验一：订单域行数与关键字段是否正常解析
-- 预期：total_rows = 180519，订单号解析失败数为 0
SELECT
    COUNT(*)                                              AS total_rows,
    SUM(CASE WHEN order_id IS NULL OR order_id = '' THEN 1 ELSE 0 END)      AS bad_order_id,
    SUM(CASE WHEN unix_timestamp(order_date_raw, 'M/d/yyyy H:mm') IS NULL THEN 1 ELSE 0 END) AS bad_order_date,
    MIN(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))     AS min_order_date,
    MAX(from_unixtime(unix_timestamp(order_date_raw, 'M/d/yyyy H:mm')))     AS max_order_date
FROM ods_order_raw;

-- 校验二：订单域物流方式行数分布（应为 4 类）
SELECT shipping_mode, COUNT(*) AS line_cnt
FROM ods_order_raw
GROUP BY shipping_mode
ORDER BY line_cnt DESC;

-- 校验三：流量域行数与访问时间范围
-- 预期：total_rows = 469977，时间范围 2017-09-01 06:00 至 2018-01-31 23:58
SELECT
    COUNT(*)                                              AS total_rows,
    SUM(CASE WHEN unix_timestamp(access_time_raw, 'M/d/yyyy H:mm') IS NULL THEN 1 ELSE 0 END) AS bad_access_date,
    COUNT(DISTINCT product)                               AS product_cnt,
    COUNT(DISTINCT ip)                                    AS ip_cnt,
    MIN(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))    AS min_access_time,
    MAX(from_unixtime(unix_timestamp(access_time_raw, 'M/d/yyyy H:mm')))    AS max_access_time
FROM ods_access_log_raw;
