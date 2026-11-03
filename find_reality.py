# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同 ASN 大厂域名全自动测速优选工具 V12.0 (Auto-ASN Enterprise)
功能特性:
1. 自动获取 VPS 本机公网 IP 与所属 ASN/ISP
2. 动态匹配同 ASN 下官方权威大厂业务域名 (控制台/API/CDN/文档站)
3. 动态嗅探同机房 /24 网段反向 PTR 资产
4. 严格校验 TLS 1.3、ALPN(h2)、证书有效期，并高亮标记同 ASN 目标
5. 一键生成 Sing-box / Xray 完美偷跑配置
"""

import sys
import os
import ssl
import time
import json
import socket
import re
import urllib.request
import concurrent.futures
from datetime import datetime, timezone

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
BOLD = "\033[1m"
RESET = "\033[0m"

MAX_WORKERS = 48        # 测速并发线程数
SOCKET_TIMEOUT = 2.5    # 单次握手超时时间 (秒)

# ==================== 全球各大厂/云厂商 ASN 精准资产域名库 ====================
ENTERPRISE_ASN_MAP = {
    # Cloudflare
    13335: [
        "www.cloudflare.com", "dash.cloudflare.com", "developers.cloudflare.com",
        "community.cloudflare.com", "workers.dev", "pages.dev", "one.one.one.one",
        "cloudflare-dns.com", "warp.plus"
    ],
    209242: [
        "www.cloudflare.com", "dash.cloudflare.com", "workers.dev"
    ],
    # Amazon Web Services (AWS)
    16509: [
        "aws.amazon.com", "console.aws.amazon.com", "docs.aws.amazon.com",
        "amazon.com", "www.amazon.com", "developer.amazon.com",
        "primevideo.com", "music.amazon.com", "s3.amazonaws.com"
    ],
    14618: [
        "aws.amazon.com", "console.aws.amazon.com", "docs.aws.amazon.com", "amazon.com"
    ],
    # Google / Google Cloud
    15169: [
        "cloud.google.com", "developers.google.com", "dns.google",
        "workspace.google.com", "dl.google.com", "fonts.googleapis.com",
        "firebase.google.com", "admin.google.com", "domains.google.com"
    ],
    396982: [
        "cloud.google.com", "workspace.google.com", "dns.google"
    ],
    # Microsoft / Azure
    8075: [
        "azure.microsoft.com", "portal.azure.com", "learn.microsoft.com",
        "docs.microsoft.com", "www.microsoft.com", "login.microsoftonline.com",
        "devblogs.microsoft.com", "visualstudio.microsoft.com", "teams.microsoft.com"
    ],
    8068: [
        "azure.microsoft.com", "portal.azure.com", "www.microsoft.com"
    ],
    # Oracle Cloud
    31898: [
        "www.oracle.com", "cloud.oracle.com", "docs.oracle.com",
        "blogs.oracle.com", "developer.oracle.com", "support.oracle.com"
    ],
    # Hetzner
    24940: [
        "www.hetzner.com", "robot.hetzner.com", "accounts.hetzner.com",
        "docs.hetzner.com", "community.hetzner.com", "status.hetzner.com",
        "konsoleh.hetzner.com"
    ],
    213230: [
        "www.hetzner.com", "accounts.hetzner.com", "docs.hetzner.com"
    ],
    # OVHcloud
    16276: [
        "www.ovhcloud.com", "www.ovh.com", "docs.ovh.com",
        "help.ovhcloud.com", "api.ovh.com", "community.ovh.com"
    ],
    35540: [
        "www.ovhcloud.com", "help.ovhcloud.com", "docs.ovh.com"
    ],
    # DigitalOcean
    14061: [
        "www.digitalocean.com", "cloud.digitalocean.com", "docs.digitalocean.com",
        "community.digitalocean.com", "status.digitalocean.com"
    ],
    # Vultr / The Constant Company
    20473: [
        "www.vultr.com", "my.vultr.com", "docs.vultr.com", "status.vultr.com"
    ],
    # Linode / Akamai
    63949: [
        "www.linode.com", "cloud.linode.com", "login.linode.com", "docs.linode.com"
    ],
    20940: [
        "www.akamai.com", "techdocs.akamai.com", "community.akamai.com"
    ],
    # Alibaba Cloud
    45102: [
        "www.alibabacloud.com", "account.alibabacloud.com", "www.aliyun.com",
        "developer.aliyun.com", "help.aliyun.com"
    ],
    37963: [
        "www.aliyun.com", "developer.aliyun.com", "www.alibabacloud.com"
    ],
    # Tencent Cloud
    132203: [
        "intl.cloud.tencent.com", "cloud.tencent.com", "dnspod.cn", "dnspod.com"
    ],
    # Fastly
    54113: [
        "www.fastly.com", "docs.fastly.com", "developer.fastly.com"
    ],
    # Apple
    714: [
        "www.apple.com", "developer.apple.com", "support.apple.com", "music.apple.com"
    ]
}

# 全球通用高权重合法大站备选库 (当处于专有 IDC / 独立机房时智能补充)
FALLBACK_ENTERPRISE_DOMAINS = [
    "www.microsoft.com", "learn.microsoft.com", "aws.amazon.com", "cloud.google.com",
    "www.oracle.com", "www.cloudflare.com", "www.apple.com", "www.debian.org",
    "www.ubuntu.com", "www.kernel.org", "addons.mozilla.org", "developer.mozilla.org",
    "www.docker.com", "caddyserver.com", "www.nginx.com", "nodejs.org", "www.python.org"
]


def fetch_current_network_info():
    """多源高可用获取当前 VPS 的公网 IP、归属 ASN 和 ISP 组织"""
    endpoints = [
        ("http://ip-api.com/json/?fields=status,message,country,city,as,org,query", "ip-api"),
        ("https://api.ip.sb/geoip", "ip.sb")
    ]
    
    for url, source in endpoints:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (curl/8.0)"})
            with urllib.request.urlopen(req, timeout=4) as response:
                data = json.loads(response.read().decode('utf-8'))
                
                if source == "ip-api" and data.get("status") == "success":
                    as_raw = data.get("as", "")
                    match = re.search(r'AS(\d+)', as_raw)
                    asn_num = int(match.group(1)) if match else None
                    return {
                        "ip": data.get("query"),
                        "asn": asn_num,
                        "asn_name": as_raw,
                        "org": data.get("org", "Unknown Org"),
                        "country": data.get("country", "Unknown Country"),
                        "city": data.get("city", "Unknown City")
                    }
                elif source == "ip.sb":
                    asn_val = data.get("asn")
                    return {
                        "ip": data.get("ip"),
                        "asn": int(asn_val) if asn_val else None,
                        "asn_name": f"AS{asn_val} {data.get('asn_organization', '')}",
                        "org": data.get("asn_organization", "Unknown Org"),
                        "country": data.get("country", "Unknown Country"),
                        "city": data.get("city", "Unknown City")
                    }
        except Exception:
            continue
            
    return None


def get_ip_asn(ip):
    """利用轻量 DNS 查询某个 IP 归属的 ASN (基于 Team Cymru 权威 DNS 接口)"""
    try:
        octets = ip.split('.')
        if len(octets) != 4:
            return None
        rev_query = f"{octets[3]}.{octets[2]}.{octets[1]}.{octets[0]}.origin.asn.cymru.com"
        # 使用 socket 反解 TXT
        txt_records = socket.gethostbyaddr(rev_query)
        # TXT 格式: "16509 | 3.80.0.0/12 | US | arin | 2017-08-16"
        if txt_records and txt_records[0]:
            match = re.search(r'(\d+)', txt_records[0])
            if match:
                return int(match.group(1))
    except Exception:
        pass
    return None


def scan_subnet_ptr_domains(base_ip):
    """从 VPS 所在的物理同 /24 C段网段中，逆向反查邻近 IP 的 PTR 域名"""
    found_domains = set()
    try:
        octets = base_ip.split('.')
        if len(octets) != 4:
            return []
        prefix = f"{octets[0]}.{octets[1]}.{octets[2]}."
        
        # 探测本网段前后部分活跃 IP 的 PTR
        cur_last = int(octets[3])
        sample_ips = [f"{prefix}{cur_last}"]
        for offset in [1, -1, 2, -2, 5, 10, 20]:
            target_last = cur_last + offset
            if 1 <= target_last <= 254:
                sample_ips.append(f"{prefix}{target_last}")
                
        def query_ptr(ip):
            try:
                host, _, _ = socket.gethostbyaddr(ip)
                # 过滤无意义的纯 IP/反向指针域名，寻找标准顶级域名
                if host and not host.endswith(".in-addr.arpa"):
                    parts = host.split('.')
                    if len(parts) >= 2:
                        # 尝试组装出根域名和二级域名
                        candidate = ".".join(parts[-2:])
                        candidate_www = f"www.{candidate}"
                        return [host, candidate, candidate_www]
            except Exception:
                pass
            return []

        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            res_lists = executor.map(query_ptr, sample_ips)
            for r in res_lists:
                for d in r:
                    if len(d) > 3
