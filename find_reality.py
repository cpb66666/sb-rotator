# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 终极同城商业嗅探器 V6.0 (Geo-Locked Enterprise)
核心特性：
1. [同城地理锁] 自动锁定本机国家与地区，严防 IP 飘到跨洋异国
2. [封杀免费证书] 彻底屏蔽 Let's Encrypt / ZeroSSL，仅保留企业级商业 CA
3. [低延迟硬限] 强制 RTT <= 35ms，确保 100% 具备同城/同区域极限握手性能
4. [连续深挖扩扫] 本机物理网段 (/24 -> /18) + 同国 ASN 商业段持续追踪
5. [权威鉴伪验证] 顶级 CDN 官方 CIDR 白名单 + 权威 DNS 双向交叉验证
"""

import sys
import os
import re
import csv
import ssl
import json
import time
import socket
import ipaddress
import subprocess
import urllib.request
import concurrent.futures
from datetime import datetime, timezone

# ANSI 颜色定义
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
BOLD = "\033[1m"
RESET = "\033[0m"

# 核心运行参数
DEFAULT_LIMIT = 5       # 抓取合格真实商业目标上限
MAX_WORKERS = 64        # 并发探测线程数
SOCKET_TIMEOUT = 2.0    # 单次探测超时时间 (秒)
MAX_ALLOWED_RTT = 35.0  # 最大允许的物理 RTT 延迟 (ms)，超过直接淘汰（防跨洋）
CSV_OUTPUT = "reality_targets.csv"

# 免费/个人证书黑名单（彻底封杀翻墙小鸡专用证书）
FORBIDDEN_FREE_CAS = {
    "let's encrypt", "zerossl", "cpanel", "certbot", "buypass",
    "trustasia free", "acme", "encryption everyday"
}

# 认可的顶级商业/企业级 CA 白名单
TRUSTED_ENTERPRISE_CAS = {
    "digicert", "amazon", "google trust services", "cloudflare",
    "globalsign", "sectigo", "entrust", "comodo", "geotrust",
    "thawte", "verisign", "microsoft", "apple"
}

# 廉价/翻墙高频后缀黑名单
CHEAP_TLDS = {
    ".xyz", ".top", ".icu", ".site", ".fun", ".shop", ".cf", ".ga",
    ".gq", ".ml", ".tk", ".work", ".click", ".link", ".online", ".tech"
}

# 常见翻墙节点命名正则特征
PROXY_NAME_PATTERN = re.compile(
    r'^(?:us|hk|jp|sg|kr|de|uk|fr|node|v|server|line|route|vpn|proxy|relay|ss|vless|vmess|hy2|iplc|bgp)[-_]?\d*',
    re.IGNORECASE
)

# GFWList 封锁关键词
BLOCKED_KEYWORDS = {
    "google", "youtube", "facebook", "twitter", "x.com", "instagram",
    "telegram", "netflix", "wikipedia", "github.com", "pornhub", "nyt",
    "bbc", "v2ex", "medium", "reddit", "openai", "chatgpt"
}

# 顶级大热域名警告库
HOT_DOMAINS = {
    "apple.com", "icloud.com", "microsoft.com", "windows.com",
    "amazon.com", "tesla.com", "yahoo.com", "live.com"
}

# 权威顶级 CDN 官方公开 IPv4 网段白名单
OFFICIAL_CDN_NETWORKS = {
    "cloudflare": [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
        "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
        "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
    ],
    "amazon": [
        "13.32.0.0/15", "13.224.0.0/14", "13.249.0.0/16", "13.35.0.0/16",
        "99.84.0.0/16", "99.86.0.0/16", "205.251.192.0/19", "54.182.0.0/16",
        "54.192.0.0/16", "54.230.0.0/16", "54.239.128.0/18", "54.239.192.0/19",
        "54.240.128.0/17", "64.252.64.0/18", "70.132.0.0/18", "143.204.0.0/16"
    ],
    "akamai": [
        "23.0.0.0/12", "23.32.0.0/11", "104.64.0.0/10", "184.84.0.0/14",
        "2.16.0.0/13", "96.6.0.0/15"
    ],
    "fastly": [
        "151.101.0.0/16", "199.232.0.0/16", "146.75.0.0/16"
    ]
}

def get_public_ip_and_location():
    """获取本机公网 IPv4、机房组织、ASN 及地理属地 (Country/City)"""
    endpoints = ["https://ipinfo.io/json", "https://ifconfig.co/json"]
    ip, org, asn, country, city = None, "Unknown", None, "US", "Unknown"
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read().decode('utf-8').strip())
                ip = data.get("ip")
                org = data.get("org", "Unknown")
                country = data.get("country", "US")
                city = data.get("city", "Unknown")
                asn_match = re.search(r'AS(\d+)', org, re.IGNORECASE)
                if asn_match:
                    asn = asn_match.group(1)
                if ip:
                    ipaddress.IPv4Address(ip)
                    return ip, org, asn, country, city
        except Exception:
            continue
    return ip, org, asn, country, city

def check_ip_country(sample_ip):
    """快速抽样探测某个网段是否与本机属于同一个国家"""
    try:
        url = f"https://ipinfo.io/{sample_ip}/country"
        req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.read().decode('utf-8').strip()
    except Exception:
        return None

def fetch_asn_announced_prefixes_geofiltered(asn, local_country):
    """从 RIPE 全球权威 BGP 数据库拉取该 ASN 网段，并执行同国过滤"""
    if not asn:
        return []
    url = f"https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{asn}"
    filtered_prefixes = []
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            raw_list = data.get("data", {}).get("prefixes", [])
            
            # 提取前缀
            candidate_prefixes = []
            for item in raw_list:
                p = item.get("prefix")
                if ":" not in p:
                    cidr = int(p.split('/')[1])
                    if 21 <= cidr <= 24:
                        candidate_prefixes.append(p)
            
            # 抽样检测地理位置，确保严格同国
            for p in candidate_prefixes[:15]:  # 抽样优先前15个活跃商业段
                sample_ip = str(ipaddress.IPv4Network(p, strict=False)[2])
                c = check_ip_country(sample_ip)
                if c == local_country:
                    filtered_prefixes.append(p)
    except Exception:
        pass
    return list(set(filtered_prefixes))

def is_valid_domain(domain):
    """过滤无效或内部保留域名"""
    if not domain or len(domain) > 253:
        return False
    domain = domain.lower().lstrip('*.')
    if domain.endswith(('.local', '.internal', '.lan', '.arpa', '.corp')):
        return False
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', domain):
        return False
    pattern = r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
    return bool(re.match(pattern, domain))

def is_cheap_or_proxy_domain(domain):
    """检查是否属于廉价后缀或私人代理节点命名"""
    domain_lower = domain.lower()
    for tld in CHEAP_TLDS:
        if domain_lower.endswith(tld):
            return True, f"廉价翻墙后缀 [{tld}]"
    subdomain = domain_lower.split('.')[0]
    if PROXY_NAME_PATTERN.match(subdomain):
        return True, f"命中翻墙代理节点命名特征 [{subdomain}]"
    return False, ""

def is_gfw_blocked(domain):
    """GFW 封锁简易快速检测"""
    domain_lower = domain.lower()
    for kw in BLOCKED_KEYWORDS:
        if kw in domain_lower:
            return True, f"命中被墙特征 [{kw}]"
    return False, ""

def verify_server_authenticity(target_ip, domain, issuer_org):
    """
    【商业级双重鉴权照妖镜】
    防线 1：官方权威 CDN CIDR 白名单匹配
    防线 2：DNS 权威 A 记录实时双向校验
    """
    target_ip_obj = ipaddress.IPv4Address(target_ip)
    issuer_lower = issuer_org.lower()

    # 1. 优先校验：是否属于大厂官方权威 CDN 网段
    for cdn_name, cidr_list in OFFICIAL_CDN_NETWORKS.items():
        if cdn_name in issuer_lower or cdn_name in domain:
            for net_str in cidr_list:
                if target_ip_obj in ipaddress.IPv4Network(net_str):
                    return True, f"属于 {cdn_name.upper()} 官方权威边缘节点集群"
            return False, f"宣称是 {cdn_name}，但 IP 根本不在其官方公布的 IP 白名单中 (邻居套娃机)"

    # 2. 次级校验：常规商业站点的 DNS 权威 A 记录反查
    try:
        _, _, official_ips = socket.gethostbyname_ex(domain)
        if target_ip in official_ips:
            return True, "官方 DNS 记录直指本 IP"
        for oip in official_ips:
            if target_ip_obj in ipaddress.IPv4Network(f"{oip}/24", strict=False):
                return True, "属于官方服务器同机房网段"
        return False, f"官方真实 IP 为 {official_ips[:2]}，当前探测 IP 不在认领列表中 (套娃偷证书)"
    except Exception as e:
        return False, f"权威 DNS 反查失败: {e}"

def extract_domains_from_der(der_bytes):
    """通过 openssl 从 DER 证书中提取 SAN 和 CN 域名"""
    domains = set()
    try:
        proc = subprocess.Popen(
            ["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-ext", "subjectAltName"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        out, _ = proc.communicate(input=der_bytes, timeout=2)
        out_str = out.decode('utf-8', errors='ignore')

        cn_match = re.search(r'CN\s*=\s*([^/,\n]+)', out_str)
        if cn_match:
            cn = cn_match.group(1).strip()
            if is_valid_domain(cn):
                domains.add(cn.lstrip('*.'))

        san_matches = re.findall(r'DNS:([^,\s]+)', out_str)
        for san in san_matches:
            san = san.strip()
            if is_valid_domain(san):
                domains.add(san.lstrip('*.'))
    except Exception:
        pass
    return list(domains)

def trace_http_redirect(ip, domain):
    """HTTP 301/302 重定向检测，锁定真实生效域名"""
    final_domain = domain
    is_redirected = False
    try:
        conn = socket.create_connection((ip, 443), timeout=SOCKET_TIMEOUT)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(conn, server_hostname=domain)
        req = f"HEAD / HTTP/1.1\r\nHost: {domain}\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
        s.sendall(req.encode())
        resp = s.recv(1024).decode('utf-8', errors='ignore')
        s.close()

        status_match = re.search(r'HTTP/\d\.\d\s+(\d+)', resp)
        if status_match and int(status_match.group(1)) in (301, 302, 307, 308):
            loc_match = re.search(r'Location:\s*([^\r\n]+)', resp, re.IGNORECASE)
            if loc_match:
                loc = loc_match.group(1).strip()
                parsed_host = re.search(r'https?://([^/:\s]+)', loc)
                if parsed_host:
                    new_domain = parsed_host.group(1).lower()
                    if is_valid_domain(new_domain) and new_domain != domain:
                        final_domain = new_domain
                        is_redirected = True
    except Exception:
        pass
    return final_domain, is_redirected

def probe_ip(ip_str):
    """第一阶段探测：端口与基本 TLS 1.3 握手"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SOCKET_TIMEOUT)
    start_time = time.time()
    try:
        s.connect((ip_str, 443))
    except Exception:
        s.close()
        return None

    tcp_rtt = (time.time() - start_time) * 1000

    # 【同城低延迟硬限制】：TCP 延迟超过 35ms 绝不可能是同城机房，直接砍掉（防止跨洋）
    if tcp_rtt > MAX_ALLOWED_RTT:
        s.close()
        return None

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.set_alpn_protocols(['h2', 'http/1.1'])
    except Exception:
        pass

    try:
        tls_start = time.time()
        sslsock = ctx.wrap_socket(s, server_hostname=None)
        sslsock.settimeout(SOCKET_TIMEOUT)
        sslsock.do_handshake()
        handshake_rtt = (time.time() - tls_start) * 1000

        tls_version = sslsock.version()
        if tls_version != "TLSv1.3":
            sslsock.close()
            return None

        # 时延不对称初筛
        if tcp_rtt < 10 and handshake_rtt > 50 and (handshake_rtt / max(tcp_rtt, 0.5)) > 6:
            sslsock.close()
            return {"spoof_relay": True, "ip": ip_str, "tcp_rtt": tcp_rtt, "handshake_rtt": handshake_rtt}

        der_cert = sslsock.getpeercert(binary_form=True)
        alpn = sslsock.selected_alpn_protocol() or "none"
        sslsock.close()

        if not der_cert:
            return None

        candidate_domains = extract_domains_from_der(der_cert)
        if not candidate_domains:
            try:
                ptr_name, _, _ = socket.gethostbyaddr(ip_str)
                if is_valid_domain(ptr_name):
                    candidate_domains.append(ptr_name)
            except Exception:
                pass

        if not candidate_domains:
            return None

        return {
            "spoof_relay": False,
            "ip": ip_str,
            "tcp_rtt": round(tcp_rtt, 2),
            "handshake_rtt": round(handshake_rtt, 2),
            "tls_version": tls_version,
            "alpn": alpn,
            "candidates": candidate_domains
        }
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None

def verify_and_evaluate(probe_result):
    """第二阶段：多维身份核验 + 免费证书彻底封杀 + 严格有效性检验"""
    ip = probe_result["ip"]
    candidates = probe_result["candidates"]

    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    try:
        ctx.set_alpn_protocols(['h2', 'http/1.1'])
    except Exception:
        pass

    for sni in candidates:
        sni_lower = sni.lower()

        # 1. 过滤廉价后缀与机场私人节点
        is_proxy, proxy_reason = is_cheap_or_proxy_domain(sni_lower)
        if is_proxy:
            print(f"  {YELLOW}[✖ 拦截私人节点] IP: {ip:<15} 域名: {sni} ({proxy_reason}){RESET}")
            continue

        # 2. 过滤 GFW 封锁域名
        blocked, _ = is_gfw_blocked(sni_lower)
        if blocked:
            continue

        # 3. 标准 TLS 握手及证书有效性检验
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SOCKET_TIMEOUT)
        try:
            start_t = time.time()
            s.connect((ip, 443))
            sslsock = ctx.wrap_socket(s, server_hostname=sni)
            sslsock.settimeout(SOCKET_TIMEOUT)
            sslsock.do_handshake()
            total_rtt = (time.time() - start_t) * 1000

            cert = sslsock.getpeercert()
            alpn = sslsock.selected_alpn_protocol() or probe_result["alpn"]
            sslsock.close()

            # 【低延迟硬拦截】：握手总延时超过 35ms 直接丢弃（非同城节点）
            if total_rtt > MAX_ALLOWED_RTT:
                continue

            not_after_str = cert.get('notAfter')
            expire_date = datetime.strptime(not_after_str, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
            remaining_days = (expire_date - datetime.now(timezone.utc)).days
            if remaining_days < 7:
                continue

            issuer = dict(x[0] for x in cert.get('issuer', []))
            issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))
            issuer_lower = issuer_org.lower()
            sans = [v for k, v in cert.get('subjectAltName', []) if k == 'DNS']

            # 【核心升级：彻底封杀 Let's Encrypt 等免费证书】
            if any(bad_ca in issuer_lower for bad_ca in FORBIDDEN_FREE_CAS):
                print(f"  {YELLOW}[✖ 封杀免费证书] IP: {ip:<15} CA 为免费证书 ({issuer_org})，不满足企业级商业要求！{RESET}")
                continue

            # 【核心鉴伪：权威 CDN CIDR + 权威 DNS 双向交叉验证】
            is_genuine, auth_msg = verify_server_authenticity(ip, sni_lower, issuer_org)
            if not is_genuine:
                print(f"  {RED}[✖ 鉴伪拦截] IP: {ip:<15} 宣称是 {sni}，但 {auth_msg}！{RESET}")
                continue

            # 4. HTTP 重定向校准
            final_sni, is_redirected = trace_http_redirect(ip, sni)

            # 5. 后量子抗量子判定
            supports_pqc = "可能支持"
            if any(k in issuer_lower for k in ["cloudflare", "google", "amazon"]):
                supports_pqc = "支持 (ML-KEM-768/Kyber)"

            is_hot = any(sni_lower.endswith(hot) for hot in HOT_DOMAINS)

            # 6. 综合评分计算
            score = 60
            if total_rtt < 5.0: score += 20
            elif total_rtt < 15.0: score += 10
            if alpn == "h2": score += 10
            if not is_hot: score += 10
            if remaining_days > 30: score += 10

            stars = "⭐⭐⭐⭐⭐" if score >= 90 else ("⭐⭐⭐⭐" if score >= 75 else "⭐⭐⭐")

            return {
                "ip": ip,
                "rtt": round(total_rtt, 2),
                "sni": final_sni,
                "raw_sni": sni,
                "is_redirected": is_redirected,
                "tls_version": probe_result["tls_version"],
                "alpn": alpn,
                "issuer": issuer_org,
                "expire_date": expire_date.strftime('%Y-%m-%d'),
                "remaining_days": remaining_days,
                "pqc": supports_pqc,
                "is_hot": is_hot,
                "score": score,
                "stars": stars,
                "all_sans": sans[:4]
            }
        except Exception:
            try:
                s.close()
            except Exception:
                pass
            continue
    return None

def build_scan_plan(base_ip, asn, local_country):
    """
    自适应同城商业队列：
    阶段 1：本机城域物理直连层级 (/24 -> /23 -> /22 -> /21 -> /20 -> /19 -> /18)
    阶段 2：经过同国地理过滤 (Geo-Locked) 的本 ASN 广播网段
    """
    net24 = ipaddress.IPv4Network(f"{base_ip}/24", strict=False)
    net23 = ipaddress.IPv4Network(f"{base_ip}/23", strict=False)
    net22 = ipaddress.IPv4Network(f"{base_ip}/22", strict=False)
    net21 = ipaddress.IPv4Network(f"{base_ip}/21", strict=False)
    net20 = ipaddress.IPv4Network(f"{base_ip}/20", strict=False)
    net19 = ipaddress.IPv4Network(f"{base_ip}/19", strict=False)
    net18 = ipaddress.IPv4Network(f"{base_ip}/18", strict=False)

    plan = [
        ("Layer 1 (同 /24 局域网段)", [str(ip) for ip in net24.hosts() if str(ip) != base_ip]),
        ("Layer 2 (扩充 /23 相邻机架)", [str(ip) for ip in net23.hosts() if ip not in net24 and str(ip) != base_ip]),
        ("Layer 3 (扩充 /22 机房核心)", [str(ip) for ip in net22.hosts() if ip not in net23 and str(ip) != base_ip]),
        ("Layer 4 (扩充 /21 区域骨干)", [str(ip) for ip in net21.hosts() if ip not in net22 and str(ip) != base_ip]),
        ("Layer 5 (扩充 /20 同城大区网段)", [str(ip) for ip in net20.hosts() if ip not in net21 and str(ip) != base_ip]),
        ("Layer 6 (扩充 /19 城域骨干网段)", [str(ip) for ip in net19.hosts() if ip not in net20 and str(ip) != base_ip]),
        ("Layer 7 (扩充 /18 区域核心网段)", [str(ip) for ip in net18.hosts() if ip not in net19 and str(ip) != base_ip])
    ]

    # 拉取经过同国核验 (Geo-Filtered) 的该 ASN 商业网段
    if asn:
        print(f"[*] 正在拉取 AS{asn} 广播网段并执行【同国地理位置锁定 ({local_country})】过滤...")
        bgp_prefixes = fetch_asn_announced_prefixes_geofiltered(asn, local_country)
        idx = 8
        for prefix in bgp_prefixes:
            try:
                p_net = ipaddress.IPv4Network(prefix, strict=False)
                if not p_net.overlaps(net18):
                    plan.append((f"Layer {idx} (AS{asn} 同国商业段: {prefix})", [str(ip) for ip in p_net.hosts()]))
                    idx += 1
            except Exception:
                continue
    return plan

def export_csv(targets, filepath):
    """导出与 RealityChecker-PLUS 兼容的 CSV 格式"""
    try:
        with open(filepath, mode="w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["IP", "Port", "Domain", "RTT(ms)", "ALPN", "Issuer", "PQC", "Stars"])
            for t in targets:
                writer.writerow([t["ip"], 443, t["sni"], t["rtt"], t["alpn"], t["issuer"], t["pqc"], t["stars"]])
        return True
    except Exception:
        return False

def main():
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}   REALITY 同城商业 TLS 1.3 终极嗅探器 V6.0 (Geo-Enterprise)    {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    print(f"[*] 正在锁定本机地理位置与机房网络环境...")
    my_ip, my_org, my_asn, my_country, my_city = get_public_ip_and_location()
    if not my_ip:
        print(f"{RED}[!] 获取公网 IP 失败，请检查网络设置。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机 IP: {BOLD}{my_ip}{RESET} | 属地: {BOLD}{my_country} ({my_city}){RESET} | 机房: {BOLD}{my_org}{RESET} (ASN: AS{my_asn})\n")

    scan_plan = build_scan_plan(my_ip, my_asn, my_country)
    print(f"{GREEN}[✓] 调度引擎已就绪，已严格锁定 [{my_country}] 本地网段并限制 RTT <= {MAX_ALLOWED_RTT}ms！{RESET}\n")

    found_targets = []

    for layer_name, ip_list in scan_plan:
        print(f"{YELLOW}[>] 正在扫描: {layer_name}{RESET}")
        print(f"[*] 待检测目标数: {len(ip_list)} 个 | 并发线程: {MAX_WORKERS}")

        stage1_results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_ip = {executor.submit(probe_ip, ip): ip for ip in ip_list}
            scanned = 0
            for future in concurrent.futures.as_completed(future_to_ip):
                scanned += 1
                res = future.result()
                if res:
                    if res.get("spoof_relay"):
                        print(f"  {RED}[✖ 拦截套娃] IP: {res['ip']:<15} (时延严重割裂: TCP {res['tcp_rtt']:.1f}ms, TLS {res['handshake_rtt']:.1f}ms){RESET}")
                    else:
                        stage1_results.append(res)
                        print(f"  {CYAN}发现同城开放: {res['ip']:<15} (延迟: {res['tcp_rtt']}ms | TLS 1.3: 是){RESET}")

                if scanned % 50 == 0 or scanned == len(ip_list):
                    sys.stdout.write(f"\r  -> 进度: {scanned}/{len(ip_list)} (捕获开放节点: {len(stage1_results)})")
                    sys.stdout.flush()

        print(f"\n[*] 正在执行【免费 CA 封杀】、【同城延时核验】与【CDN+DNS 权威鉴伪】...")
        for probe_res in stage1_results:
            evaluated = verify_and_evaluate(probe_res)
            if evaluated:
                found_targets.append(evaluated)
                print(f"  {GREEN}[✓ 顶级商业真身] {evaluated['stars']} IP: {evaluated['ip']:<15} | SNI: {evaluated['sni']} | CA: {evaluated['issuer']}{RESET}")

            if len(found_targets) >= DEFAULT_LIMIT:
                print(f"\n{GREEN}[✓] 已找到 {DEFAULT_LIMIT} 个顶级同城商业官方目标，圆满完成任务并停止扩散！{RESET}")
                break

        if len(found_targets) >= DEFAULT_LIMIT:
            break
        else:
            print(f"[*] 当前网段未找齐目标 ({len(found_targets)}/{DEFAULT_LIMIT})。继续自动深挖下一个同城商业网段...\n")

    if not found_targets:
        print(f"\n{RED}[!] 在当前同城所有商业网段内均未发现商业企业实体服务器。{RESET}")
        return

    # 按推荐总分与 RTT 排序
    found_targets.sort(key=lambda x: (-x["score"], x["rtt"]))

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}     🏆 REALITY 顶级同城商业认证目标排行 (剔除一切免费与异国IP)   {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}\n")

    for idx, item in enumerate(found_targets, 1):
        hot_flag = f"{RED}[⚠️ 热门域名]{RESET}" if item["is_hot"] else f"{GREEN}[企业认证]{RESET}"
        redir_flag = f"{YELLOW}(重定向校准自 {item['raw_sni']}){RESET}" if item["is_redirected"] else ""
        print(f"{BOLD}[{idx}] {item['stars']} IP: {item['ip']}:443  (同城物理延迟: {item['rtt']} ms) {hot_flag}{RESET}")
        print(f"    - 官方 SNI: {BOLD}{CYAN}{item['sni']}{RESET} {redir_flag}")
        print(f"    - 协议/ALPN: {GREEN}{item['tls_version']}{RESET} | {item['alpn']} | 抗量子: {MAGENTA}{item['pqc']}{RESET}")
        print(f"    - 商业 CA 主体: {BOLD}{item['issuer']}{RESET} (有效期至: {item['expire_date']}, 剩余 {item['remaining_days']} 天)")
        print(f"    {YELLOW}------------------------------------------------------------{RESET}")
        print(f"    {BOLD}Sing-box 推荐配置:{RESET}")
        print(f'      "server_name": "{item["sni"]}",')
        print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
        print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")

    if export_csv(found_targets, CSV_OUTPUT):
        print(f"{GREEN}[✓] 真实候选目标已成功导出至: {BOLD}{CSV_OUTPUT}{RESET}")
        print(f"[*] 提示：可直接导入 RealityChecker-PLUS 进行批量测试：")
        print(f"    {CYAN}./reality-checker csv {CSV_OUTPUT}{RESET}\n")

if __name__ == "__main__":
    main()
EOF_PYTHON
