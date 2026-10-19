-- ============================================================
-- ADS 导出：把应用层八张表导出为 TSV，供在线层 MySQL 装载
-- 表名与 04_ads.sql 的八张表一一对应，顺序不变
--
-- 执行（在虚拟机内）：
--   sudo docker cp /mnt/hgfs/bishe/hive/05_export_ads.sql hive-server:/tmp/
--   sudo docker exec hive-server bash -c "rm -rf /tmp/ads_export; LANG=C.UTF-8 hive -f /tmp/05_export_ads.sql"
--   sudo docker cp hive-server:/tmp/ads_export /mnt/hgfs/bishe/ads_export
--
-- 说明：
--   - 制表符分隔、文本存储，导出文件落在 hive-server 容器本地 /tmp/ads_export 下
--   - Hive 的空值在文本中写作反斜杠加 N，MySQL 的 LOAD DATA 默认就把该记号识别为空值，
--     两端约定一致，无需额外转换
--   - 中文列（物流方式、风险等级、处置建议等）依赖 LANG=C.UTF-8，缺该变量会乱码
--   - 全部 INSERT 使用 OVERWRITE，可安全重跑
-- ============================================================

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_delay_warning'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_delay_warning;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_dim_warning'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_dim_warning;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_conversion_warning'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_conversion_warning;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_traffic_warning'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_traffic_warning;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_order_risk_score'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_order_risk_score;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_warning_ticket'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_warning_ticket;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_handle_stats'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_handle_stats;

INSERT OVERWRITE LOCAL DIRECTORY '/tmp/ads_export/ads_risk_board'
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
SELECT * FROM bishe_ads.ads_risk_board;

-- 金额档位边界：在线层做实时预测时要复现订单宽表的低/中/高档位口径，
-- 档位由 NTILE(3) 按订单净额三分位切分，故此处取各档的取值范围，供在线层作为常量使用
SELECT
    amount_level,
    COUNT(*)                       AS order_cnt,
    ROUND(MIN(total_net_amount), 2) AS min_net_amount,
    ROUND(MAX(total_net_amount), 2) AS max_net_amount
FROM bishe_dws.dws_order_wide
GROUP BY amount_level
ORDER BY min_net_amount;
