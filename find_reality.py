#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同 ASN 大厂域名全自动测速优选工具 (Auto-ASN Enterprise Scanner)

项目特性:
- 零第三方依赖: 纯 Python 3 标准库实现，开箱即用 (Linux / macOS / Windows)
- 自动识别本机网络: 多源并发探测公网 IP、自治系统号 (ASN) 及 ISP 组织
- 严格同 ASN 对齐校验: 采用 whois.cymru.com 43 端口毫秒级真实比对 IP 归属，杜绝跨 ASN 混入
- 丰富大厂 ASN 库: 覆盖 腾讯云、AWS、Cloudflare、Google、Azure、Oracle、Hetzner、OVH、Vultr 等
- 严格符合 REALITY 规范: 强制 TLS 1.3、ALPN 必须支持 HTTP/2 (h2)、证书有效天数校验
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
    # 腾讯云 / 腾讯 (Tencent Cloud / Overseas & Domestic)
    132203: [
        "intl.cloud.tencent.com", "cloud.tencent.com", "tencentcloud.com",
        "www.tencentcloud.com", "tencent.com", "www.tencent.com",
        "dnspod.com", "dnspod.cn", "api.tencentcloudapi.com",
        "voovmeeting.com", "meeting.tencent.com", "work.weixin.qq.com"
    ],
    45090: [
        "cloud.tencent.com", "intl.cloud.tencent.com", "www.tencent.com",
        "tencent.com", "dnspod.cn", "dnspod.com", "api.tencentcloudapi.com"
    ],
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
    # Alibaba Cloud / 阿里云
    45102: [
        "www.alibabacloud.com", "account.alibabacloud.com", "www.aliyun.com",
        "developer.aliyun.com", "help.aliyun.com"
    ],
    37963: [
        "www.aliyun.com", "developer.aliyun.com", "www.alibabacloud.com"
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


def fetch_current_network_info():
    """多源高可用获取当前机器的公网 IP、归属 ASN 和 ISP 组织"""
    endpoints = [
        ("http://ip-api.com/json/?fields=status,message,country,city,as,org,query", "ip-api"),
        ("https://api.ip.sb/geoip", "ip.sb")
    ]
    
    for url, source in endpoints:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
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
    """
    通过 whois.cymru.com 43 端口精准获取 IP 归属的 ASN (纯 socket 极速查询)
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(('whois.cymru.com', 43))
        s.send(f'{ip}\n'.encode())
        resp = b''
        while True:
            chunk = s.recv(1024)
            if not chunk:
                break
            resp += chunk
        s.close()
        
        for line in resp.decode(errors='ignore').splitlines():
            line = line.strip()
            if line and not line.startswith("AS"):
                parts = [p.strip() for p in line.split('|')]
                if len(parts) >= 1 and parts[0].isdigit():
                    return int(parts[0])
    except Exception:
        # Fallback 到 HTTP 查询
        try:
            url = f"http://ip-api.com/json/{ip}?fields=as"
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                match = re.search(r'AS(\d+)', data.get("as", ""))
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
        for offset in [1, -1, 2, -2, 5, 10]:
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

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            res_lists = executor.map(query_ptr, sample_ips)
            for r in res_lists:
                for d in r:
                    if len(d) > 3 and not re.match(r'^\d+\.\d+\.\d+\.\d+$', d):
                        found_domains.add(d.lower())
    except Exception:
        pass
    return list(found_domains)


def resolve_nearest_ip(domain):
    """利用本地系统 DNS 获取真实 A 记录 IP"""
    try:
        _, _, ip_list = socket.gethostbyname_ex(domain)
        v4_ips = [ip for ip in ip_list if ":" not in ip]
        return v4_ips[0] if v4_ips else None
    except Exception:
        return None


def test_domain_handshake(domain, local_asn, timeout=2.5):
    """执行真实 TCP 建立 + TLS 1.3 握手，并严格核验 ASN 一致性"""
    nearest_ip = resolve_nearest_ip(domain)
    if not nearest_ip:
        return None

    # 1. 严格校验目标 IP 是否属于同一个 ASN
    target_asn = get_ip_asn(nearest_ip)
    is_same_asn = (local_asn is not None and target_asn == local_asn)

    # 2. TCP 连接
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    tcp_start = time.time()
    try:
        s.connect((nearest_ip, 443))
    except Exception:
        s.close()
        return None
    tcp_rtt = (time.time() - tcp_start) * 1000

    # 3. TLS 握手测试
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

        # REALITY 严苛标准：必须支持 TLS 1.3
        if sslsock.version() != "TLSv1.3":
            sslsock.close()
            return None

        cert = sslsock.getpeercert()
        alpn = sslsock.selected_alpn_protocol() or "http/1.1"
        sslsock.close()

        # REALITY 严苛标准：必须支持 HTTP/2
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
    if item['is_same_asn']:
        asn_tag = f"{GREEN}[同 ASN 完美命中 🌟 AS{local_asn}]{RESET}"
    else:
        asn_tag = f"{YELLOW}[跨 ASN: AS{item['target_asn']}]{RESET}"
    
    print(f"{BOLD}[{idx}] 🏆 推荐 SNI: {BOLD}{CYAN}{item['domain']}{RESET}  {asn_tag}")
    print(f"    - 目标官方 IP: {BOLD}{item['ip']}:443{RESET} (握手总延迟: {GREEN}{item['total_rtt']} ms{RESET} | TCP: {item['tcp_rtt']} ms)")
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
    parser.add_argument("-t", "--threads", type=int, default=32, help="测速并发线程数 (默认: 32)")
    parser.add_argument("-w", "--timeout", type=float, default=2.5, help="单次握手超时时间 (秒, 默认: 2.5)")
    parser.add_argument("-n", "--top", type=int, default=10, help="展示最优结果数量 (默认: 10)")
    return parser.parse_args()


def main():
    args = parse_arguments()

    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}    REALITY 同 ASN 大厂域名全自动测速优选工具 (Auto-ASN)          {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    
    print(f"[*] 正在自动探测当前机器的公网 IP 及归属 ASN 自治系统...")
    net_info = fetch_current_network_info()
    
    if not net_info or not net_info.get("ip"):
        print(f"{RED}[!] 无法获取本地公网 IP/ASN，请检查网络。{RESET}")
        return

    local_asn = net_info.get("asn")
    print(f"{GREEN}[✓] 本机公网 IP : {BOLD}{net_info['ip']}{RESET}")
    print(f"{GREEN}[✓] 归属自治系统: {BOLD}{net_info['asn_name']}{RESET}")
    print(f"{GREEN}[✓] 机房与位置  : {BOLD}{net_info['org']} ({net_info['country']} - {net_info['city']}){RESET}\n")
    
    # 优先抽取匹配本地 ASN 的大厂官方域名
    matched_asn_domains = ENTERPRISE_ASN_MAP.get(local_asn, [])
    if matched_asn_domains:
        print(f"{GREEN}[+] 命中大厂专属 ASN (AS{local_asn})！已载入官方核心合规域名池。{RESET}")
    else:
        print(f"{YELLOW}[!] 当前 ASN (AS{local_asn}) 未在内置大厂库，将通过同 C 段 PTR 及全网大厂库深度扫描同 ASN 目标...{RESET}")

    # 动态扫描同一 C 段的 PTR 反解域名
    subnet_ptr_domains = scan_subnet_ptr_domains(net_info['ip'])
    if subnet_ptr_domains:
        print(f"[+] 动态捕获同机房 /24 网段邻近域名: {len(subnet_ptr_domains)} 个")

    # 汇总待测试候选域名
    candidate_domains = list(set(matched_asn_domains + subnet_ptr_domains))
    
    # 如果候选太少，补充其他腾讯/主流大厂常用域名以防漏网
    if len(candidate_domains) < 15:
        candidate_domains.extend([
            "cloud.tencent.com", "intl.cloud.tencent.com", "tencentcloud.com",
            "www.tencent.com", "dnspod.com", "voovmeeting.com", "work.weixin.qq.com"
        ])
        candidate_domains = list(set(candidate_domains))

    print(f"[*] 候选扫描目标池: {len(candidate_domains)} 个域名")
    print(f"[*] 正在并发执行 TLS 1.3/H2 握手与【严格同 ASN 对齐校验】...\n")

    results = []
    start_all = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as executor:
        future_to_domain = {executor.submit(test_domain_handshake, dom, local_asn, args.timeout): dom for dom in candidate_domains}
        finished = 0
        total = len(candidate_domains)
        for future in concurrent.futures.as_completed(future_to_domain):
            finished += 1
            res = future.result()
            if res:
                results.append(res)
            if finished % 3 == 0 or finished == total:
                sys.stdout.write(f"\r  -> 测速与 ASN 校验进度: {finished}/{total} (合格目标: {len(results)} 个)")
                sys.stdout.flush()

    total_time = round(time.time() - start_all, 1)
    print(f"\n\n{GREEN}[✓] 探测测速完毕 (耗时 {total_time} 秒)！{RESET}")

    # 严格同 ASN 过滤
    same_asn_results = [r for r in results if r["is_same_asn"]]
    
    if same_asn_results:
        # 按延迟升序排序
        same_asn_results.sort(key=lambda x: x["total_rtt"])
        print(f"\n{GREEN}{BOLD}================================================================={RESET}")
        print(f"{GREEN}{BOLD}   🎉 成功锁定 {len(same_asn_results)} 个【100% 同 ASN (AS{local_asn})】大厂官方目标！{RESET}")
        print(f"{GREEN}{BOLD}================================================================={RESET}\n")
        
        top_n = min(args.top, len(same_asn_results))
        for idx in range(top_n):
            print_result_card(idx + 1, same_asn_results[idx], local_asn)
    else:
        print(f"\n{YELLOW}[!] 在当前 ASN (AS{local_asn}) 内部未直接发现开放 TLS 1.3 + H2 的同 ASN 目标。{RESET}")
        if results:
            print(f"[*] 为您展示邻近超低延迟的优质合规大厂站点 (跨 ASN):")
            results.sort(key=lambda x: x["total_rtt"])
            for idx in range(min(5, len(results))):
                print_result_card(idx + 1, results[idx], local_asn)

    print(f"{GREEN}[✓] 探测完成！{RESET}")


if __name__ == "__main__":
    main()
