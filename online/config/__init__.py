# -*- coding: utf-8 -*-
"""Django 配置包初始化。

Django 的 MySQL 后端默认要求 mysqlclient，这里统一改用纯 Python 的 PyMySQL，
并在导入配置时即完成顶替，保证命令行与 WSGI 两种启动方式下都生效。
"""

import pymysql

# Django 会校验驱动版本不低于 1.4.3，PyMySQL 自报版本较低，此处补齐
pymysql.version_info = (1, 4, 3, "final", 0)
pymysql.install_as_MySQLdb()
