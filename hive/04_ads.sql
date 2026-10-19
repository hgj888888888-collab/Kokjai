-- ============================================================
-- ADS 层：应用层指标表（供 Django 前端大屏直接查询）
-- 表名与任务书 6.3 节一致，共八张：
--   1. ads_delay_warning       延迟交付预警，含订单号、延迟概率与风险等级
--   2. ads_dim_warning         维度告警，物流方式与商品类目延迟率越限告警
--   3. ads_conversion_warning  转化异常告警，含商品、浏览量、转化率与偏离度
--   4. ads_traffic_warning     流量异常告警，含日期、访问量与标准差偏离度
--   5. ads_order_risk_score    综合风险评分，含延迟概率、维度风险加权、等级与处置建议
--   6. ads_warning_ticket      风险工单，含订单号、风险类型、风险等级、处置状态等
--   7. ads_handle_stats        处置结果统计，含预警命中率、误报率与平均处置时长
--   8. ads_risk_board          看板汇总指标，按国家、市场、类目、物流与时间汇总
--
-- 前置条件：
--   1) 01_ods.sql、02_dwd.sql、03_dws.sql 已在真实 Hive 上执行通过
--   2) Hive 命令必须加 LANG=C.UTF-8，否则中文注释乱码：
--        docker cp 04_ads.sql hive-server:/tmp/
--        docker exec hive-server bash -c "LANG=C.UTF-8 hive -f /tmp/04_ads.sql"
--
-- 说明：
--   - 全部 INSERT 使用 OVERWRITE，可安全重跑
--   - ads_delay_warning 的延迟概率口径已由冷启动基线切换为 W1 随机森林模型输出：
--     连续概率取自模型输出层 bishe_model.w1_order_prob（外部表，指向 HDFS 模型目录），
--     若个别订单在该模型表中无匹配，则退化取该订单所属物流方式的历史延迟率兜底，
--     口径切换以 prob_source 字段标识（W1模型:随机森林连续概率 / 基线:物流方式历史延迟率）。
--   - ads_dim_warning 对商品类目维度保留描述性监控：
--     类目与物流方式的构成显著相关（卡方 p = 2.1e-11），
--     控制物流方式后类目效应不显著（分层卡方合并 p = 0.940），
--     故类目行仅作监控展示，实际告警由越限规则与样本量门槛共同把关。
--   - 告警判定（W2 W3）需同时满足三个条件：样本量足够、统计显著、业务显著，
--     统计显著用两比例检验的偏离度衡量，业务显著用偏离全站不少于 10 个百分点衡量。
--   - 工单表为系统运行时生成，非订单类工单的 create_time 取生成时刻；
--     处置状态初始为待处理，人工处置后由在线层回写。
-- ============================================================

-- ------------------------------------------------------------
-- 0. 模型输出层（W1 随机森林连续延迟概率回写暂存）
--    本层不属于任务书 6.3 节规定的四层数仓（ODS/DWD/DWS/ADS），
--    是 W1 模型训练脚本导出全量订单连续概率后回写的暂存表，
--    仅供 ADS 层切换概率口径时读取，故只在 04_ads.sql 中建，
--    不改动 01_ods.sql、02_dwd.sql、03_dws.sql。
--    外部表指向 HDFS 模型输出目录，文本逗号分隔、跳过表头；
--    DROP 只删元数据、不删 HDFS 数据，可安全重跑，也不重复上传模型文件。
-- ------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS bishe_model COMMENT '跨境电商订单预警系统 模型输出层(W1回写暂存)';

DROP TABLE IF EXISTS bishe_model.w1_order_prob;

CREATE EXTERNAL TABLE IF NOT EXISTS bishe_model.w1_order_prob (
    order_id  STRING  COMMENT '订单号',
    late_prob DOUBLE  COMMENT 'W1随机森林输出延迟概率(0至1的连续值)',
    y_true    INT     COMMENT '真实延迟标签(0/1,仅自查用)',
    split     STRING  COMMENT '数据划分(train/test,仅自查用)'
)
COMMENT 'W1随机森林全量订单延迟概率外部暂存表,指向 HDFS 路径 /bishe/model/w1_order_prob'
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/bishe/model/w1_order_prob'
TBLPROPERTIES ('skip.header.line.count'='1');

CREATE DATABASE IF NOT EXISTS bishe_ads COMMENT '跨境电商订单预警系统 应用指标层';

USE bishe_ads;

-- ------------------------------------------------------------
-- 1. 延迟交付预警（W1）
--    概率口径：W1 随机森林模型输出的连续延迟概率，
--             论文主指标用时序切分（2015-2016 训练、2017-2018 测试），
--             测试集 AUC 0.7646、F1 0.6974。
--             但把概率回写给全量订单时不能直接用这一个模型，它见过训练期订单的答案，
--             打出的概率是过拟合值（近 0 或 1），会让下游命中率虚高。
--             故改用滚动向前打分，每半年一个区间，只用该区间之前的数据重训模型，
--             实测 60599 单由模型给出概率，最早 3 个月 5153 单无历史模型可用，记为冷启动。
--    兜底规则：订单在模型表中无匹配（即冷启动区间）时，退化为该订单所属物流方式的历史延迟率。
--             实测四档基线：First Class 95.27%、Second Class 76.72%、
--             Same Day 46.15%、Standard Class 38.13%，全站 54.8%。
--    风险等级：按概率固定阈值划分，概率不小于 0.8 为高、不小于 0.5 为中、其余为低；
--             告警（alert_flag = 1）为高或中风险。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_delay_warning;

CREATE TABLE IF NOT EXISTS ads_delay_warning (
    order_id           STRING    COMMENT '订单号',
    order_datetime     TIMESTAMP COMMENT '下单时间',
    order_month        STRING    COMMENT '下单月份 yyyy-MM',
    shipping_mode      STRING    COMMENT '物流方式',
    main_category_name STRING    COMMENT '主类目',
    order_country      STRING    COMMENT '目的国',
    market             STRING    COMMENT '市场大区',
    amount_level       STRING    COMMENT '订单金额档位',
    total_net_amount   DOUBLE    COMMENT '订单净额',
    delay_prob         DOUBLE    COMMENT '延迟概率',
    prob_source        STRING    COMMENT '概率来源(W1模型:随机森林连续概率/基线:物流方式历史延迟率)',
    risk_level         STRING    COMMENT '风险等级(高/中/低)',
    alert_flag         INT       COMMENT '是否触发预警(1=高或中风险)'
)
COMMENT '延迟交付预警表，含订单号、延迟概率与风险等级'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_delay_warning
SELECT
    w.order_id,
    w.order_datetime,
    date_format(w.order_datetime, 'yyyy-MM')        AS order_month,
    w.shipping_mode,
    w.main_category_name,
    w.order_country,
    w.market,
    w.amount_level,
    w.total_net_amount,
    ROUND(NVL(m.late_prob, s.delay_rate / 100), 6)  AS delay_prob,
    CASE WHEN m.late_prob IS NOT NULL THEN 'W1模型:随机森林连续概率'
         ELSE '基线:物流方式历史延迟率' END         AS prob_source,
    CASE WHEN NVL(m.late_prob, s.delay_rate / 100) >= 0.8 THEN '高'
         WHEN NVL(m.late_prob, s.delay_rate / 100) >= 0.5 THEN '中'
         ELSE '低' END                              AS risk_level,
    CASE WHEN NVL(m.late_prob, s.delay_rate / 100) >= 0.5 THEN 1 ELSE 0 END  AS alert_flag
FROM bishe_dws.dws_order_wide w
JOIN bishe_dws.dws_shipping_risk s
  ON w.shipping_mode = s.shipping_mode
LEFT JOIN bishe_model.w1_order_prob m
  ON w.order_id = m.order_id;

-- ------------------------------------------------------------
-- 2. 维度告警（W2 物流方式、W3 商品类目）
--    两个维度统一用同一套越限规则，放在一张表内，以 dim_type 区分。
--    基线为全站延迟率，偏离度用两比例检验的标准误衡量，
--    告警需同时满足：订单数不少于 1000、偏离度绝对值不小于 3 倍标准误、
--    且偏离全站不少于 10 个百分点。
--    实测结果：物流方式 First Class、Second Class、Standard Class 三类告警；
--    商品类目 50 个均不告警（9 个订单数不少于 1000 的类目偏离均在 1.2 个百分点以内）。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_dim_warning;

CREATE TABLE IF NOT EXISTS ads_dim_warning (
    dim_type        STRING  COMMENT '维度类型(物流方式/商品类目)',
    dim_value       STRING  COMMENT '维度取值',
    order_cnt       BIGINT  COMMENT '订单数',
    late_cnt        BIGINT  COMMENT '延迟订单数',
    delay_rate      DOUBLE  COMMENT '延迟率百分比',
    baseline_rate   DOUBLE  COMMENT '全站延迟率百分比',
    deviation_pp    DOUBLE  COMMENT '偏离全站百分点',
    std_error_pp    DOUBLE  COMMENT '两比例检验标准误百分点',
    z_score         DOUBLE  COMMENT '偏离度(偏离量除以标准误)',
    sample_enough   INT     COMMENT '样本量是否达标(1=订单数不少于1000)',
    alert_flag      INT     COMMENT '是否告警'
)
COMMENT '维度告警表，物流方式与商品类目延迟率越限告警'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_dim_warning
SELECT
    t.dim_type,
    t.dim_value,
    t.order_cnt,
    t.late_cnt,
    ROUND(t.delay_rate, 2)                                       AS delay_rate,
    ROUND(t.tot_late / t.tot_cnt * 100, 2)                       AS baseline_rate,
    ROUND(t.delay_rate - t.tot_late / t.tot_cnt * 100, 2)        AS deviation_pp,
    ROUND(100 * SQRT((t.tot_late / t.tot_cnt) *
                     (1 - t.tot_late / t.tot_cnt) / t.order_cnt), 4) AS std_error_pp,
    ROUND((t.delay_rate - t.tot_late / t.tot_cnt * 100) /
          (100 * SQRT((t.tot_late / t.tot_cnt) *
                      (1 - t.tot_late / t.tot_cnt) / t.order_cnt)), 4) AS z_score,
    CASE WHEN t.order_cnt >= 1000 THEN 1 ELSE 0 END              AS sample_enough,
    CASE WHEN t.order_cnt >= 1000
              AND ABS(t.delay_rate - t.tot_late / t.tot_cnt * 100) >=
                  3 * (100 * SQRT((t.tot_late / t.tot_cnt) *
                                  (1 - t.tot_late / t.tot_cnt) / t.order_cnt))
              AND ABS(t.delay_rate - t.tot_late / t.tot_cnt * 100) >= 10
         THEN 1 ELSE 0 END                                       AS alert_flag
FROM (
    SELECT
        dim_type,
        dim_value,
        order_cnt,
        late_cnt,
        late_cnt / order_cnt * 100                       AS delay_rate,
        SUM(order_cnt) OVER ()                           AS tot_cnt,
        SUM(late_cnt)  OVER ()                           AS tot_late
    FROM (
        SELECT '物流方式' AS dim_type,
               shipping_mode AS dim_value,
               COUNT(*) AS order_cnt,
               SUM(late_delivery_risk) AS late_cnt
        FROM bishe_dwd.dwd_order_main
        GROUP BY shipping_mode
        UNION ALL
        SELECT '商品类目' AS dim_type,
               main_category_name AS dim_value,
               COUNT(*) AS order_cnt,
               SUM(late_delivery_risk) AS late_cnt
        FROM bishe_dwd.dwd_order_main
        GROUP BY main_category_name
    ) g
) t;

-- ------------------------------------------------------------
-- 3. 转化异常告警（W4）
--    口径：两源共同窗口 2017-09 至 2018-01 内，浏览量大于 1000 且订单侧有成交的商品，
--    按转化率升序取最低四分位判为高浏览低转化异常。
--    实测：可关联商品（订单侧有成交）共 36 个，其中浏览量大于 1000 的 32 个，
--    在这 32 个商品内按转化率升序取最低四分位，异常组 8 个，
--    异常组合计浏览 58440 次、成交 26 单、组内转化率 0.0445%。
--    基线口径为全部 36 个可关联商品的全站平均转化率 1.646%，
--    异常组与之相差约 37 倍，与任务书 5.2 节 W4 一致。
--    注意基线必须在 36 个商品上算，若先在浏览量大于 1000 的子集上算基线，
--    数值会偏移，无法复现任务书中的 1.646%。
--    转化率区间为 0.027439% 至 3.366715%，二者之比即极差 122.7 倍。
--    偏离度取全站均值除以该商品转化率，异常组内最大为 60.0 倍。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_conversion_warning;

CREATE TABLE IF NOT EXISTS ads_conversion_warning (
    product            STRING  COMMENT '商品名',
    category           STRING  COMMENT '商品类目',
    department         STRING  COMMENT '商品部门',
    views              BIGINT  COMMENT '浏览量',
    orders             BIGINT  COMMENT '下单量(含该商品的唯一订单数)',
    conv_rate          DOUBLE  COMMENT '转化率百分比',
    baseline_conv_rate DOUBLE  COMMENT '全站平均转化率百分比',
    deviation_ratio    DOUBLE  COMMENT '全站均值相对该商品的倍数',
    alert_flag         INT     COMMENT '是否告警(1=最低四分位)',
    alert_level        STRING  COMMENT '告警类型'
)
COMMENT '转化异常告警表，含商品、浏览量、转化率与偏离度'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_conversion_warning
SELECT
    t.product,
    t.category,
    t.department,
    t.views,
    t.orders,
    ROUND(t.conv_frac * 100, 6)                                        AS conv_rate,
    ROUND(t.tot_orders / t.tot_views * 100, 6)                         AS baseline_conv_rate,
    ROUND((t.tot_orders / t.tot_views) / t.conv_frac, 1)               AS deviation_ratio,
    CASE WHEN t.quartile = 1 THEN 1 ELSE 0 END                         AS alert_flag,
    CASE WHEN t.quartile = 1 THEN '高浏览低转化' ELSE '正常' END        AS alert_level
FROM (
    SELECT
        p.product,
        p.category,
        p.department,
        p.views,
        p.orders,
        p.conv_frac,
        p.tot_orders,
        p.tot_views,
        NTILE(4) OVER (ORDER BY p.conv_frac ASC, p.product_key ASC) AS quartile
    FROM (
        SELECT
            product,
            category,
            department,
            product_key,
            views,
            orders,
            orders / views              AS conv_frac,
            SUM(orders) OVER ()         AS tot_orders,
            SUM(views)  OVER ()         AS tot_views
        FROM bishe_dws.dws_product_conversion
        WHERE orders > 0
    ) p
    WHERE p.views > 1000
) t;

-- ------------------------------------------------------------
-- 4. 流量异常告警（W5）
--    口径：按日期汇总全站访问量，采用三倍标准差法，
--    基线的均值与标准差在剔除第一轮异常日后重新计算，
--    即先以全部日期的统计量筛掉偏离度绝对值大于 3 的日期，再用剩余日期定基线。
--    实测：日均访问量 2791.64 次，标准差 271.99，
--    三倍标准差告警共命中 6 天，全部为突增。
--    其中极端日为 2017-09-14 访问 45648 次、偏离度 157.57，为日均的 16.4 倍；
--    另外五日为 2017-09-18、09-19、09-26、09-27、09-30，
--    访问量 3612 至 3693 次，偏离度 3.02 至 3.31，属轻度突增。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_traffic_warning;

CREATE TABLE IF NOT EXISTS ads_traffic_warning (
    access_date  STRING  COMMENT '访问日期',
    visits       BIGINT  COMMENT '当日访问量',
    avg_visits   DOUBLE  COMMENT '日均访问量(剔除异常日后)',
    std_visits   DOUBLE  COMMENT '访问量标准差(剔除异常日后)',
    z_score      DOUBLE  COMMENT '偏离度',
    alert_flag   INT     COMMENT '是否告警(1=偏离度绝对值大于3)',
    alert_level  STRING  COMMENT '告警类型'
)
COMMENT '流量异常告警表，含日期、访问量与标准差偏离度'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_traffic_warning
SELECT
    t.access_date,
    t.visits,
    ROUND(t.avg_visits, 2)                               AS avg_visits,
    ROUND(t.std_visits, 2)                               AS std_visits,
    ROUND((t.visits - t.avg_visits) / t.std_visits, 4)   AS z_score,
    CASE WHEN ABS((t.visits - t.avg_visits) / t.std_visits) > 3 THEN 1 ELSE 0 END AS alert_flag,
    CASE WHEN (t.visits - t.avg_visits) / t.std_visits > 3 THEN '流量突增'
         WHEN (t.visits - t.avg_visits) / t.std_visits < -3 THEN '流量骤降'
         ELSE '正常' END                                 AS alert_level
FROM (
    SELECT
        access_date,
        visits,
        AVG(CASE WHEN ABS(z_first) <= 3 THEN visits END)  OVER () AS avg_visits,
        STDDEV_SAMP(CASE WHEN ABS(z_first) <= 3 THEN visits END) OVER () AS std_visits
    FROM (
        SELECT
            access_date,
            visits,
            (visits - first_avg) / first_std AS z_first
        FROM (
            SELECT
                access_date,
                visits,
                AVG(visits) OVER ()          AS first_avg,
                STDDEV_SAMP(visits) OVER ()  AS first_std
            FROM (
                SELECT access_date, SUM(views) AS visits
                FROM bishe_dws.dws_product_traffic
                GROUP BY access_date
            ) d
        ) a
    ) b
) t;

-- ------------------------------------------------------------
-- 5. 综合风险评分（W6）
--    风险分 = 0.6 乘延迟概率 加 0.4 乘物流方式风险。
--    延迟概率取 W1 随机森林模型输出的连续概率（bishe_model.w1_order_prob），
--    无匹配时退化为所属物流方式的历史延迟率兜底；
--    物流方式风险为该物流方式的延迟率除以最大值，归一到 0 至 1；
--    物流方式是唯一经检验有效的真实信号源，故权重最大。
--    类目效应经分层卡方检验控制物流方式后不显著（合并 p = 0.940），
--    自 2026-10-15 起不再纳入评分，类目维度只在看板中作描述性监控。
--    等级按风险分位切分为高、中、低三级，同分时以订单净额降序兜底。
--    处置建议按风险等级与金额档位给出，对应 5.7 节的风险分级表。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_order_risk_score;

CREATE TABLE IF NOT EXISTS ads_order_risk_score (
    order_id           STRING    COMMENT '订单号',
    order_datetime     TIMESTAMP COMMENT '下单时间',
    order_month        STRING    COMMENT '下单月份 yyyy-MM',
    shipping_mode      STRING    COMMENT '物流方式',
    main_category_name STRING    COMMENT '主类目',
    order_country      STRING    COMMENT '目的国',
    market             STRING    COMMENT '市场大区',
    amount_level       STRING    COMMENT '订单金额档位',
    total_net_amount   DOUBLE    COMMENT '订单净额',
    delay_prob         DOUBLE    COMMENT '延迟概率',
    shipping_risk      DOUBLE    COMMENT '物流方式风险(归一到0至1)',
    risk_score         DOUBLE    COMMENT '综合风险分',
    risk_level         STRING    COMMENT '风险等级(高/中/低)',
    suggestion         STRING    COMMENT '处置建议'
)
COMMENT '综合风险评分表，含延迟概率、维度风险加权、等级与处置建议'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_order_risk_score
SELECT
    b.order_id,
    b.order_datetime,
    b.order_month,
    b.shipping_mode,
    b.main_category_name,
    b.order_country,
    b.market,
    b.amount_level,
    b.total_net_amount,
    b.delay_prob,
    b.shipping_risk,
    b.risk_score,
    CASE b.risk_rank WHEN 1 THEN '高' WHEN 2 THEN '中' ELSE '低' END AS risk_level,
    CASE WHEN b.risk_rank = 1 AND b.amount_level = '高' THEN '升级物流方式并提前通知客户新时效，人工介入确认'
         WHEN b.risk_rank = 1 THEN '升级物流方式、优先分拣，提前通知客户新时效'
         WHEN b.risk_rank = 2 AND b.amount_level = '高' THEN '标记监控并纳入观察清单，预留库存缓冲'
         WHEN b.risk_rank = 2 THEN '标记监控、预留库存缓冲、加入观察清单'
         ELSE '仅记录，不干预' END AS suggestion
FROM (
    SELECT
        a.*,
        NTILE(3) OVER (ORDER BY a.risk_score DESC, a.total_net_amount DESC, a.order_id ASC) AS risk_rank
    FROM (
        SELECT
            w.order_id,
            w.order_datetime,
            date_format(w.order_datetime, 'yyyy-MM') AS order_month,
            w.shipping_mode,
            w.main_category_name,
            w.order_country,
            w.market,
            w.amount_level,
            w.total_net_amount,
            ROUND(NVL(m.late_prob, s.delay_rate / 100), 6) AS delay_prob,
            ROUND(s.delay_rate / MAX(s.delay_rate) OVER (), 6) AS shipping_risk,
            ROUND(0.6 * NVL(m.late_prob, s.delay_rate / 100)
                  + 0.4 * (s.delay_rate / MAX(s.delay_rate) OVER ()), 6) AS risk_score
        FROM bishe_dws.dws_order_wide w
        JOIN bishe_dws.dws_shipping_risk s
          ON w.shipping_mode = s.shipping_mode
        LEFT JOIN bishe_model.w1_order_prob m
          ON w.order_id = m.order_id
    ) a
) b;

-- ------------------------------------------------------------
-- 6. 风险工单（处置闭环）
--    订单级工单取高风险订单，维度级、转化级与流量级工单取各类告警行。
--    初始状态为待处理、处理人为未分配、误报标记为 0，
--    人工处置后由在线层更新处置状态、处理人、处置动作、处置时间与备注。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_warning_ticket;

CREATE TABLE IF NOT EXISTS ads_warning_ticket (
    ticket_id      STRING  COMMENT '工单号',
    target_id      STRING  COMMENT '预警对象(订单号/维度取值/商品名/日期)',
    warn_type      STRING  COMMENT '预警类型',
    risk_level     STRING  COMMENT '风险等级',
    handle_status  STRING  COMMENT '处置状态(待处理/处理中/已处置/已关闭)',
    handler        STRING  COMMENT '处理人',
    handle_action  STRING  COMMENT '处置动作',
    create_time    STRING  COMMENT '工单创建时间',
    handle_time    STRING  COMMENT '处置时间',
    remark         STRING  COMMENT '备注',
    is_false_alarm INT     COMMENT '误报标记(1=误报)'
)
COMMENT '风险工单表，含订单号、风险类型、风险等级、处置状态、处理人、处置动作、时间与备注'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_warning_ticket
SELECT
    CONCAT('T', CAST(ROW_NUMBER() OVER (ORDER BY t.create_time, t.warn_type, t.target_id) AS STRING)) AS ticket_id,
    t.target_id,
    t.warn_type,
    t.risk_level,
    '待处理'        AS handle_status,
    '未分配'        AS handler,
    t.handle_action,
    t.create_time,
    CAST(NULL AS STRING) AS handle_time,
    t.remark,
    0               AS is_false_alarm
FROM (
    SELECT
        s.order_id AS target_id,
        '延迟交付风险' AS warn_type,
        '高风险' AS risk_level,
        '升级物流方式、优先分拣、提前通知客户新时效' AS handle_action,
        date_format(s.order_datetime, 'yyyy-MM-dd HH:mm:ss') AS create_time,
        CONCAT('物流方式为', s.shipping_mode, '，延迟概率 ', CAST(s.delay_prob AS STRING)) AS remark
    FROM bishe_ads.ads_order_risk_score s
    WHERE s.risk_level = '高'
    UNION ALL
    SELECT
        d.dim_value AS target_id,
        CONCAT(d.dim_type, '履约风险') AS warn_type,
        '高风险' AS risk_level,
        '升级物流方式、优先分拣、提前通知客户新时效' AS handle_action,
        date_format(current_timestamp(), 'yyyy-MM-dd HH:mm:ss') AS create_time,
        CONCAT(d.dim_value, ' 延迟率 ', CAST(d.delay_rate AS STRING), '%，偏离全站 ',
               CAST(d.deviation_pp AS STRING), ' 个百分点') AS remark
    FROM bishe_ads.ads_dim_warning d
    WHERE d.alert_flag = 1
    UNION ALL
    SELECT
        c.product AS target_id,
        '订单转化异常' AS warn_type,
        '中风险' AS risk_level,
        '核查商品页、定价与库存，发起商品优化工单' AS handle_action,
        date_format(current_timestamp(), 'yyyy-MM-dd HH:mm:ss') AS create_time,
        CONCAT(c.product, ' 转化率 ', CAST(c.conv_rate AS STRING), '%，低于全站 ',
               CAST(c.deviation_ratio AS STRING), ' 倍') AS remark
    FROM bishe_ads.ads_conversion_warning c
    WHERE c.alert_flag = 1
    UNION ALL
    SELECT
        w.access_date AS target_id,
        '订单流量异常' AS warn_type,
        '中风险' AS risk_level,
        '核查是否为促销爆发或异常流量，必要时限流' AS handle_action,
        CONCAT(w.access_date, ' 00:00:00') AS create_time,
        CONCAT(w.access_date, ' 访问量 ', CAST(w.visits AS STRING),
               '，偏离度 ', CAST(w.z_score AS STRING)) AS remark
    FROM bishe_ads.ads_traffic_warning w
    WHERE w.alert_flag = 1
) t;

-- ------------------------------------------------------------
-- 7. 处置结果统计
--    预警命中率定义为被预警且订单确实延迟的比例，仅延迟交付类工单有真实结果标签可核对，
--    其余类型记为无标签（labeled_cnt 为 0）。
--    平均处置时长在人工处置回流前无数据，记为 NULL，
--    待在线层产生处置记录后由回填脚本更新。
--    注意：本表必须拆成两条语句写入。先 INSERT OVERWRITE 写各预警类型行，
--    再 INSERT INTO 追加「全部」汇总行。
--    若把两次聚合写成一条语句的顶层 INSERT 直接接 UNION ALL，
--    在 Hive 2.3 的本地 MapReduce 模式下会生成空读取阶段并报
--    return code 2 from MapRedTask；把 UNION ALL 包进派生表也无效，
--    只有拆语句才稳定通过。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_handle_stats;

CREATE TABLE IF NOT EXISTS ads_handle_stats (
    stat_scope       STRING  COMMENT '统计范围(预警类型/全部)',
    warn_type        STRING  COMMENT '预警类型(全部行为全部)',
    ticket_cnt       BIGINT  COMMENT '工单总数',
    labeled_cnt      BIGINT  COMMENT '有真实结果标签的工单数',
    hit_rate         DOUBLE  COMMENT '预警命中率百分比',
    false_alarm_rate DOUBLE  COMMENT '误报率百分比',
    handled_cnt      BIGINT  COMMENT '已处置工单数',
    avg_handle_hours DOUBLE  COMMENT '平均处置时长小时'
)
COMMENT '处置结果统计表，含预警命中率、误报率与平均处置时长'
STORED AS PARQUET;

-- 7.1 各预警类型：工单数与有真实标签的延迟类工单命中率
INSERT OVERWRITE TABLE ads_handle_stats
SELECT
    '预警类型' AS stat_scope,
    k.warn_type,
    k.ticket_cnt,
    NVL(h.labeled_cnt, 0) AS labeled_cnt,
    h.hit_rate,
    CASE WHEN h.hit_rate IS NULL THEN CAST(NULL AS DOUBLE)
         ELSE ROUND(100 - h.hit_rate, 2) END AS false_alarm_rate,
    0 AS handled_cnt,
    CAST(NULL AS DOUBLE) AS avg_handle_hours
FROM (
    SELECT warn_type, COUNT(*) AS ticket_cnt
    FROM bishe_ads.ads_warning_ticket
    GROUP BY warn_type
) k
LEFT JOIN (
    SELECT '延迟交付风险' AS warn_type,
           COUNT(*) AS labeled_cnt,
           ROUND(AVG(m.late_delivery_risk) * 100, 2) AS hit_rate
    FROM bishe_ads.ads_warning_ticket t
    JOIN bishe_dwd.dwd_order_main m ON t.target_id = m.order_id
    WHERE t.warn_type = '延迟交付风险'
) h ON k.warn_type = h.warn_type;

-- 7.2 追加全部汇总行。命中率的分母为有真实标签的工单数
INSERT INTO TABLE ads_handle_stats
SELECT
    '全部' AS stat_scope,
    '全部' AS warn_type,
    COUNT(*) AS ticket_cnt,
    SUM(CASE WHEN t.warn_type = '延迟交付风险' THEN 1 ELSE 0 END) AS labeled_cnt,
    ROUND(AVG(CASE WHEN t.warn_type = '延迟交付风险' THEN m.late_delivery_risk END) * 100, 2) AS hit_rate,
    ROUND(100 - AVG(CASE WHEN t.warn_type = '延迟交付风险' THEN m.late_delivery_risk END) * 100, 2) AS false_alarm_rate,
    0 AS handled_cnt,
    CAST(NULL AS DOUBLE) AS avg_handle_hours
FROM bishe_ads.ads_warning_ticket t
LEFT JOIN bishe_dwd.dwd_order_main m ON t.target_id = m.order_id;

-- ------------------------------------------------------------
-- 8. 看板汇总指标
--    统一长表结构，以 board_dim 区分汇总维度：总体、市场大区、目的国、
--    商品类目、物流方式、下单月份、下单时段。
--    订单量占比在各自维度内计算，用于饼图与柱状图。
--    注意：订单明细的 Latitude 与 Longitude 是客户所在地坐标而非目的国坐标，
--    实测各目的国的坐标均值都落在美国境内，故本表不放经纬度，
--    世界地图由在线层按目的国名称对齐底图后着色。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ads_risk_board;

CREATE TABLE IF NOT EXISTS ads_risk_board (
    board_dim        STRING  COMMENT '汇总维度',
    board_key        STRING  COMMENT '维度取值',
    order_cnt        BIGINT  COMMENT '订单数',
    order_share      DOUBLE  COMMENT '维度内订单量占比百分比',
    total_revenue    DOUBLE  COMMENT '营收合计(订单净额)',
    avg_order_amount DOUBLE  COMMENT '平均单笔金额',
    delay_rate       DOUBLE  COMMENT '延迟率百分比'
)
COMMENT '看板汇总指标表，按国家、市场、类目、物流与时间汇总'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads_risk_board
SELECT
    board_dim,
    board_key,
    order_cnt,
    ROUND(order_cnt / SUM(order_cnt) OVER (PARTITION BY board_dim) * 100, 4) AS order_share,
    total_revenue,
    avg_order_amount,
    delay_rate
FROM (
    SELECT '总体' AS board_dim, '全站' AS board_key,
           COUNT(*) AS order_cnt,
           ROUND(SUM(total_net_amount), 2) AS total_revenue,
           ROUND(AVG(total_net_amount), 2) AS avg_order_amount,
           ROUND(AVG(late_delivery_risk) * 100, 2) AS delay_rate
    FROM bishe_dws.dws_order_wide
    UNION ALL
    SELECT '市场大区', market,
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY market
    UNION ALL
    SELECT '目的国', order_country,
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY order_country
    UNION ALL
    SELECT '商品类目', main_category_name,
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY main_category_name
    UNION ALL
    SELECT '物流方式', shipping_mode,
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY shipping_mode
    UNION ALL
    SELECT '下单月份', date_format(order_datetime, 'yyyy-MM'),
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY date_format(order_datetime, 'yyyy-MM')
    UNION ALL
    SELECT '下单时段', time_period,
           COUNT(*), ROUND(SUM(total_net_amount), 2), ROUND(AVG(total_net_amount), 2),
           ROUND(AVG(late_delivery_risk) * 100, 2)
    FROM bishe_dws.dws_order_wide
    GROUP BY time_period
) t;

-- ============================================================
-- 加载校验
-- ============================================================

-- 校验一：延迟预警，预期 65752 行、连续概率 56969 个不同取值、告警 25596 单
--         概率由滚动向前模型回写 60599 单，冷启动区间 5153 单取物流方式历史延迟率兜底
--         高风险 12183（First Class 9337、Second Class 1708、Same Day 1138）、
--         中风险 13413（Second Class 11058、Standard Class 1162、First Class 742、Same Day 451）、
--         低风险 40156（Standard Class 38162、Same Day 1982、Second Class 12）
SELECT COUNT(*) AS row_cnt,
       COUNT(DISTINCT order_id) AS order_cnt,
       COUNT(DISTINCT delay_prob) AS prob_cnt,
       SUM(alert_flag) AS alert_cnt
FROM ads_delay_warning;

SELECT risk_level, shipping_mode, COUNT(*) AS order_cnt, MAX(delay_prob) AS delay_prob
FROM ads_delay_warning
GROUP BY risk_level, shipping_mode
ORDER BY delay_prob DESC;

-- 校验二：维度告警，预期 54 行（物流方式 4 加商品类目 50），告警 3 行且全在物流方式
SELECT dim_type, COUNT(*) AS row_cnt, SUM(alert_flag) AS alert_cnt, SUM(sample_enough) AS enough_cnt
FROM ads_dim_warning
GROUP BY dim_type;

SELECT dim_type, dim_value, order_cnt, delay_rate, baseline_rate, deviation_pp, std_error_pp, z_score, alert_flag
FROM ads_dim_warning
ORDER BY alert_flag DESC, order_cnt DESC
LIMIT 10;

-- 校验三：转化告警，预期 32 行（可关联 36 个中浏览量大于 1000 的）、告警 8 行
--         转化率极差 122.7 倍、全站基线 1.646%
SELECT COUNT(*) AS row_cnt, SUM(alert_flag) AS alert_cnt,
       ROUND(SUM(orders) / SUM(views) * 100, 4) AS window_conv_rate,
       ROUND(AVG(baseline_conv_rate), 4) AS baseline_conv_rate_in_table,
       ROUND(MAX(conv_rate) / MIN(conv_rate), 1) AS conv_ratio
FROM ads_conversion_warning;

SELECT COUNT(*) AS alert_cnt, SUM(views) AS sum_views, SUM(orders) AS sum_orders,
       ROUND(SUM(orders) / SUM(views) * 100, 4) AS group_conv_rate,
       ROUND(MAX(baseline_conv_rate) / (SUM(orders) / SUM(views) * 100), 1) AS group_deviation_ratio,
       ROUND(MAX(deviation_ratio), 1) AS per_product_max_ratio
FROM ads_conversion_warning
WHERE alert_flag = 1;

-- 校验四：流量告警，预期 153 天、告警 6 天、日均 2791.64 次
--         极端日为 2017-09-14 访问 45648 次，偏离度 157.57
--         其余五日为轻度突增，访问量 3612 至 3693 次，偏离度 3.02 至 3.31
SELECT COUNT(*) AS day_cnt, SUM(alert_flag) AS alert_cnt, ROUND(AVG(avg_visits), 2) AS avg_visits
FROM ads_traffic_warning;

SELECT access_date, visits, std_visits, z_score, alert_level
FROM ads_traffic_warning
WHERE alert_flag = 1
ORDER BY z_score DESC;

-- 校验五：综合评分，预期 65752 行，高分 21918、中分 21917、低分 21917
SELECT COUNT(*) AS row_cnt, COUNT(DISTINCT order_id) AS order_cnt
FROM ads_order_risk_score;

SELECT risk_level, COUNT(*) AS order_cnt, ROUND(MIN(risk_score), 4) AS min_score,
       ROUND(MAX(risk_score), 4) AS max_score
FROM ads_order_risk_score
GROUP BY risk_level
ORDER BY min_score DESC;

SELECT suggestion, COUNT(*) AS order_cnt
FROM ads_order_risk_score
GROUP BY suggestion
ORDER BY order_cnt DESC;

-- 校验六：工单，预期延迟交付风险 21918、订单转化异常 8、订单流量异常 6、
--         物流方式履约风险 3，全部为待处理
SELECT warn_type, risk_level, COUNT(*) AS ticket_cnt, MAX(handle_status) AS handle_status
FROM ads_warning_ticket
GROUP BY warn_type, risk_level
ORDER BY ticket_cnt DESC;

-- 校验七：处置统计，工单合计 21935 行，延迟交付类命中率 86.51%、误报率 13.49%
--         命中率按训练期与测试期拆分后分别为 86.44 与 86.64，说明滚动向前口径已消除过拟合
SELECT * FROM ads_handle_stats ORDER BY ticket_cnt DESC;

-- 校验八：看板汇总，预期七个维度、目的国 164 行、商品类目 50 行、下单月份 37 行
SELECT board_dim, COUNT(*) AS row_cnt, SUM(order_cnt) AS order_cnt,
       ROUND(SUM(order_share), 2) AS share_sum
FROM ads_risk_board
GROUP BY board_dim
ORDER BY board_dim;

SELECT board_dim, board_key, order_cnt, order_share, total_revenue, avg_order_amount, delay_rate
FROM ads_risk_board
WHERE board_dim IN ('总体', '物流方式', '下单时段')
ORDER BY board_dim, order_cnt DESC;
 