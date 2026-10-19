# 跨境电商订单预警系统

基于公开供应链数据集构建的离线数仓与在线预警看板。离线层用 Hive 做四层数仓加工并训练延迟风险模型，在线层用 Django 提供预警查询、工单处置与实时预测服务。

## 技术栈

离线层：Ubuntu 22.04 + Docker 容器化部署，Hadoop HDFS 存储、Apache Hive 2.3 做数仓主力计算、Apache Spark 做双引擎结果校验，Python 3.13 配合 pandas、scikit-learn、XGBoost 训练模型。

在线层：Django 5.2 + Django REST Framework 提供接口，MySQL 8.0 存 ADS 导出的预警结果与工单，前端为原生 HTML/CSS/JavaScript 单页应用，图表用 ECharts 5.6。

## 目录结构

```
hive/          ODS 到 ADS 四层数仓 SQL，01 至 05 按层执行
spark/         与 Hive 对跑的校验脚本
train_w1.py    W1 延迟风险模型训练脚本
online/        Django 在线服务，含前后端与容器配置
docker/        Hadoop 与 Hive 的容器编排配置
ads_export/    Hive 导出的 ADS 结果（未入库，见下）
```

## 数据来源

数据集不随仓库分发，两个数据集均来自 Mendeley Data 公开数据集 DataCo Smart Supply Chain，DOI 为 10.17632/8gx2fvg2k6.5。下载后放到 `data/` 目录，路径如下：

- `data/dataco/DataCoSupplyChainDataset.csv` 订单主表，180,519 行，覆盖 65,752 单
- `data/tokenized_access_logs.csv` 访问日志，469,977 行

说明：订单主表为真实企业数据；访问日志虽出自同一数据集包，但其 url 全部为规整模板路径、逐小时访问量分布过于平整、IP 池仅 3,340 个却产生 47 万条记录，统计特征显示它更接近作者构造的模拟日志。其中 2017-09-14 单日 45,648 次访问属数据自带现象，本项目将其作为异常检测的验证案例使用。

## 未入库的内容

以下内容因体积或性质原因未纳入版本管理，需要时按上述来源自行获取或重新生成：

- `data/`（原始数据集，182 MB）
- `w1_model.pkl`（训练好的模型，296 MB，超过 GitHub 单文件限制，可运行 `train_w1.py` 重新训练）
- `ads_export/`（Hive 导出的 ADS 结果，由 `hive/05_export_ads.sql` 生成）
- `xnj/`（Ubuntu 虚拟机镜像目录）

## 部署与运行

完整的环境搭建、数仓执行顺序、容器启动方式、已知故障与排查方法，见仓库内的 `AI交接说明.md`。
