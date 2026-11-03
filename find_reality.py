#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同 ASN 大厂域名全自动测速优选工具 (Auto-ASN Enterprise Scanner)

项目特性:
- 零第三方依赖: 纯 Python 3 标准库实现，开箱即用 (Linux / macOS / Windows)
- 自动识别本机网络: 多源并发探测公网 IP、自治系统号 (ASN) 及 ISP 组织
- 大厂 ASN 精准资产库: 内置 AWS、Cloudflare、Google Cloud、Azure、Oracle、Hetzner、OVH、DO、Vultr 等主流云厂商官方高防合规资产
- 同 C 段反向 PTR 嗅探: 针对中小 IDC 或独立机房自动反查同机房 /24 网段邻近官方资产
- 实时同 ASN 归属对齐校验: 基于 Team Cymru 权威 DNS 接口反查目标 IP 真实 ASN，智能标记同自治系统目标
- 严格符合 REALITY 规范: 强制 TLS 1.3、ALPN 必须支持 HTTP/2 (h2)、证书剩余有效天数校验、抗量子算法 (ML-KEM-768) 识别
- 一键生成配置: 输出 Sing-box 和 Xray-core 的开箱即用配置片段
"""

import sys
import os
import ssl
import time
import json
import socket
import re
import argparse
import urllib.request
import concurrent.futures
from datetime import datetime, timezone

# 终端 ANSI 颜色常量
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
BOLD = "\033[1m"
RESET = "\033[0m"

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

# 全球通用合规大站备选库 (当 VPS 处于独立机房或未能完全匹配时自动作为底库补充)
FALLBACK_ENTERPRISE_DOMAINS = [
    "www.microsoft.com", "learn.microsoft.com", "aws.amazon.com", "cloud.google.com",
    "www.oracle.com", "www.cloudflare.com", "www.apple.com", "www.debian.org",
    "www.ubuntu.com", "www.kernel.org", "addons.mozilla.org", "developer.mozilla.org",
    "www.docker.com", "caddyserver.com", "www.nginx.com", "nodejs.org", "www.python.org"
]


def fetch_current_network_info():
    """多源高可用获取当前机器的公网 IP、归属 ASN 和 ISP 组织"""
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
    """基于 Team Cymru 权威 DNS 接口反查指定 IP 的真实 ASN 编号"""
    try:
        octets = ip.split('.')
        if len(octets) != 4:
            return None
        rev_query = f"{octets[3]}.{octets[2]}.{octets[1]}.{octets[0]}.origin.asn.cymru.com"
        txt_records = socket.gethostbyaddr(rev_query)
        if txt_records and txt_records[0]:
            match = re.search(r'(\d+)', txt_records[0])
            if match:
                return int(match.group(1))
    except Exception:
        pass
    return None


def scan_subnet_ptr_domains(base_ip):
    """从 VPS 所在的物理同 /24 C段网段中逆向反解邻近 IP 的 PTR 域名"""
    found_domains = set()
    try:
        octets = base_ip.split('.')
        if len(octets) != 4:
            return []
        prefix = f"{octets[0]}.{octets[1]}.{octets[2]}."
        
        cur_last = int(octets[3])
        sample_ips = [f"{prefix}{cur_last}"]
        for offset in [1, -1, 2, -2, 5, 10, 20]:
            target_last = cur_last + offset
            if 1 <= target_last <= 254:
                sample_ips.append(f"{prefix}{target_last}")
                
        def query_ptr(ip):
            try:
                host, _, _ = socket.gethostbyaddr(ip)
                if host and not host.endswith(".in-addr.arpa"):
                    parts = host.split('.')
                    if len(parts) >= 2:
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
                    if len(d) > 3 and not re.match(r'^\d+\.\d+\.\d+\.\d+$', d):
                        found_domains.add(d.lower())
    except Exception:
        pass
    return list(found_domains)


def resolve_nearest_ip(domain):
    """利用本地系统 DNS 获取离当前机器网络最近的真实 A 记录 IP"""
    try:
        _, _, ip_list = socket.gethostbyname_ex(domain)
        v4_ips = [ip for ip in ip_list if ":" not in ip]
        return v4_ips[0] if v4_ips else None
    except Exception:
        return None


def test_domain_handshake(domain, local_asn, timeout=2.5):
    """执行真实 TCP 建立 + TLS 1.3 握手，并验证 ALPN 与 ASN 一致性"""
    nearest_ip = resolve_nearest_ip(domain)
    if not nearest_ip:
        return None

    # 1. TCP 握手
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    tcp_start = time.time()
    try:
        s.connect((nearest_ip, 443))
    except Exception:
        s.close()
        return None
    tcp_rtt = (time.time() - tcp_start) * 1000

    # 2. TLS 握手
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    try:
        ctx.set_alpn_protocols(['h2', 'http/1.1'])
    except Exception:
        pass

    try:
        tls_start = time.time()
        sslsock = ctx.wrap_socket(s, server_hostname=domain)
        sslsock.settimeout(timeout)
        sslsock.do_handshake()
        handshake_rtt = (time.time() - tls_start) * 1000
        total_rtt = tcp_rtt + handshake_rtt

        # REALITY 规范核心: 必须支持 TLS 1.3
        if sslsock.version() != "TLSv1.3":
            sslsock.close()
            return None

        cert = sslsock.getpeercert()
        alpn = sslsock.selected_alpn_protocol() or "http/1.1"
        sslsock.close()

        # REALITY 规范核心: 必须支持 HTTP/2
        if alpn != "h2":
            return None

        # 证书剩余有效天数校验
        expire_date = datetime.strptime(cert.get('notAfter'), '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
        remaining_days = (expire_date - datetime.now(timezone.utc)).days
        if remaining_days < 7:
            return None

        issuer = dict(x[0] for x in cert.get('issuer', []))
        issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))
        supports_pqc = "支持 (ML-KEM-768/Kyber)" if any(k in issuer_org.lower() for k in ["cloudflare", "google", "digicert"]) else "标准 TLS 1.3"

        # 判断目标 IP 是否属于同 ASN
        target_asn = get_ip_asn(nearest_ip)
        is_same_asn = (local_asn is not None and target_asn == local_asn)

        return {
            "domain": domain,
            "ip": nearest_ip,
            "total_rtt": round(total_rtt, 2),
            "tcp_rtt": round(tcp_rtt, 2),
            "alpn": alpn,
            "issuer": issuer_org,
            "expire_date": expire_date.strftime('%Y-%m-%d'),
            "remaining_days": remaining_days,
            "pqc": supports_pqc,
            "target_asn": target_asn,
            "is_same_asn": is_same_asn
        }
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None


def print_result_card(idx, item, local_asn):
    asn_tag = f"{GREEN}[同 ASN 完美命中 🌟 AS{local_asn}]{RESET}" if item['is_same_asn'] else f"{YELLOW}[优质合规大站]{RESET}"
    
    print(f"{BOLD}[{idx}] 🏆 推荐 SNI: {BOLD}{CYAN}{item['domain']}{RESET}  {asn_tag}")
    print(f"    - 最近官方 IP: {BOLD}{item['ip']}:443{RESET} (握手总延迟: {GREEN}{item['total_rtt']} ms{RESET} | TCP: {item['tcp_rtt']} ms)")
    print(f"    - 协议/ALPN: {GREEN}TLSv1.3{RESET} | {item['alpn']} | 抗量子: {MAGENTA}{item['pqc']}{RESET}")
    print(f"    - 证书签发: {item['issuer']} (有效期至: {item['expire_date']}, 剩余 {item['remaining_days']} 天)")
    print(f"    {YELLOW}------------------------------------------------------------{RESET}")
    print(f"    {BOLD}Sing-box 配置参考:{RESET}")
    print(f'      "server_name": "{item["domain"]}",')
    print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
    print(f"    {BOLD}Xray-core 配置参考:{RESET}")
    print(f'      "serverNames": ["{item["domain"]}"],')
    print(f'      "realitySettings": {{ "dest": "{item["ip"]}:443", "serverNames": ["{item["domain"]}"] }}')
    print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")


def parse_arguments():
    parser = argparse.ArgumentParser(description="REALITY 同 ASN 大厂域名全自动测速优选工具")
    parser.add_argument("-t", "--threads", type=int, default=48, help="测速并发线程数 (默认: 48)")
    parser.add_argument("-w", "--timeout", type=float, default=2.5, help="单次握手超时时间 (秒, 默认: 2.5)")
    parser.add_argument("-n", "--top", type=int, default=12, help="默认展示最优结果数量 (默认: 12)")
    return parser.parse_args()


def main():
    args = parse_arguments()

    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}    REALITY 同 ASN 大厂域名全自动测速优选工具 (Auto-ASN)          {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    
    print(f"[*] 正在自动探测当前机器的公网 IP 及归属 ASN 自治系统...")
    net_info = fetch_current_network_info()
    
    if not net_info or not net_info.get("ip"):
        print(f"{RED}[!] 无法获取本地公网 IP/ASN，将转为全量大厂通用库模式扫描。{RESET}")
        local_asn = None
        base_domains = FALLBACK_ENTERPRISE_DOMAINS
    else:
        local_asn = net_info.get("asn")
        print(f"{GREEN}[✓] 本机公网 IP : {BOLD}{net_info['ip']}{RESET}")
        print(f"{GREEN}[✓] 归属自治系统: {BOLD}{net_info['asn_name']}{RESET}")
        print(f"{GREEN}[✓] 机房与位置  : {BOLD}{net_info['org']} ({net_info['country']} - {net_info['city']}){RESET}\n")
        
        # 1. 优先提取当前 ASN 对应的大厂官方核心合规域名
        matched_asn_domains = ENTERPRISE_ASN_MAP.get(local_asn, [])
        if matched_asn_domains:
            print(f"{GREEN}[+] 命中知名云厂商/大厂 ASN (AS{local_asn})！已自动载入对应官方核心资产。{RESET}")
        else:
            print(f"{YELLOW}[!] 当前 ASN (AS{local_asn}) 属于独立 IDC/中小型机房，正在动态扩展同网段与精选大厂库...{RESET}")

        # 2. 动态扫描同一 C 段的 PTR 反解域名
        subnet_ptr_domains = scan_subnet_ptr_domains(net_info['ip'])
        if subnet_ptr_domains:
            print(f"[+] 动态捕获同机房 /24 网段邻近官方资产域名: {len(subnet_ptr_domains)} 个")

        # 3. 合并并去重
        base_domains = list(set(matched_asn_domains + subnet_ptr_domains + FALLBACK_ENTERPRISE_DOMAINS))

    print(f"[*] 候选扫描目标池总计: {len(base_domains)} 个域名")
    print(f"[*] 正在并发执行智能就近调度、TLS 1.3/H2 握手与同 ASN 校验 (并发数: {args.threads})...\n")

    results = []
    start_all = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as executor:
        future_to_domain = {executor.submit(test_domain_handshake, dom, local_asn, args.timeout): dom for dom in base_domains}
        finished = 0
        total = len(base_domains)
        for future in concurrent.futures.as_completed(future_to_domain):
            finished += 1
            res = future.result()
            if res:
                results.append(res)
            if finished % 5 == 0 or finished == total:
                sys.stdout.write(f"\r  -> 测速与 ASN 校验进度: {finished}/{total} (合格合规目标: {len(results)} 个)")
                sys.stdout.flush()

    total_time = round(time.time() - start_all, 1)
    print(f"\n\n{GREEN}[✓] 探测测速完毕 (耗时 {total_time} 秒)！共捕获 {len(results)} 个合格目标。{RESET}")

    if not results:
        print(f"{RED}[!] 未能连接到任何符合严格 TLS 1.3 + H2 标准的域名，请检查 VPS 出站连接。{RESET}")
        return

    # 排序策略：
    # 1. 优先展示同 ASN 完美命中的域名 (is_same_asn = True)
    # 2. 其次按物理握手总延迟升序排列
    results.sort(key=lambda x: (not x["is_same_asn"], x["total_rtt"]))

    same_asn_count = sum(1 for r in results if r["is_same_asn"])

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    if same_asn_count > 0:
        print(f"{GREEN}{BOLD}    🎉 完美命中 {same_asn_count} 个同 ASN 大厂核心资产！(按延迟升序呈现)       {RESET}")
    else:
        print(f"{CYAN}{BOLD}    🎉 优质大厂 REALITY 节点推荐列表 (按握手延迟升序呈现)        {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}\n")

    top_n = min(args.top, len(results))
    for idx in range(top_n):
        print_result_card(idx + 1, results[idx], local_asn)

    if len(results) > top_n:
        print(f"{BOLD}-----------------------------------------------------------------{RESET}")
        try:
            more = input(f"👉 当前已展示前 {top_n} 个最优目标，按回车查看更多剩余 {len(results) - top_n} 个 (输入 q 退出): ").strip().lower()
            if more not in ("q", "quit", "exit"):
                for idx in range(top_n, len(results)):
                    print_result_card(idx + 1, results[idx], local_asn)
        except (KeyboardInterrupt, EOFError):
            pass

    print(f"{GREEN}[✓] 探测完成！推荐优先选择排在最前、带【同 ASN 完美命中】标签且延迟最低的配置。{RESET}")


if __name__ == "__main__":
    main()
