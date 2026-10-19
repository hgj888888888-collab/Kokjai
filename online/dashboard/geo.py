# -*- coding: utf-8 -*-
"""目的国名称映射，供世界地图着色使用。

订单表的 order_country 取自数据集原始字段，为西班牙语国名；
ECharts 世界地图底图为英文国名且部分使用了缩写形式，两者只有 61 个能直接对上。
这里维护一份映射维表，把余下的国名对齐到底图名称，保证地图着色不串国。

说明：
1. 数值列无对应关系，仅做名称对齐，不改动任何统计口径。
2. 底图中不存在的地区（香港、台湾、马提尼克、瓜德罗普、法属圭亚那）不做映射，
   这些地区合计订单量极小，接口会单独返回，前端在卡片说明中标注未上图。
"""

import json
import os

from django.conf import settings

# 西语国名到世界地图英文国名的映射
NAME_MAP = {
    "Estados Unidos": "United States",
    "Francia": "France",
    "México": "Mexico",
    "Alemania": "Germany",
    "Reino Unido": "United Kingdom",
    "Brasil": "Brazil",
    "Italia": "Italy",
    "España": "Spain",
    "República Dominicana": "Dominican Rep.",
    "Turquía": "Turkey",
    "Filipinas": "Philippines",
    "Países Bajos": "Netherlands",
    "Panamá": "Panama",
    "Nueva Zelanda": "New Zealand",
    "Irán": "Iran",
    "Tailandia": "Thailand",
    "Egipto": "Egypt",
    "SudAfrica": "South Africa",
    "Marruecos": "Morocco",
    "Pakistán": "Pakistan",
    "Suecia": "Sweden",
    "Japón": "Japan",
    "República Democrática del Congo": "Dem. Rep. Congo",
    "Ucrania": "Ukraine",
    "Rusia": "Russia",
    "Irak": "Iraq",
    "Arabia Saudí": "Saudi Arabia",
    "Corea del Sur": "Korea",
    "Perú": "Peru",
    "Malasia": "Malaysia",
    "Bélgica": "Belgium",
    "Singapur": "Singapore",
    "Polonia": "Poland",
    "Bangladés": "Bangladesh",
    "Myanmar (Birmania)": "Myanmar",
    "Irlanda": "Ireland",
    "Haití": "Haiti",
    "Argelia": "Algeria",
    "Rumania": "Romania",
    "Suiza": "Switzerland",
    "Noruega": "Norway",
    "Dinamarca": "Denmark",
    "Finlandia": "Finland",
    "Camerún": "Cameroon",
    "Kazajistán": "Kazakhstan",
    "Costa de Marfil": "Côte d'Ivoire",
    "Sudán": "Sudan",
    "Kenia": "Kenya",
    "Afganistán": "Afghanistan",
    "Bielorrusia": "Belarus",
    "República Checa": "Czech Rep.",
    "Camboya": "Cambodia",
    "Zimbabue": "Zimbabwe",
    "Hungría": "Hungary",
    "Trinidad y Tobago": "Trinidad and Tobago",
    "Lituania": "Lithuania",
    "Uzbekistán": "Uzbekistan",
    "Jordania": "Jordan",
    "Kirguistán": "Kyrgyzstan",
    "Níger": "Niger",
    "Libia": "Libya",
    "Benín": "Benin",
    "Ruanda": "Rwanda",
    "Papúa Nueva Guinea": "Papua New Guinea",
    "Moldavia": "Moldova",
    "Croacia": "Croatia",
    "Siria": "Syria",
    "Azerbaiyán": "Azerbaijan",
    "Turkmenistán": "Turkmenistan",
    "Bosnia y Herzegovina": "Bosnia and Herz.",
    "Túnez": "Tunisia",
    "Gabón": "Gabon",
    "Sierra Leona": "Sierra Leone",
    "Grecia": "Greece",
    "Emiratos Árabes Unidos": "United Arab Emirates",
    "Yibuti": "Djibouti",
    "Líbano": "Lebanon",
    "Eslovaquia": "Slovakia",
    "República Centroafricana": "Central African Rep.",
    "Etiopía": "Ethiopia",
    "Lesoto": "Lesotho",
    "República del Congo": "Congo",
    "Luxemburgo": "Luxembourg",
    "Chipre": "Cyprus",
    "Botsuana": "Botswana",
    "Belice": "Belize",
    "Tayikistán": "Tajikistan",
    "Laos": "Lao PDR",
    "Eslovenia": "Slovenia",
    "Surinam": "Suriname",
    "Sudán del Sur": "S. Sudan",
    "Suazilandia": "Swaziland",
    "Omán": "Oman",
    "Guinea Ecuatorial": "Eq. Guinea",
    "Bután": "Bhutan",
    "Sáhara Occidental": "W. Sahara",
    "República de Gambia": "Gambia",
    "Baréin": "Bahrain",
}

# 世界地图可用名称集合，用于校验映射目标是否存在，加载时校验一次并缓存
_map_names = None


def _load_map_names():
    global _map_names
    if _map_names is None:
        path = os.path.join(settings.BASE_DIR, "static", "vendor", "world.json")
        with open(path, encoding="utf-8") as fh:
            geo = json.load(fh)
        _map_names = {
            feature["properties"].get("name")
            for feature in geo["features"]
            if feature["properties"].get("name")
        }
    return _map_names


def to_map_name(country):
    """把订单表的国名转换成世界地图底图名，底图已有同名或无法对应时返回原值。"""
    names = _load_map_names()
    if country in names:
        return country
    return NAME_MAP.get(country, country)


def is_mapped(country):
    """判断该国名能否在世界地图上着色。"""
    return to_map_name(country) in _load_map_names()
