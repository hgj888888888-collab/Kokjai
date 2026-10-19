# AI 工作交接说明

本文件用于在不同 AI 会话或不同工作区之间交接本项目的状态。阅读者读完本文件后，应能直接接着干活，无需重新调研。

最后更新：2026-10-15

## 一、项目基本信息

- 课题名称：跨境电商订单预警系统的设计与实现
- 课题类型：工程设计（软件开发），本科毕业设计
- 任务书（权威文档，一切以它为准）：
  - `d:\bishe\任务书-跨境电商订单预警系统.md`
  - `d:\bishe\任务书-跨境电商订单预警系统.docx`
- 任务书结构：一 课题基本信息、二 背景与意义、三 国内外研究现状、四 研究目标、五 主要研究内容（5.1 预警方向、5.2 各预警项的计算字段与逻辑、5.3 数据来源与数据质量处理含数据字典、5.4 特征工程、5.5 建模与评估、5.6 系统设计与实现、5.7 预警处置闭环）、六 技术路线与系统架构、七 开发环境、八 可行性分析、九 进度安排、十 预期成果、十一 参考文献

## 二、数据集

本项目使用两个公开数据集，均已下载到本地，不接受 AI 生成的合成数据。

| 数据源 | 业务域 | 本地路径 | 规模 | 时间范围 | 出处 |
|---|---|---|---|---|---|
| DataCo Supply Chain Dataset | 订单域（履约） | `d:\bishe\data\dataco\DataCoSupplyChainDataset.csv` | 180,519 行 × 53 列，65,752 个订单，164 个目的国 | 2015-01 至 2018-01 | Mendeley Data，DOI: 10.17632/8gx2fvg2k6.5，CC BY 4.0 |
| tokenized_access_logs | 流量域（行为） | `d:\bishe\data\tokenized_access_logs.csv`（原位于 `c:\Users\23916\Desktop\32323\8gx2fvg2k6-5\`，已于 2026-10-14 复制过来） | 469,977 行 × 8 列，76 个商品，3,340 个 IP | 2017-09 至 2018-01 | 同一 Mendeley 数据集附带 |
| 字段说明文档 | 参考 | `d:\bishe\data\dataco\DescriptionDataCoSupplyChain.csv` | - | - | 同上 |

重要提示：`c:\Users\23916\Desktop\32323\8gx2fvg2k6-5\DataCoSupplyChainDataset.csv` 是一份损坏副本，8,290 行（4.59%）字段错位，已弃用，禁止使用。只能用 `d:\bishe\data\dataco\` 下那份。

2026-10-16 流量域数据性质的核验结论：订单域 DataCo 主表是真实企业数据，但同一 Mendeley 包附带的 `tokenized_access_logs.csv` 从统计特征看更像是作者构造的模拟日志，不是真实网站采集记录。判据有四条。其一，全部 469,977 行的 url 都是完全规整的模板路径 `/department/<部门>/category/<类目>/product/<商品名>`，且每一行都含 %20，真实日志必然混有首页、列表页、检索页、参数页与爬虫路径。其二，除 2017-09-14 外的 152 天，按小时汇总后 6 至 23 点每小时都稳定在约 22,700 条、0 至 5 点每小时都稳定在约 2,225 条，小时之间几乎没有波动，真实访问一定是随作息起伏的曲线。其三，恰恰只有 2017-09-14 这一天呈现正常的作息曲线（6 点 169 条爬到 21 点 7735 条），且其总量 45,648 条，紧接着的第二名只有 3,693 条，中间没有过渡。其四，IP 池过小且高度重复，全表仅 3,340 个 IP 却产生 469,977 条记录，平均每个 IP 出现 140 次，最高 566 次，真实日志绝大多数 IP 只出现一两次。论文中应如实说明该日志来自同一公开数据集的附带文件，其 2017-09-14 尖峰属数据自带现象，可作为一个异常检测案例来写，不要描述为真实大促。

两个数据源的共同时间窗口为 2017-09-01 至 2018-01-31。跨源分析必须限定在该窗口内。

跨源商品匹配口径（2026-10-15 在 Hive 上实测）：订单表商品名原样，访问表商品名为小写去空格，匹配时对订单侧统一做 `lower(trim())` 归一。全时段（订单表 2015-01 起、访问表 2017-09 起）重叠 72 个商品；限定共同窗口 2017-09 至 2018-01 后重叠 36 个。W4 用的是窗口内口径，即 36 个，与第三节 W4 的「可关联商品 36 个」一致。两数含义不同，不可混用。

## 三、已实测确认的结论（可直接引用，均已复跑验证）

预警体系共 6 项，其中 W1 至 W3、W6 为订单预警主体，W4、W5 为订单获取侧扩展。

### W1 延迟交付风险预警（机器学习，核心）

- 订单粒度建模，按时序划分：2015 至 2016 年训练，2017 至 2018 年测试，严禁随机切分。
- 复跑结果（2026-10-15，订单粒度聚合，严格时序切分 2015 至 2016 训练、2017 至 2018 测试）：Logistic Regression AUC 0.7456、F1 0.6577；Random Forest AUC 0.7646、F1 0.6974；XGBoost AUC 0.7622、F1 0.6971。论文基线取 Random Forest，模型已序列化为 `d:\bishe\w1_model.pkl`。历史旧值 0.7648、0.7539、0.7554、0.7571 等一律废弃。
- 特征集（26 个字段，2026-10-15 定稿）：去掉 `order_country`、`order_state`、`order_city` 三个高基数类别（独热后 2779 列），依据是 2016 验证集 AUC 0.7666 对 0.7640，去掉更好，且该选择只用训练期数据、未看测试集；`days_for_shipment_scheduled` 与 `shipping_mode` 一一映射，只保留后者；`order_id`、`customer_id`、`order_datetime`、`order_year`、`dt` 不作为特征。
- 关键业务规律：Same Day 订单在中午 12 点前下单的延迟率为 0，12 点后下单的延迟率约 95%，即同日达存在下单截止时间。该规律由交叉表实测得出，下单小时是下单时即可获得的输入，不属泄露，也是模型超过物流方式单变量（单变量 AUC 0.7276、全模型 0.7646）的主要来源。
- 仓库回写口径（滚动向前）：把概率写回全量 65,752 单时，不能直接用训练好的那一个模型，它见过训练期订单的答案，会打出近 0 或 1 的过拟合概率。实测沿用该口径会把下游预警命中率从 86.51 抬到 94.15，属虚高。故改用滚动向前打分，每半年一个区间、只用该区间之前的数据重训，得到 60,599 单的真实概率；最早 3 个月（2015-01 至 2015-03）5,153 单无历史模型可用，记为冷启动，由物流方式历史延迟率兜底。实测训练期与测试期的高风险命中率分别为 86.44 与 86.64，已基本持平。
- 订单粒度聚合口径：下单时间与物流方式在订单内恒定，直接取一值；数量求和、单价均值、销售额求和；标签取最大值。商品类目与部门取该订单内销售额最大的那条明细。实测有 67.8% 的订单横跨多个商品类目，早期 pandas 脚本用的 first() 即文件里首次出现的那行，属随机选择且无法在 Hive 里干净复现，该口径已废弃。
- 物流方式是最强的单一信号来源，其与延迟标签的关联度为 0.456，单变量 AUC 0.7276。计划发货天数与延迟的关联度同为 0.456，因为二者是一对一映射（取值均为 4 类），关联强度必然相同，故建模只保留物流方式。2026-10-15 补充：在物流方式之外还有一个真实且合规的信号，即同日达订单的下单截止时间（见上一条），用到它以后全模型 AUC 升到 0.7646。
- 必须剔除的泄露字段：`Days for shipping (real)`、`Delivery Status`、`Late_delivery_risk`。不剔除会让 AUC 虚高。

### W2 物流方式履约风险告警（统计阈值）

实测各物流方式延迟率：

| 物流方式 | 订单数 | 承诺天数 | 实际天数均值 | 延迟率 |
|---|---|---|---|---|
| First Class | 10,079 | 1 | 2.00 | 95.3% |
| Second Class | 12,778 | 2 | 4.00 | 76.7% |
| Same Day | 3,571 | 0 | 0.48 | 46.2% |
| Standard Class | 39,324 | 4 | 4.00 | 38.1% |

延迟率极差 57.1 个百分点，全站延迟率 54.8%，全站实际发货天数均值 3.5 天。

关键业务结论：First Class 承诺 1 天实际需 2 天（全站第二快，比 Standard 的 4 天快一倍），延迟率高的真正原因是承诺时效设置过满，而非运力慢。处置建议应是校准承诺时效，而不是停用该方式。

### W3 商品类目履约监控（描述性，原计划为统计阈值告警）

- 全部 50 个类目的延迟率区间为 44.44% 至 70.0%，卡方检验 p = 0.663，不显著。旧文档记的 40.0% 至 65.5% 与 p 小于 0.001 均不可复现，已废弃。
- 控制物流方式后类目效应完全消失（分层卡方合并 p = 0.940）。订单数不少于 1000 的 9 个大类目原始延迟率极差仅 2.23 个百分点，直接标准化后缩到 0.86。
- 定位：降为描述性监控与归因，不参与 W6 评分。详见第七节专节。

### W4 订单转化异常预警（扩展，统计阈值）

- 计算前必须把订单侧截取到共同时间窗口（2017-09 至 2018-01），否则分子分母时间口径不一致，转化率会失真。同一口径下不限制窗口为 34.0%，限定窗口后为 1.646%。
- 正确结果：可关联商品 36 个，全站平均转化率 1.646%（逐商品均值 1.097%），浏览量大于 1000 的商品间转化率极差 122.7 倍。
- 异常组取转化率最低四分位的 8 个商品：合计浏览 58,440 次，仅成交 26 单，组内转化率 0.045%，与全站均值相差 37 倍。
- 重要坑：转化率分子必须用「含该商品的唯一订单数」，任一订单只要包含该商品即计入。若先把订单按 Order Id 去重只留首行再按商品统计，多商品订单会被误算给首个商品，结果被系统性低估约 2.6 倍（旧文档中的 0.637% 与 33 个商品即由此而来），该错误口径已废弃，不要再使用。

### W5 订单流量异常预警（扩展，3 倍标准差）

- 日均访问量 2,791.64 次，标准差 271.99（均为剔除异常日后重算的基线）。
- 三倍标准差告警共命中 6 天，全部为突增，无骤降。极端日为 2017-09-14 单日访问 45,648 次，为日均的 16.4 倍，偏离度 157.57；另有 2017-09-18、09-19、09-26、09-27、09-30 五天，访问量 3,612 至 3,693 次，偏离度 3.02 至 3.31，属轻度突增。
- 口径提醒：先以全部日期算出的第一轮偏离度约为 12.25，随后剔除越限日重算基线，最终偏离度才放大到 157.57。两种口径不可混用，ADS 表里存的是最终口径。

### W6 订单综合风险评分（规则融合）

- 风险分 = 0.6 乘 W1 延迟概率 加 0.4 乘 W2 物流方式风险，后者除以自身最大值归一到 0 至 1，再按分位切高、中、低三级。
- 2026-10-15 起去掉类目项，原因是 W3 经分层卡方检验不成立。
- 本身无独立验证，属设计环节，需系统实现后用回测验证。不参与 W4、W5 的商品与流量告警。

### 已实测后排除的方向（不要再重复探索）

- 订单状态异常类：`Order Status` 完全由支付方式 `Type` 决定，属派生标签。对应关系为 CASH 对 CLOSED；DEBIT 对 COMPLETE 与 ON_HOLD；PAYMENT 对 PENDING_PAYMENT 与 PAYMENT_REVIEW；TRANSFER 对 CANCELED、PENDING、PROCESSING 与 SUSPECTED_FRAUD。
- 折扣与利润类：折扣率与延迟标签的关联度仅 0.017，利润率同理，为模拟字段。
- 时效超期预警：数据只含下单至发货一段，没有送达环节，无法定义送达超期。
- 目的国延迟率告警：对订单数不少于 30 的 103 个国家做卡方检验，p = 0.11；全部 164 个国家 p = 0.09，均不显著，属随机波动。
- 订单复杂度、金额、地理距离：与延迟的关联度均小于 0.01，无信号。
- IP 异常访问：访问日志 IP 分布过于均匀，排名第一的 IP 仅占 0.12%，无爬虫或刷单特征。
- 客户行为类：客户分群与各维度关联度约 0.004，为模拟字段。

## 四、数据质量处理要点（已核验的真实问题）

1. 粒度统一。原始表一行不等于一单，同一订单号平均对应 2.75 行，所有订单级统计必须先按 `Order Id` 去重聚合。
2. 折扣率修复。`Order Item Discount Rate` 标注为 0.06 的 10,029 行（占 5.56%），由折扣金额除以销售额反算实为 5.5%，与标注不符。统一改用 `Order Item Discount / Sales` 重算。
3. 利润字段血缘。`Order Item Profit Ratio` 在 0.01 容差下等于 `Benefit per order / Order Item Total`（匹配率 100%；因该比率仅保留两位小数，在 0.0001 容差下为 61.9%）。`Order Profit Per Order` 与 `Benefit per order` 恒等。三列冗余，仅保留 `Benefit per order`。另有 33,784 行（18.7%）为负利润率，最低 -2.75。
4. 字段冗余。`Shipping Mode` 与 `Days for shipment (scheduled)` 一对一映射（First Class 对 1，Same Day 对 0，Second Class 对 2，Standard Class 对 4），无一行矛盾，建模只保留其一。这也是延迟预警单变量上限的原因。
5. 无效列剔除。`Product Description` 空值率 100%，`Customer Email` 与 `Customer Password` 为脱敏单值，`Product Status` 为常量，`Order Zipcode` 缺失率 86.2%，全部剔除。
6. 编码统一。源文件为 Latin-1 编码，订单城市与目的国含 238 个带重音名称。读取与入库统一按 latin1 解码，进入 HDFS 前一次性转存 UTF-8。
7. 双源交叉验证。订单表的下单时间按小时完全均匀（各小时占比 4.1% 至 4.2%），无昼夜规律；而访问日志的访问小时呈真实昼夜规律（凌晨 0 至 5 点仅占 0.47%，晚间 19 至 22 点占 6.0% 至 6.5%）。同一时期的两个数据源对比，证实订单域的时间字段为模拟生成，因此时间类特征的有效性要分级使用。
8. 金额与折扣字段说明。折扣率不影响利润率（利润率随折扣率变化仅 0.017 量级），但影响利润金额，因为利润金额等于净额乘利润率。

## 五、必须遵守的硬约束

1. 数据集只能用 UCI / Mendeley 公开、可查证、可引用的真实数据，不得使用 AI 生成的合成数据。
2. 建模必须按时间划分训练集与测试集，严禁随机切分，严防未来信息泄露。
3. 必须剔除 `Late_delivery_risk`、`Delivery Status`、`Days for shipping (real)` 三个结果字段。
4. 数仓必须采用 ODS、DWD、DWS、ADS 四层 Hive 分层结构。
5. 系统必须部署在 Ubuntu 虚拟机中，采用离线大数据处理与在线 Django Web 服务分离的架构。
6. 虚拟机内用 Docker 容器化部署 Hadoop 与 Hive，避免依赖冲突。
7. 前端可视化必须包含饼图、柱状图、折线图、世界地图四类图表，采用蓝宝石蓝加白为主色调的卡片式布局。
8. 模型训练完成后序列化为 .pkl 文件，部署到 Django 后端提供实时预测服务。
9. Hive 执行命令必须加 `LANG=C.UTF-8` 环境变量，避免中文乱码。
10. 论文引用数据集使用 Mendeley DOI 10.17632/8gx2fvg2k6.5，注意与同系列旧版数据集区分。

## 六、用户偏好（沟通与呈现）

- 全部用中文，数据全部为中文表述。
- 界面简洁优雅，蓝宝石蓝加白为主色，卡片式布局优于表格，不要 emoji 图标，要有鼠标悬停反馈。
- 前端风格参考 Awwwards 上的 The Bluejack Group Dashboard。
- 沟通时把术语翻译成大白话，不要堆砌符号；书面文档中不要花哨标点、箭头、直角引号、数学符号、圈号。
- 代码改动以最小修改为主，优先改现有文件而不是重写。

## 七、当前目录状态与待决事项

`d:\bishe` 现有内容（已于 2026-10-14 清理完毕）：

- `xnj\` Ubuntu 虚拟机，约 27.8 GB，内含 ubuntu-22.04.1 镜像与虚拟磁盘，是后续部署 Hadoop 与 Hive 的运行环境。
- `data\dataco\` DataCo 数据集，约 91.5 MB；`data\tokenized_access_logs.csv` 流量域数据集，约 95.4 MB（2026-10-14 从桌面复制进来）。
- `docker\` Hadoop 与 Hive 容器编排，含 docker-compose.yml 与 hadoop.env，可直接复用。
- `hive\` 四层数仓 SQL，含 01_ods、02_dwd、03_dws、04_ads 四个文件，均已按 DataCo 字段重写完成，表名与任务书 6.3 节一致，并已在真实 Hive 上跑通。
- `spark\` Spark 侧复算脚本，含 `dws_cross_check.py`，用于跨域关联与流量维度的双引擎互验，并输出各阶段耗时，供任务书 8.5 节的引擎对比实验引用。
- `train_w1.py` W1 延迟预警训练与滚动向前打分脚本（2026-10-15 新增），负责时序切分建模、三模型对比与全量订单概率导出。
- `w1_model.pkl` W1 最优模型（随机森林）序列化文件（2026-10-15 新增），供在线服务加载做实时预测。
- `setup_vm.sh` 虚拟机初始化脚本。
- `任务书-跨境电商订单预警系统.md` 与 `任务书-跨境电商订单预警系统.docx`。注意：2026-10-15 的 W1 指标更新（AUC 0.7646 等）只改了 md，docx 未重新生成，定稿前需统一。
- `AI交接说明.md` 本文件。
- `ssh_setup\setup.sh` 免密登录初始化脚本（2026-10-15 已使用完毕）。

### 运行环境实际情况（2026-10-15 实测）

虚拟机已开机，IP 192.168.100.134，系统 Ubuntu 22.04.1 LTS，2 核，内存 7.7G，根分区 49G 已用 32%。宿主到虚拟机已配好 SSH 密钥免密登录，登录后 sudo 亦免密。私钥原在 `C:\Users\23916\AppData\Local\Temp\bishe_analysis\id_ed25519`，2026-10-16 已另存一份到 `C:\Users\23916\.ssh\id_ed25519`（公钥同目录，后缀 .pub），对应公钥已装入虚拟机 `hgj` 账户。另修正了 `C:\Users\23916\.ssh` 的 ACL，原 `config` 文件残留 `GJH\Hogki` 权限会导致 ssh 报 Bad owner or permissions。此后宿主可直接 `ssh hgj@192.168.100.134` 免密登录，不必再带 `-F none -i <key>`。连接命令模板见第九节。

部署实况（2026-10-15 已按此更正任务书第七节与 6.3 节）：

- Docker 29.1.3，守护进程运行中。`docker-compose`（v1 命令，路径 /usr/bin/docker-compose）与 `docker compose`（v2 插件）都不可用。v1 与 Docker 29 的 API 不兼容，执行 `docker-compose up/down` 会报 `KeyError: 'ContainerConfig'`，而且它在报错前已经把容器删掉了，**这台虚拟机上永远不要再对这套容器用 docker-compose 的 up/down**。容器生命周期一律用 `docker start/stop/restart`，需要重建某一个容器时用 `docker run`（命令见下）。
- 编排文件在虚拟机内实际位于 `~/bishe-docker/`（`docker-compose.yml` 与 `hadoop.env`），内容与宿主 `d:\bishe\docker\` 一致；该目录下原有一份旧数据 `raw_online_retail.csv`，已于 2026-10-15 删除。
- 容器 `namenode`、`datanode`、`hive-metastore`、`metastore-db`、`hive-server`、`spark` 全部运行。前五者镜像为 bde2020 的 Hadoop 2.7.4 与 Hive 2.3.2；`spark` 镜像为 `bde2020/spark-master:2.4.0-hadoop2.7`（与 Hadoop 2.7.4 同代），以 master 模式启动但作业实际以 local 模式执行，未部署 worker。
- 虚拟机内未安装原生 Hadoop 与 Hive，不存在两套环境冲突。
- HDFS 可用，剩余空间 31.39 GB，在线 DataNode 1 个，实测建目录、上传、读取、删除均正常。
- Hive 2.3.2 可正常连接。库为 `bishe_ods`（ODS 层，含 `ods_order_raw`、`ods_access_log_raw` 两张外部表）、`bishe_dwd`（DWD 层，含 `dwd_order_detail`、`dwd_order_main`、`dwd_access_log` 三张表）、`bishe_dws`（DWS 层六张表）、`bishe_ads`（ADS 层八张表）、`bishe_model`（模型输出层，含外部表 `w1_order_prob`，指向 HDFS 目录 `/bishe/model/w1_order_prob`，仅供 ADS 层切换概率口径时读取，不属任务书 6.3 节规定的四层数仓）与 `default`。
- 共享目录 `/mnt/hgfs/bishe` 已挂载，指向宿主 `d:\bishe`，虚拟机内可直接读取两个数据集与全部脚本，无需拷贝。

已知现象，不必再排查：

- namenode 容器的健康检查长期报 unhealthy，原因是探针去 curl 容器的 50070 端口，而该镜像 50070 并不监听，属误报。HDFS 读写实测正常，不要据此判定集群故障。
- 虚拟机挂起恢复后，容器间网络会整体失效，表现为容器互相之间任意端口都不通，而宿主到容器端口正常。根源是 Docker 的 iptables 转发规则失效，解决办法是重启 Docker 守护进程，2026-10-15 已用此法修复。2026-10-16 又出现更重的一种：连虚拟机内访问容器端口也全部不通，`curl 127.0.0.1:8000` 返回 000，Hive 连 HDFS 报 No route to host，且不只 iptables 失效，Docker 网桥接口本身已 DOWN 并丢失地址。判据为 `ip -br a` 里 `br-` 开头的网桥接口显示 DOWN 且不再带 172.18.0.1/16。此时手动 `ip link set up` 并补地址无效，仍须 `sudo systemctl restart docker`，详见第七节「在线层实测结果」末尾的故障复现记录。

### hive-server 重建命令与堆内存的坑（2026-10-15）

重建 hive-server 的完整命令（在虚拟机内执行，其余四个容器不动）：

```
sudo docker rm -f hive-server
sudo docker run -d \
    --name hive-server \
    --restart unless-stopped \
    --network bishe-docker_bishe \
    -p 10000:10000 -p 10002:10002 \
    -e SERVICE_PRECONDITION=hive-metastore:9083 \
    -e HADOOP_HEAPSIZE=2048 \
    -e HIVE_SERVER2_HEAPSIZE=2048 \
    -e HADOOP_CLIENT_OPTS=-Xmx2048m \
    --env-file /home/hgj/bishe-docker/hadoop.env \
    bde2020/hive:2.3.2-postgresql-metastore
```

堆内存的坑（务必保留 `-e HADOOP_CLIENT_OPTS=-Xmx2048m` 这一行）：

- 现象：`hive.server2.heapsize` 已经设成 2048，`hadoop.env` 里也改了，但 HiveServer2 的 JVM 实际堆仍是 512 MB，DWD 装载报 `java.lang.OutOfMemoryError: Java heap space`。
- 根因：镜像内 `/etc/hadoop/hadoop-env.sh` 第 61 行写死了 `export HADOOP_CLIENT_OPTS="-Xmx512m $HADOOP_CLIENT_OPTS"`。该变量随后被拼进 `HADOOP_OPTS`，而 `HADOOP_OPTS` 排在 Hive 自己设的 `-Xmx2048m` 之后，Java 取最后一个 `-Xmx`，于是 2048 被 512 覆盖。
- 验证方法：`sudo docker exec hive-server jinfo -flag MaxHeapSize <hiveserver2的pid>`，应输出 `-XX:MaxHeapSize=2147483648`。只看命令行里的 `-Xmx` 会被误导，因为同时存在三个。
- 注意：不要只改 `docker/hadoop.env`，那个文件里的 `hive.server2.heapsize` 与 `mapred.child.java.opts` 都不足以覆盖上述写死值。

### spark 容器与运行方式（2026-10-15 新增）

重建命令（在虚拟机内执行，其余五个容器不动）：

```
sudo docker run -d \
    --name spark \
    --restart unless-stopped \
    --network bishe-docker_bishe \
    --memory 2560m \
    -p 8080:8080 -p 4040:4040 \
    -v /mnt/hgfs/bishe:/bishe:ro \
    --env-file /home/hgj/bishe-docker/hadoop.env \
    -e SPARK_MODE=master \
    bde2020/spark-master:2.4.0-hadoop2.7
```

运行作业：

```
sudo docker exec spark bash -c 'export SPARK_HOME=/spark; \
  /spark/bin/spark-submit --master local[2] --driver-memory 1g \
  --conf spark.hadoop.fs.defaultFS=hdfs://namenode:9000 \
  --conf spark.sql.shuffle.partitions=4 /bishe/spark/dws_cross_check.py'
```

已知坑：

- 镜像内 Spark 装在 `/spark`，且容器里 `SPARK_HOME` 环境变量为空，直接敲 `spark-submit` 会报 command not found，必须显式 `export SPARK_HOME=/spark` 或用绝对路径 `/spark/bin/spark-submit`。
- 该镜像不会生成 `/etc/hadoop/conf`，`--env-file hadoop.env` 里的 `CORE_CONF_*` 对 Spark 不生效，HDFS 地址只能通过 `--conf spark.hadoop.fs.defaultFS=hdfs://namenode:9000` 注入，否则读 HDFS 会直接失败。
- 容器内 Python 为 3.6.6、pip 为 10.0.1，pandas 依赖 numpy 1.15.4 装不上，因此任务书 8.5 节的对照实验改用同机同任务的 Hive MapReduce，而不是单机 pandas。
- 容器内存上限 2560m，接入现有 `bishe-docker_bishe` 网络，不影响其余五个容器。

### DWD 层实测结果（2026-10-15）

`hive/02_dwd.sql` 已在真实 Hive 上跑通，三张表全部装载成功，末尾五条校验结果：

| 校验项 | 实测值 | 与文档是否一致 |
|---|---|---|
| 订单明细行数 | 180,519 | 一致 |
| 订单数 | 65,752 | 一致 |
| 每单平均行数 | 2.7455 | 一致（文档记 2.75） |
| 订单级主表行数 | 65,752 | 一致 |
| 多类目订单占比 | 44,563 单，67.77% | 一致（文档记 67.8%） |
| W2 各物流方式延迟率 | First Class 10,079 单 95.27%；Second Class 12,778 单 76.72%；Same Day 3,571 单 46.15%；Standard Class 39,324 单 38.13% | 一致 |
| 跨域重叠商品 | 全时段 72 个，共同窗口内 36 个 | 见第二节口径说明 |

分区覆盖 2015-01 至 2018-01 共 37 个月，其中 2017-10 起订单量降为约 2,100 行每月，属源数据本身特征。

### DWS 层实测结果（2026-10-15）

`hive/03_dws.sql` 已按任务书 6.3 节的六张表重写并在真实 Hive 上跑通，全部九项校验通过，无失败。表名为 `dws_order_wide`、`dws_country_risk`、`dws_shipping_risk`、`dws_category_risk`、`dws_product_traffic`、`dws_product_conversion`。

| 校验项 | 实测值 | 与文档是否一致 |
|---|---|---|
| 订单宽表行数与分区数 | 65,752 行、37 个月份 | 一致 |
| 金额三档分布 | 低 21,918、中 21,917、高 21,917 | 新增字段，分布均衡 |
| W2 物流方式延迟率 | 与 DWD 完全一致（95.27 / 76.72 / 46.15 / 38.13） | 一致 |
| W3 类目数与延迟率区间 | 50 个类目，44.44% 至 70.0%，占比合计 100.0% | 类目数一致，区间不一致（见下） |
| 国别维度 | 164 个目的国、5 个市场大区 | 一致 |
| 商品流量维度 | 76 个商品、469,977 次浏览、11,450 行 | 一致 |
| 跨域商品宽表 | 有流量商品 76 个，其中可关联（有成交）36 个 | 一致 |
| W4 全站转化率 | 1.646%，逐商品均值 1.0968% | 一致 |
| W4 极差与异常组 | 浏览量大于 1000 的可关联商品 32 个，极差 122.7 倍；最低四分位 8 个，合计浏览 58,440 次、成交 26 单、组内转化率 0.0445% | 一致 |
| W5 异常日 | 2017-09-14 访问 45,648 次 | 一致 |

键口径说明：

- 类目维度必须按主类目（订单级，取订单内销售额最大的类目）分组，得 50 个类目。不可按「部门加类目」分组：`Category Id` 与 `Category Name` 并非一一对应，实测 51 个编号对 50 个名称，`Electronics` 一个名称挂在两个编号下，按部门加类目会变成 51 个且订单量重复计算。
- 跨域商品宽表保留全部有流量的 76 个商品（含零成交的 40 个），W4 的「可关联商品」指其中 `orders > 0` 的 36 个，统计转化率时必须过滤。用全 76 个算会把零成交商品计入分母，得 0.9773%，属错误口径。

### ADS 层实测结果（2026-10-15）

`hive/04_ads.sql` 已按任务书 6.3 节的八张表重写并在真实 Hive 上跑通，exit_code 为 0，无 FAILED，八组校验全部通过。表名为 `ads_delay_warning`、`ads_dim_warning`、`ads_conversion_warning`、`ads_traffic_warning`、`ads_order_risk_score`、`ads_warning_ticket`、`ads_handle_stats`、`ads_risk_board`。

| 表 | 行数 | 关键数字 |
|---|---|---|
| ads_delay_warning | 65,752 | 概率来自 W1 随机森林滚动向前打分 60,599 单，冷启动区间 5,153 单取物流方式历史延迟率兜底；按概率 0.8 与 0.5 分档，告警 25,596 单（高 12,183、中 13,413、低 40,156），prob_source 已标注来源 |
| ads_dim_warning | 54 | 物流方式 4 加商品类目 50；告警 3 行且全在物流方式（Standard Class 偏离 负16.69 个百分点、z 负66.51；Second Class 正21.89、z 49.73；First Class 正40.44、z 81.59）；商品类目 0 行告警，9 个类目 sample_enough 为 1 |
| ads_conversion_warning | 32 | 可关联 36 个中浏览量大于 1000 的 32 个；告警 8 行；转化率极差 122.7 倍，最低 0.027439%、最高 3.366715%；全站基线 1.646% |
| ads_traffic_warning | 153 | 日均 2791.64、标准差 271.99、告警 6 天，全部突增无骤降 |
| ads_order_risk_score | 65,752 | 风险分 0.6 乘延迟概率 加 0.4 乘物流方式风险，后项除以自身最大值归一；NTILE(3) 分档 高 21,918、中 21,917、低 21,917 |
| ads_warning_ticket | 21,935 | 延迟交付风险 高风险 21,918、订单转化异常 中风险 8、订单流量异常 中风险 6、物流方式履约风险 高风险 3；初始状态全部为 待处理 与 未分配 |
| ads_handle_stats | 5 | 延迟交付类 ticket_cnt 21,918、命中率 86.51%、误报率 13.49；按训练期与测试期拆分命中率分别为 86.44 与 86.64，说明滚动向前口径已消除过拟合；其余三类无结果标签可核对，命中率为 NULL |
| ads_risk_board | 265 | 总体 1、市场大区 5、目的国 164、商品类目 50、物流方式 4、下单月份 37、下单时段 4；各维度 order_share 合计均为 100.0，订单数均为 65,752 |

维度告警的判定三条件，须同时满足才告警：订单数不少于 1000、偏离全站不低于 3 倍标准误、偏离全站不低于 10 个百分点。该规则直接编码了 W3 混杂分析的结论，因此商品类目一行未告警。

W6 权重变更（2026-10-15 按用户决定）：原为 0.5 延迟概率 加 0.3 物流方式 加 0.2 类目，现去掉类目项，改为 0.6 延迟概率 加 0.4 物流方式风险。`ads_order_risk_score` 已删除 category_risk 列并重跑，NTILE 分档人数不变（高 21,918、中 21,917、低 21,917）；同日 W1 概率由冷启动基线换成模型连续值后，风险分区间由 0.388872 至 0.97162 变为 0.2102 至 0.9994，命中率由 85.28 变为 86.51。

Hive 2.3 本地 MapReduce 模式的一个坑：顶层 `INSERT OVERWRITE TABLE t SELECT ... UNION ALL SELECT ...`，只要任一分支含 JOIN，就会生成空读取阶段并报 `return code 2 from org.apache.hadoop.hive.ql.exec.mr.MapRedTask`；把 UNION ALL 包进派生表也无效。只有拆成两条语句，先 INSERT OVERWRITE 再 INSERT INTO 追加，才稳定通过。不含 JOIN 的分支包在派生表内可以正常工作，`ads_warning_ticket` 的四个分支与 `ads_risk_board` 的七个分支即属后者。

另有一个已修复的字段单位 bug：`ads_conversion_warning.conv_rate` 初版忘了乘 100，存成小数 0.033667，与百分数口径的 baseline_conv_rate 混用，导致表内自算极差得 122.9 而非 122.7。修复办法是把派生表列改名为 conv_frac，外层乘 100 后再输出。

### Spark 层实测结果（2026-10-15）

`spark/dws_cross_check.py` 已在真实 Spark 2.4.0（local[2]）上跑通，整作业 37.36 秒。用途是与 Hive 侧做双引擎互验，并产出任务书 8.5 节所需的引擎耗时对比。本脚本只做复算与核对，不覆盖 Hive 的落库结果，也不参与 W1 建模。

双引擎互验，同一口径、两套引擎，结果逐项一致：

| 校验项 | Hive 实测 | Spark 复算 |
|---|---|---|
| 商品流量维度 | 76 商品、469,977 浏览、11,450 行 | 相同 |
| 跨域商品宽表 | 76 商品，其中可关联 36 | 相同 |
| 全站转化率（76 商品口径） | 0.9773% | 0.9773% |
| 可关联商品转化率 | 36 个、1.646%、逐商品均值 1.0968%、合计 4,593 单 / 279,036 浏览 | 相同 |
| W4 极差与异常组 | 极差 122.7 倍，最低 0.027439%、最高 3.366715%；异常组 8 个、浏览 58,440、成交 26、组内 0.0445% | 相同 |
| W5 基线 | 日均 2,791.64、标准差 271.99 | 相同 |
| W5 告警 | 命中 6 天，极端日 2017-09-14 访问 45,648、偏离 157.57 | 相同 |

口径注记：W5 的标准差必须用样本口径，即除以 n 减 1。首次复算误用总体口径，得 271.09 与偏离 158.09，看着像两边数据不一致，实际只是分母差一个系数；改用 `stddev_samp` 后与 Hive 的 `STDDEV_SAMP` 完全吻合。

引擎耗时对比，同机同数据（虚拟机 2 核 7.7G）：

| 任务 | Hive（MapReduce local） | Spark（local[2]） |
|---|---|---|
| 跨域关联（W4，含 JOIN 与 COUNT DISTINCT） | 语句 63.8 秒，整命令 84 秒 | 10.4 秒 |
| 商品流量聚合（W5） | 语句 21.9 秒，整命令 42 秒 | 3.8 秒 |
| 整作业 | 未整体计时 | 37.36 秒 |

结论：Spark 在迭代式聚合上明显更快，但结果与 Hive 完全相同，准确度不受引擎影响；模型训练仍用 Python 的 scikit-learn，不用 Spark MLlib。

Spark 在本项目里的定位是架构可扩展性与落地前景，不是提升准确度。

#### 答辩应答口径（按问答卡顺序讲，不夸大）

问答一：数据本来就不算多，为什么要加 Spark？

1. 技术栈与生产级大数据架构同构：HDFS 分布式存储、Hive 四层数仓、Spark 计算引擎，分层职责清晰，不是为凑工具而堆栈。
2. 实测同一任务 Spark 比 MapReduce 快约 6 倍，跨域关联 10.4 秒对 63.8 秒，且数据规模越大差距越明显。
3. 课题场景是跨境电商订单预警，真实平台的日订单量远不止本数据集这个规模。这 65 万行是公开可复现的教学样本，架构是按真实业务规模设计的。
4. 真要扩到集群，只需把作业提交参数里的 master 从 local 改成集群地址，业务代码一行不用重写。

同场补一句实情：本机是单机容器化部署、2 核、local 模式，当前数据规模下单机足够跑完，选这套栈是为了双数据源纳管、分层建模与后续扩容留余地。这样回答既不夸大，也把落地前景讲清楚了。

切忌说「这套系统能处理海量数据」，会被追问「那你现场演示一下集群」，而本机只是单机。

问答二：想真正落地，必须做集群吗？

不必。落地与否取决于数据量，不取决于用不用 Spark。当前这套单机容器化部署，对一个日均几千单的小电商就是可以直接用的生产形态；集群只是数据长大之后的扩展路径，而这套架构的价值恰恰是现在小规模能跑、将来扩容只改配置不改代码。

问答三：Spark 在这个项目里到底干了什么？

承担跨域关联与流量维度的复算，与 Hive 侧结果逐项一致，构成双引擎互验，用来证明四层数仓产出的数字可靠；同时产出引擎耗时对比实验。它不负责提升准确度，准确度由特征与算法决定，与计算引擎无关。

关于动机：本科阶段「学过 Spark 想在实际项目里用起来」是很正常的出发点，答辩口径讲「按生产可用架构对齐」即可，与学以致用并不矛盾，不必心虚。

Spark 阶段到此收口，不再追加工作：不做数据放大实验、不加 worker 节点、不用 MLlib 建模。

### W3 类目告警经实测不成立，已定降为描述性监控（2026-10-15 定）

任务书记载「50 个类目，延迟率区间 40.0% 至 65.5%，卡方检验 p = 1.2e-07，差异显著」。本次用卡方检验实测，结论相反：

| 分组维度 | 卡方值 | 自由度 | p 值 | 结论 |
|---|---|---|---|---|
| 物流方式（4 类） | 13,661.67 | 3 | 小于 1e-15 | 极显著 |
| 目的国（164 类） | 187.59 | 163 | 0.091 | 不显著 |
| 商品类目（全部 50 类） | 44.33 | 49 | 0.663 | 不显著 |
| 商品类目（订单数不少于 100，36 类） | 32.81 | 35 | 0.574 | 不显著 |
| 商品类目（订单数不少于 500，14 类） | 8.92 | 13 | 0.779 | 不显著 |
| 商品类目（订单数不少于 1000，9 类） | 4.98 | 8 | 0.760 | 不显著 |

方法可信度依据：同一套脚本算出目的国 p = 0.091，与文档记录的 0.09 完全吻合；物流方式 p 小于 1e-15，与已知的真实信号吻合。故本表结论可信。

原因分析：类目延迟率的高低几乎完全由样本量决定。排最前的 Golf Bags & Carts 只有 10 单，延迟率 70.0% 即 7 单；排最后的 Men's Golf Clubs 有 63 单，延迟率 44.44%。全站延迟率 54.8% 已接近抛硬币，小样本类目的波动足以覆盖 44% 至 70% 这个区间。提高样本量门槛后差异反而更小，说明不存在类目效应。

文档同时记载的区间 40.0% 至 65.5% 在六种口径下均不可复现，实测区间为 44.44% 至 70.0%。

### W3 混杂分析（2026-10-15 追加，用户要求先做归因再定）

前提：类目与物流方式并不独立。50 乘 4 列联表卡方 289.75，自由度 147，p = 2.1e-11，各类目的物流方式构成确有显著差异。例如延迟率居前的 Golf Bags & Carts（10 单）First Class 占 40.0%，而全站 First Class 只占 15.3%；延迟率居末的 Men's Golf Clubs（63 单）First Class 只占 9.5%。

分层检验，即在每个物流方式内部单独测类目效应，以消除物流方式构成的干扰：

| 分层 | 类目数 | 订单数 | 卡方 | 自由度 | p 值 |
|---|---|---|---|---|---|
| First Class | 50 | 10,079 | 34.51 | 49 | 0.942 |
| Second Class | 50 | 12,778 | 34.90 | 49 | 0.936 |
| Standard Class | 50 | 39,324 | 30.46 | 49 | 0.983 |
| Same Day | 47 | 3,571 | 63.63 | 46 | 0.043 |
| 合并 | 197 | 65,752 | 163.49 | 193 | 0.940 |

Same Day 分层 p = 0.043 属擦边，四次检验经 Bonferroni 校正后阈值为 0.0125，故亦不显著。合并后 p = 0.940，控制物流方式之后类目效应完全消失。

直接标准化，即用全站各物流方式的延迟率折算每个类目的理论延迟率，看离散度收窄多少：

| 样本量档 | 类目数 | 原始极差 | 标准化后极差 |
|---|---|---|---|
| 订单数不少于 1000 | 9 | 2.23 | 0.86 |
| 500 至 1000 | 5 | 4.73 | 7.41 |
| 100 至 500 | 22 | 17.04 | 6.14 |
| 少于 100 | 14 | 25.56 | 24.06 |

大样本的 9 个类目（订单数不少于 1000）原始延迟率极差只有 2.23 个百分点，标准化后缩到 0.86，基本没有差别。剩余离散度集中在订单数不足 100 的 14 个小类目，属抽样波动。

结论：延迟差异的唯一真实来源是物流方式，类目本身不构成独立的延迟风险。类目确实与物流方式有构成关联，但该关联未转化为可检出的延迟率差异。

最终定位（2026-10-15 用户决定）：W3 保留类目看板与阈值巡检能力，但降为描述性监控，结论改为描述性表述，不声称统计显著，也不与 W1、W2 并列作为预测性风险项。W6 综合评分去掉类目项，改为 0.6 延迟概率 加 0.4 物流方式风险，`hive/04_ads.sql` 已同步修改并重跑通过。任务书 md 已按此改写，docx 未改（用户要求只改 md）。

遗留待清（2026-10-15 已清理完毕，以下为清理记录）：

- 已删 Hive 表 `bishe_ods.ods_online_retail`（外部表，只删元数据）。
- 已删 HDFS 目录 `/user/hive/warehouse/ods/online_retail/`，内含 `raw_online_retail.csv`，92.8 MB。
- 已删 HDFS 目录 `/user/hive/warehouse/bishe_ods.db/` 下的旧内容，随后把空的 `bishe_ods.db` 目录补回（该目录是 `bishe_ods` 库的位置，删掉后建表会报目录不存在）。
- 已删虚拟机内 `/home/hgj/bishe-docker/raw_online_retail.csv`，89 MB。
- 清理后 Hive 只剩 `bishe_ods`（`ods_order_raw`、`ods_access_log_raw`）与 `bishe_dwd`（`dwd_order_detail`、`dwd_order_main`、`dwd_access_log`）两个业务库和 `default`，仓库下只剩 `ods/`、`bishe_ods.db/`、`bishe_dwd.db/` 三项。
- 保留 `/home/hgj/bishe-docker/hadoop.env.bak.20261015154228`（改堆参数前的备份，1.9 KB），确认无需回滚后可删。

已删除、不可恢复的旧数据集 Online Retail II 遗留物：

- `output\` 目录，约 127.6 MB，含 33 张图表、4 个模型 pkl、若干中间 CSV。
- `online_retail_II.xlsx` 原始数据。
- 根目录 11 个分析脚本：seasonal_analysis、ml_modeling、germany_deepdive、feature_engineering、export_raw_csv、eda_visualization、data_cleaning、customer_group_analysis、country_drilldown、country_analysis、model_comparison。
- `论文-双算法对比实验.md` 实验稿。
- `django_app\` 整套基于旧表结构的 Django 应用。

注意 `docker\` 目录的编排文件不含 Spark 服务，只含 HDFS 与 Hive 五个容器，可直接复用；`hive\` 里四个 SQL 均已按 DataCo 字段重写并在真实 Hive 上跑通。

待决事项与已定事项：

1. 已定：不另建文件夹，直接在 `d:\bishe` 继续，同一工作区内新建对话并让新 AI 先读本文件。
2. 已定：`django_app` 删除，在线服务层按 DataCo 完全重做，不复用旧框架。
3. 已完成（2026-10-14）：消除两份文档的 5 处不一致。W1 基线改用复跑值（2026-10-15 再次复跑后为 Random Forest AUC 0.7646、F1 0.6974，Logistic Regression 0.7456、0.6577，XGBoost 0.7622、0.6971，见第三节 W1）；W4 改用正确口径，全站 1.646%、极差 122.7 倍、可关联商品 36 个；粒度 2.74 改为 2.75；Ubuntu 版本按实际环境统一为 22.04（虚拟机 vmx 挂载的是 ubuntu-22.04.1-desktop-amd64.iso，`setup_vm.sh` 顶部注释同步改为 22.04）；删除已不再使用的 Online Retail II 参考文献。任务书 md 与 docx 均已同步重新生成。
4. 已完成（2026-10-14）：ODS 与 DWD 层脚本按 DataCo 重写完成。`hive/01_ods.sql` 建订单域与流量域两张外部表 `ods_order_raw`、`ods_access_log_raw`；`hive/02_dwd.sql` 建 `dwd_order_detail`、`dwd_order_main`、`dwd_access_log`，表名与任务书 6.3 节一致。
5. 已完成（2026-10-15）：ODS 与 DWD 层已在真实 Hive 上跑通并逐条校验通过，结果见第七节「DWD 层实测结果」。
6. 已完成（2026-10-15）：旧数据集 Online Retail II 在虚拟机内的残留（旧表、HDFS 目录、旧 CSV）已全部清理，明细见第七节「遗留待清」。
7. 已完成（2026-10-15）：DWS 聚合层 `hive/03_dws.sql` 按任务书 6.3 节的六张表重写并在真实 Hive 上跑通，九项校验全部通过，明细见第七节「DWS 层实测结果」。
8. 已定（2026-10-15）：W3 类目告警经卡方检验实测不显著（全部 50 类 p = 0.663，控制物流方式后合并 p = 0.940），降为描述性监控，W6 去掉类目项，见第七节「W3 类目告警经实测不成立，已定降为描述性监控」。
9. 已完成（2026-10-15）：ADS 层 `hive/04_ads.sql` 按任务书 6.3 节的八张表重写并在真实 Hive 上跑通，八组校验全部通过，明细见第七节「ADS 层实测结果」。
10. 已完成（2026-10-15）：任务书第七节开发环境口径已按实况更正（Hadoop 2.7.4、Hive 2.3.2、Spark 2.4.0 容器化部署，Docker 29.1.3，容器生命周期用 docker 命令管理，本地执行模式未部署 YARN）；6.3 节服务清单已把原有的 spark-master 与 spark-worker 两行合并为单个 spark 容器；大数据组件一行由 Spark 3.x 更正为 2.4.0。
11. 已解决（2026-10-15，用户选择补部署 Spark）：已追加单个 Spark 2.4.0 容器，并用 `spark/dws_cross_check.py` 复算跨域关联与流量维度，与 Hive 结果逐项一致，同时得出引擎耗时对比。任务书 5.5、5.6、6.1、6.2 节已改为 Hive 与 Spark 双引擎实现并互验、模型训练由 Python 的 scikit-learn 与 XGBoost 完成，不再声称 Spark 承担建模；8.5 节的风险应对也改成本次实测的耗时数字。明细见第七节「Spark 层实测结果」。
12. 已完成（2026-10-15）：W1 模型落地。新增 `d:\bishe\train_w1.py`（训练与滚动向前打分脚本），模型序列化为 `d:\bishe\w1_model.pkl`；HDFS 新增模型输出目录 `/bishe/model/w1_order_prob`，Hive 新增 `bishe_model.w1_order_prob` 外部表（模型输出层，不属任务书 6.3 节规定的四层数仓，属模型回写暂存）；`hive/04_ads.sql` 已把 `ads_delay_warning` 与 `ads_order_risk_score` 的延迟概率由冷启动基线换成模型连续值并重跑通过，实测数字见第七节「ADS 层实测结果」。
13. 已完成（2026-10-16）：在线层落地。MySQL 8.0 容器 `bishe-mysql` 承载库 `bishe_online`，八张 ADS 表经 Hive 导出文本后装载，行数与 Hive 逐表一致；Django 5.2 容器 `bishe-django` 加载 `w1_model.pkl` 提供实时预测；前端为蓝宝石蓝加白卡片式看板，含饼图、柱状图、折线图与世界地图四类图表，并实现工单处置闭环。明细见第七节「在线层实测结果」。
14. 下一步：浏览器端视觉核验、任务书与 docx 定稿前的口径统一。

### 在线层实测结果（2026-10-16）

在线层按 DataCo 完全重做，不沿用已删除的旧 django_app。工程位于宿主 `d:\bishe\online\`，经共享目录在虚拟机内可见。

容器与镜像：

| 容器 | 镜像 | 端口 | 说明 |
|---|---|---|---|
| bishe-mysql | mysql:8.0 | 3306 | 业务库 `bishe_online`，utf8mb4，启动参数含 `--local-infile=1` 与 mysql_native_password |
| bishe-django | bishe-django:1.0（基于 python:3.13-slim 构建） | 8000 | 只读挂载 `/mnt/hgfs/bishe:/data:ro` |

八张 ADS 表装载行数，与 Hive 逐表一致：`ads_delay_warning` 65752、`ads_warning_ticket` 21935、`ads_order_risk_score` 65752、`ads_risk_board` 265、`ads_traffic_warning` 153、`ads_dim_warning` 54、`ads_conversion_warning` 32、`ads_handle_stats` 5。导出文本在 `d:\bishe\ads_export\`，导出脚本为 `hive/05_export_ads.sql`，装载命令为 `dashboard/management/commands/load_ads.py`。

Django 侧要点：

- 用 PyMySQL 顶替 mysqlclient，钩子写在 `config/__init__.py`，容器内直接装 mysqlclient 会失败。
- 模型与依赖版本必须锁定。`w1_model.pkl` 在 scikit-learn 1.9.1、pandas 3.0.3、numpy 2.5.1 下训练，容器 requirements 固定这三者，否则 pkl 无法无损加载。
- 世界地图不采用经纬度。实测订单表经纬度为客户所在地坐标，各目的国均值落在美国乔治亚州，avg_lat 约 29.6、avg_lng 约 -84.9，无法作为目的国定位，故 `ads_risk_board` 不加经纬度列，地图改为国名映射着色。
- 国名映射维表为 `dashboard/geo.py`。订单表目的国名为西班牙语，ECharts 底图为英文，实测 61 个可直接匹配，另建 103 条映射，校验结果为 0 错误、无重复指向、全部键被使用。未能上图的仅 Martinica、Hong Kong、Taiwán、Guadalupe、Guayana Francesa 五处，合计 111 单。

接口实测（2026-10-16 复验）：页面与 `api/dashboard/`、`api/orders/`、`api/tickets/`、`api/handle-stats/` 均返回 200，静态资源返回 200；实时预测入参物流方式 First Class 加净额 360，返回延迟概率 0.915、等级高。入参 `order_datetime` 为必填，缺失时返回 400。

看板关键实测数字：订单总数 65752、全站延迟率 54.82%、预警订单 25596、风险分级高 12183 中 13413 低 40156、平均延迟概率 0.5408、工单数 21935、命中率 86.51%、误报率 13.49%、总营收 33,054,402.04；四类物流方式延迟率沿用 W2 值；维度条目数为目的国 164、月度点 37、流量日 153、类目 15、转化商品 32、时段 4。

2026-10-16 故障复现与修法：虚拟机休眠唤醒后 Docker 网络整体失效，程度比 2026-10-15 更重，连虚拟机内访问容器端口也不通，`curl 127.0.0.1:8000` 返回 000，Hive 连 HDFS 报 No route to host，namenode 把 datanode 判为 dead。判据为 `ip -br a` 中 `br-` 开头的网桥接口变为 DOWN 且丢失 172.18.0.1/16 地址，手动 `ip link set up` 并补地址无效。修法为 `sudo systemctl restart docker`，重启后网桥回升为 UP 并带回地址，八个容器按 unless-stopped 自动全部拉起，HDFS 的 datanode 自动重新注册，Live datanodes 1、Under replicated 0，随后页面与接口恢复 200、Hive 可正常 `show databases`，无需重建任何容器。另已对早期 OOM 退出的重复 hive-server 容器执行 `docker update --restart=no`，避免开机时被一起拉起。

2026-10-16 工单处置接口卡死的根因与修法：前端提交处置后长期停在「提交中」，后端日志里没有该 POST 记录，直连接口 curl 超时返回 000，但同一脚本里紧邻的 GET 正常。逐段定位确认 `WarningTicket.objects.get` 与 `ticket.save()` 均在毫秒级，卡点在 `_refresh_handle_stats()`。根因是 `WarningTicket` 的 Meta 里设了 `ordering = ["ticket_id"]`，Django 执行 `values_list("warn_type", flat=True).distinct()` 时会把默认排序字段一并塞进 SELECT，去重完全失效，循环次数等于工单总数 21,918 而不是预警类型的 4 个；每次循环又要跑 count、values_list、update 三条查询，合计六万余条 SQL，单次处置需十分钟以上并吃满一个 CPU 核，前端 fetch 于是永久挂起。修法是在 distinct 之前先 `order_by()` 清空排序，改后同一 POST 从十分钟级降到 0.14 秒。修改文件为 `d:\bishe\online\dashboard\views.py`，并把该文件 `docker cp` 进 `bishe-django` 的 `/app` 后重启容器才生效，因为在线层代码打在镜像里，`/data` 只是只读挂载，改宿主上的文件不会自动进容器。

2026-10-16 前端页面拆分与图表裁切修复：原看板把 7 张图与 4 个功能模块全部堆在首页，现按侧重点拆为五页，用 hash 路由切换（`#overview` 总览、`#risk` 履约风险、`#traffic` 流量与转化、`#orders` 订单查询与预测、`#tickets` 工单处置），仍是同一个 `index.html` 加 tab 导航，不新建多个 HTML。要点一：`display:none` 的容器量不到宽高，ECharts 必须在切到该页时才 init，切页后再 `resize()`，故 `app.js` 里加了 `VIEW_CHARTS` 映射与 `rendered` 惰性标记。要点二：原来的图表裁切是四张图各自的真实缺陷，风险等级饼图与物流方式饼图是半径过大导致标签被卡片边缘切掉，已收紧半径并加 `labelLine` 与 `avoidLabelOverlap`；物流方式延迟率柱状图的横轴四个名称过长被自动隐藏，已把名称按空格拆成两行并强制 `interval: 0`；商品类目前十五的横向条形图是容器只有 280px 放不下 15 行，已为它单独设 460px 高容器并给右侧数值标签留出空间。要点三：柱状图与条形图的基线数值原先用 markLine 标签画在图内，会与柱顶数值重叠，已改成 `label.show=false` 并把基线数值写进卡片副标题。要点四：`.grid` 由 auto-fit 改为固定两列、总览页用三列（`.grid-3`），避免混用 `card-full` 时行内出现空列；窄屏下 `card-wide` 必须回到单列，否则隐式列会撑出横向滚动条。要点五：页面引用的 `app.css` 与 `app.js` 已加 `?v=2` 版本号，避免浏览器拿到旧缓存。

## 八、已知的坑（前人踩过，勿重复）

- 以下这条是旧数据集 Online Retail II 的经验，对 DataCo 不适用，仅作记录，不要当成 DataCo 的处理要求：取消订单的 Quantity 为负值会让模型学到虚假特征，必须先取绝对值。DataCo 的 Order Item Quantity 取值 1 至 5，全为正数，不存在负值用于表示取消的情况。
- 类别极度不平衡时准确率无参考价值，必须展示 Recall、AUC。
- Django 模型 Meta 若带 ordering，再对它做 `values_list(..., flat=True).distinct()` 会因排序字段被并入 SELECT 而失去去重效果，务必写成 `order_by().values_list(...).distinct()`，否则循环次数会等于表行数。
- `w1_model.pkl` 里的 `metrics` 是按模型名分层的字典，形如 `{"Random Forest":{"auc":..,"f1":..},"Logistic Regression":{..},"XGBoost":{..}}`，`predictor.model_info()` 原样透出。前端取指标必须写 `metrics[model_name].auc`，写成扁平的 `metrics.auc` 会取到 undefined，页面显示成 NaN。
- 看板主页原先没有禁用缓存，前端改版后浏览器会继续用缓存的 HTML，连带加载旧的 `app.js`，表现为「代码已更新但页面还是老样子」。已在 `views.py` 的 `index` 上加 `@never_cache`，并在模板里给 css 与 js 加版本查询参数。
- Docker 镜像拉取易因网络中断，需配置国内镜像源并启用自动重试。
- bde2020 的 Hadoop 镜像健康检查探针易误报，需调整服务就绪条件，避免容器启动死锁。
- Word 文件被占用时 pandoc 会报 Permission denied，应先关闭 Word 再生成。
- 用浏览器代理给「目的国订单分布」世界地图截图做验证时会被平台内容审核拦截，报「图片包含敏感内容 (4016)」，整个验证任务会因此中断并在对话里弹出红色错误框。含地图的页面一律改用读取页面结构的文字方式验证，不要截图；纯图表页可以正常截图。
- 中文路径在后续 Docker 挂载与 Hadoop 处理环节可能引发编码问题，新目录建议用英文名。

## 九、下一步建议

1. 在 `d:\bishe` 中另开一个新对话，第一句先让新 AI 读本文件。
2. 已完成：`tokenized_access_logs.csv` 已复制到 `d:\bishe\data\`，与 DataCo 订单表放在一起，便于统一管理和后续上传 HDFS。
3. 已完成（2026-10-15）：四层数仓全部落地（`hive/01_ods.sql`、`02_dwd.sql`、`03_dws.sql`、`04_ads.sql`），均已在真实 Hive 上跑通；W1 模型已训练并落盘为 `d:\bishe\w1_model.pkl`，全量订单连续概率已回写并覆盖 `ads_delay_warning` 与 `ads_order_risk_score` 的延迟概率口径。下一步实现在线服务与前端看板。

### 虚拟机连接方式（2026-10-15 建立）

虚拟机已配好免密 SSH 与免密 sudo，连接不需要密码。私钥在宿主 `C:\Users\23916\.ssh\id_ed25519`（2026-10-16 从 Temp 目录另存过来并修好 ACL），原路径 `C:\Users\23916\AppData\Local\Temp\bishe_analysis\id_ed25519` 仍可用。

连接命令模板（PowerShell）：

```
$key = "C:\Users\23916\.ssh\id_ed25519"
$o = @("-F","none","-i",$key,"-o","BatchMode=yes","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-o","IdentitiesOnly=yes","-o","LogLevel=ERROR","-o","ConnectTimeout=15")
& ssh @o "hgj@192.168.100.134" '要执行的命令'
```

执行多行脚本时用 base64 传输，避免引号转义问题：

```
$raw = Get-Content "本地脚本.sh" -Raw
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
& ssh @o "hgj@192.168.100.134" ("echo " + $b64 + " | base64 -d | bash")
```

注意事项：

- 这类命令需要关闭沙箱执行（vmrun 与 ssh 会读写沙箱外的路径）。
- 虚拟机 IP 由 VMware NAT 动态分配，重启后可能变化，可用 `vmrun -T ws getGuestIPAddress "d:\bishe\xnj\Ubuntu 64 位.vmx"` 重新获取。
- 虚拟机重启后若容器间网络不通，先重启 Docker 守护进程。
- Hive 相关命令必须带 `LANG=C.UTF-8`，例如 `docker exec -e LANG=C.UTF-8 hive-server beeline -u jdbc:hive2://localhost:10000 -f /tmp/脚本.sql`。
- Spark 作业命令见第七节「spark 容器与运行方式」，核心是必须显式 `export SPARK_HOME=/spark` 并用 `--conf spark.hadoop.fs.defaultFS=hdfs://namenode:9000` 指定 HDFS 地址。
- 数据准备：订单表为 Latin-1 编码，进 HDFS 前需 `iconv -f LATIN1 -t UTF-8` 转换；两个 CSV 表头均由 Hive 建表语句的 `skip.header.line.count=1` 跳过，直接原样上传即可。
