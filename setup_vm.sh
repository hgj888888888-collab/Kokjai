#!/bin/bash
# ============================================================
# Ubuntu 22.04 虚拟机一键环境配置脚本
# 毕业设计：《基于跨境电商订单数据的订单异常状态预测与分析》
#
# 组件清单：
#   - Python 3.8 + pip + venv
#   - Java 8 (Hadoop/Hive/Spark 依赖)
#   - Hadoop 3.3.x (HDFS)
#   - Hive 3.1.x
#   - Spark 3.x (PySpark)
#   - Django 4.x + 依赖库
#
# 使用方式：
#   chmod +x setup_vm.sh
#   sudo ./setup_vm.sh
# ============================================================

set -e

echo "============================================"
echo "[1/6] 更新系统包 & 安装基础工具"
echo "============================================"
apt-get update -y
apt-get install -y wget curl vim git ssh rsync software-properties-common

echo ""
echo "============================================"
echo "[2/6] 安装 Python 3.8 + pip + venv"
echo "============================================"
apt-get install -y python3 python3-pip python3-venv python3-dev
pip3 install --upgrade pip

# 创建项目虚拟环境
PROJECT_DIR=/opt/bishe
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR
python3 -m venv venv
source venv/bin/activate

echo "虚拟环境已创建: $PROJECT_DIR/venv"

echo ""
echo "============================================"
echo "[3/6] 安装 Java 8"
echo "============================================"
apt-get install -y openjdk-8-jdk
java -version
echo 'export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64' >> ~/.bashrc
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> ~/.bashrc
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

echo ""
echo "============================================"
echo "[4/6] 安装 Hadoop 3.3.6 + HDFS"
echo "============================================"
cd /opt
wget -q https://archive.apache.org/dist/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz
tar -xzf hadoop-3.3.6.tar.gz
mv hadoop-3.3.6 hadoop
rm hadoop-3.3.6.tar.gz

echo 'export HADOOP_HOME=/opt/hadoop' >> ~/.bashrc
echo 'export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop' >> ~/.bashrc
echo 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin' >> ~/.bashrc
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin

# 配置 Hadoop 伪分布式
cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<'EOF'
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:9000</value>
    </property>
    <property>
        <name>hadoop.tmp.dir</name>
        <value>/opt/hadoop/tmp</value>
    </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<'EOF'
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
</configuration>
EOF

echo "Hadoop 安装完成，首次使用请执行: hdfs namenode -format && start-dfs.sh"

echo ""
echo "============================================"
echo "[5/6] 安装 Hive 3.1.3"
echo "============================================"
cd /opt
wget -q https://archive.apache.org/dist/hive/hive-3.1.3/apache-hive-3.1.3-bin.tar.gz
tar -xzf apache-hive-3.1.3-bin.tar.gz
mv apache-hive-3.1.3-bin hive
rm apache-hive-3.1.3-bin.tar.gz

echo 'export HIVE_HOME=/opt/hive' >> ~/.bashrc
echo 'export PATH=$PATH:$HIVE_HOME/bin' >> ~/.bashrc
export HIVE_HOME=/opt/hive
export PATH=$PATH:$HIVE_HOME/bin

# 修复 Hive 与 Hadoop 的 guava 版本冲突
rm -f $HIVE_HOME/lib/guava-19.0.jar
cp $HADOOP_HOME/share/hadoop/common/lib/guava-27.0-jre.jar $HIVE_HOME/lib/

echo "Hive 安装完成，首次使用请执行: schematool -dbType derby -initSchema"

echo ""
echo "============================================"
echo "[6/6] 安装 Python 项目依赖 (Django + 机器学习)"
echo "============================================"
source $PROJECT_DIR/venv/bin/activate
pip install django==4.2.* pandas numpy matplotlib seaborn scikit-learn xgboost joblib xlsxwriter openpyxl pyhive pyspark pymysql

echo ""
echo "============================================"
echo "✅ 环境配置完成！"
echo "============================================"
echo "下一步操作："
echo "  1. source ~/.bashrc"
echo "  2. hdfs namenode -format"
echo "  3. start-dfs.sh"
echo "  4. schematool -dbType derby -initSchema"
echo "  5. 启动 Django: cd /opt/bishe && source venv/bin/activate && python manage.py runserver 0.0.0.0:8000"
echo ""
