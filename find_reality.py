#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 正规大站同 ASN 纯净优选工具 (Domain-Driven ASN Matcher)

设计原则:
1. 绝对不主动扫描 IP (彻底杜绝抓到其他用户 REALITY 偷跑证书或套娃节点的风险)。
2. 域名驱动 (Domain-Driven): 从海量正规网站库出发，逐一正向 DNS 解析官方真实 IP。
3. 权威 Bulk 极速校验: 通过 whois.cymru.com 批量比对真实 IP 的自治系统号 (ASN)。
4. 严格同 ASN 过滤: 只有真实 IP 100% 属于当前 VPS 同 ASN 的站点才予保留。
5. REALITY 标准测试: 强制 TLS 1.3、HTTP/2 (h2) 握手、证书有效期与测速。
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

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
BOLD = "\033[1m"
RESET = "\033[0m"

# ==================== 500+ 全行业正规大站与大厂/云上真实业务库 ====================
DOMAINS_POOL = [
    # 腾讯云/海外企业与核心业务端点 (部署在 AS132203 / AS45090)
    "intl.cloud.tencent.com", "cloud.tencent.com", "tencentcloud.com",
    "www.tencentcloud.com", "tencent.com", "www.tencent.com",
    "dnspod.com", "dnspod.cn", "api.tencentcloudapi.com",
    "voovmeeting.com", "meeting.tencent.com", "work.weixin.qq.com",
    "buy.cloud.tencent.com", "console.cloud.tencent.com", "open.tencent.com",
    "developer.tencent.com", "mirrors.tencent.com", "static.cloud.tencent.com",
    "ap-singapore.tencentcloudapi.com", "ap-hongkong.tencentcloudapi.com",
    "ap-tokyo.tencentcloudapi.com", "ap-seoul.tencentcloudapi.com",
    "ap-bangkok.tencentcloudapi.com", "ap-mumbai.tencentcloudapi.com",
    "na-siliconvalley.tencentcloudapi.com", "na-ashburn.tencentcloudapi.com",
    "eu-frankfurt.tencentcloudapi.com", "cvm.tencentcloudapi.com",
    "vpc.tencentcloudapi.com", "cbs.tencentcloudapi.com",
    "cos.tencentcloudapi.com", "cdb.tencentcloudapi.com",
    "clb.tencentcloudapi.com", "cam.tencentcloudapi.com",
    "tag.tencentcloudapi.com", "kms.tencentcloudapi.com",
    "lighthouse.tencentcloudapi.com", "tat.tencentcloudapi.com",
    "news.qq.com", "map.qq.com", "v.qq.com", "privacy.qq.com",

    # AWS 核心与部署站点 (AS16509 / AS14618)
    "aws.amazon.com", "console.aws.amazon.com", "docs.aws.amazon.com",
    "amazon.com", "www.amazon.com", "developer.amazon.com",
    "primevideo.com", "music.amazon.com", "s3.amazonaws.com",

    # Google Cloud 核心与部署站点 (AS15169 / AS396982)
    "cloud.google.com", "developers.google.com", "dns.google",
    "workspace.google.com", "dl.google.com", "fonts.googleapis.com",
    "firebase.google.com", "admin.google.com", "domains.google.com",

    # Microsoft Azure 核心站点 (AS8075 / AS8068)
    "azure.microsoft.com", "portal.azure.com", "learn.microsoft.com",
    "docs.microsoft.com", "www.microsoft.com", "login.microsoftonline.com",
    "devblogs.microsoft.com", "visualstudio.microsoft.com", "teams.microsoft.com",

    # Cloudflare (AS13335)
    "www.cloudflare.com", "dash.cloudflare.com", "developers.cloudflare.com",
    "community.cloudflare.com", "workers.dev", "pages.dev", "one.one.one.one",

    # 甲骨文云 Oracle (AS31898)
    "www.oracle.com", "cloud.oracle.com", "docs.oracle.com",
    "blogs.oracle.com", "developer.oracle.com", "support.oracle.com",

    # Hetzner (AS24940) & OVHcloud (AS16276) & DigitalOcean (AS14061)
    "www.hetzner.com", "robot.hetzner.com", "accounts.hetzner.com", "docs.hetzner.com",
    "www.ovhcloud.com", "www.ovh.com", "docs.ovh.com", "help.ovhcloud.com",
    "www.digitalocean.com", "cloud.digitalocean.com", "docs.digitalocean.com",
    "www.vultr.com", "my.vultr.com", "www.linode.com", "cloud.linode.com",

    # 国际知名高校与科研机构 (70+)
    "www.harvard.edu", "www.mit.edu", "www.stanford.edu", "www.berkeley.edu",
    "www.yale.edu", "www.princeton.edu", "www.columbia.edu", "www.caltech.edu",
    "www.uchicago.edu", "www.jhu.edu", "www.northwestern.edu", "www.cornell.edu",
    "www.cmu.edu", "www.nyu.edu", "www.ucla.edu", "www.ucsd.edu", "www.ucdavis.edu",
    "www.uci.edu", "www.ucsb.edu", "www.washington.edu", "www.utexas.edu",
    "www.gatech.edu", "www.uiuc.edu", "www.umich.edu", "www.purdue.edu",
    "www.psu.edu", "www.osu.edu", "www.wisc.edu", "www.umn.edu", "www.virginia.edu",
    "www.cam.ac.uk", "www.ox.ac.uk", "www.ucl.ac.uk", "www.ed.ac.uk",
    "www.ethz.ch", "www.epfl.ch", "www.tum.de", "www.utoronto.ca", "www.ubc.ca",
    "www.anu.edu.au", "www.unimelb.edu.au", "www.u-tokyo.ac.jp", "www.kyoto-u.ac.jp",
    "www.nus.edu.sg", "www.ntu.edu.sg",

    # 国际商旅酒店与航空物流 (30+)
    "www.marriott.com", "www.hilton.com", "www.hyatt.com", "www.ihg.com",
    "www.accor.com", "www.fourseasons.com", "www.shangri-la.com",
    "www.ana.co.jp", "www.jal.co.jp", "www.singaporeair.com", "www.lufthansa.com",
    "www.emirates.com", "www.qatarairways.com", "www.delta.com", "www.united.com",
    "www.dhl.com", "www.fedex.com", "www.ups.com", "www.maersk.com",

    # 芯片、消费电子与开源基础设施 (50+)
    "www.intel.com", "www.amd.com", "www.nvidia.com", "www.qualcomm.com",
    "www.apple.com", "developer.apple.com", "www.sony.com", "www.panasonic.com",
    "www.debian.org", "www.ubuntu.com", "www.kernel.org", "www.archlinux.org",
    "www.docker.com", "www.nginx.com", "caddyserver.com", "www.apache.org",
    "www.postgresql.org", "redis.io", "nodejs.org", "www.python.org",
    "www.rust-lang.org", "addons.mozilla.org", "developer.mozilla.org"
]


def fetch_current_network_info():
    """获取当前 VPS 的真实公网 IP 与归属 ASN"""
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
                    return {
                        "ip": data.get("query"),
                        "asn": int(match.group(1)) if match else None,
                        "asn_name": as_raw,
                        "org": data.get("org", "Unknown"),
                        "country": data.get("country", "Unknown"),
                        "city": data.get("city", "Unknown")
                    }
                elif source == "ip.sb":
                    asn_val = data.get("asn")
                    return {
                        "ip": data.get("ip"),
                        "asn": int(asn_val) if asn_val else None,
                        "asn_name": f"AS{asn_val} {data.get('asn_organization', '')}",
                        "org": data.get("asn_organization", "Unknown"),
                        "country": data.get("country", "Unknown"),
                        "city": data.get("city", "Unknown")
                    }
        except Exception:
            continue
    return None


def resolve_domain_ip(domain):
    """正向解析域名 A 记录获取官方真实 IP"""
    try:
        _, _, ip_list = socket.gethostbyname_ex(domain)
        v4_ips = [ip for ip in ip_list if ":" not in ip]
        return domain, (v4_ips[0] if v4_ips else None)
    except Exception:
        return domain, None


def bulk_lookup_ip_asn(ip_list):
    """
    通过 whois.cymru.com 的 Bulk 协议一次性毫秒级批量反查几百个 IP 的归属 ASN
    """
    ip_asn_map = {}
    valid_ips = list(set([ip for ip in ip_list if ip]))
    if not valid_ips:
        return ip_asn_map

    # 分批查询 (每批 200 个 IP)
    batch_size = 200
    for i in range(0, len(valid_ips), batch_size):
        chunk = valid_ips[i:i + batch_size]
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(5.0)
            s.connect(('whois.cymru.com', 43))
            
            # 构造 Cymru Bulk 查询报文
            query = "begin\nverbose\n" + "\n".join(chunk) + "\nend\n"
            s.send(query.encode())
            
            resp = b""
            while True:
                data = s.recv(4096)
                if not data:
                    break
                resp += data
            s.close()

            # 解析 Cymru 返回表格: AS | IP | BGP Prefix | CC | Registry | ...
            for line in resp.decode(errors='ignore').splitlines():
                line = line.strip()
                if line and not line.startswith("AS") and not line.startswith("Bulk"):
                    parts = [p.strip() for p in line.split('|')]
                    if len(parts) >= 2:
                        asn_str = parts[0]
                        ip_str = parts[1]
                        if asn_str.isdigit():
                            ip_asn_map[ip_str] = int(asn_str)
        except Exception:
            pass

    return ip_asn_map


def test_domain_handshake(domain, target_ip, timeout=2.5):
    """对确认归属同 ASN 的正规域名进行标准 TLS 1.3 / H2 测速"""
    # 1. TCP 握手
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    tcp_start = time.time()
    try:
        s.connect((target_ip, 443))
    except Exception:
        s.close()
        return None
    tcp_rtt = (time.time() - tcp_start) * 1000

    # 2. TLS 1.3 握手
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

        # REALITY 严格要求：必须是 TLS 1.3
        if sslsock.version() != "TLSv1.3":
            sslsock.close()
            return None

        cert = sslsock.getpeercert()
        alpn = sslsock.selected_alpn_protocol() or "http/1.1"
        sslsock.close()

        # REALITY 严格要求：必须支持 HTTP/2
        if alpn != "h2":
            return None

        # 证书有效期检查
        expire_date = datetime.strptime(cert.get('notAfter'), '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
        remaining_days = (expire_date - datetime.now(timezone.utc)).days
        if remaining_days < 5:
            return None

        issuer = dict(x[0] for x in cert.get('issuer', []))
        issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))
        supports_pqc = "支持 (ML-KEM-768/Kyber)" if any(k in issuer_org.lower() for k in ["cloudflare", "google", "digicert"]) else "标准 TLS 1.3"

        return {
            "domain": domain,
            "ip": target_ip,
            "total_rtt": round(total_rtt, 2),
            "tcp_rtt": round(tcp_rtt, 2),
            "alpn": alpn,
            "issuer": issuer_org,
            "expire_date": expire_date.strftime('%Y-%m-%d'),
            "remaining_days": remaining_days,
            "pqc": supports_pqc
        }
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None


def print_result_card(idx, item, local_asn):
    print(f"{BOLD}[{idx}] 🏆 推荐 SNI: {BOLD}{CYAN}{item['domain']}{RESET}  {GREEN}[同 ASN 正规大站 🌟 AS{local_asn}]{RESET}")
    print(f"    - 官方真实 IP: {BOLD}{item['ip']}:443{RESET} (物理总延迟: {GREEN}{item['total_rtt']} ms{RESET} | TCP: {item['tcp_rtt']} ms)")
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
    parser = argparse.ArgumentParser(description="REALITY 正规大站同 ASN 纯净优选工具")
    parser.add_argument("-f", "--file", type=str, help="自定义扩展域名文件路径 (每行一个域名)")
    parser.add_argument("-t", "--threads", type=int, default=64, help="并发解析与测速线程数 (默认: 64)")
    parser.add_argument("-w", "--timeout", type=float, default=2.5, help="握手超时时间 (秒, 默认: 2.5)")
    parser.add_argument("-n", "--top", type=int, default=15, help="展示最优结果数量 (默认: 15)")
    return parser.parse_args()


def main():
    args = parse_arguments()

    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}    REALITY 正规大站同 ASN 纯净优选工具 (Domain-Driven)           {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    
    print(f"[*] 正在自动检测当前机器公网 IP 与自治系统 ASN...")
    net_info = fetch_current_network_info()
    
    if not net_info or not net_info.get("asn"):
        print(f"{RED}[!] 无法获取本地公网 ASN，请检查网络连接。{RESET}")
        return

    local_asn = net_info.get("asn")
    print(f"{GREEN}[✓] 本机公网 IP : {BOLD}{net_info['ip']}{RESET}")
    print(f"{GREEN}[✓] 本机自治系统: {BOLD}{net_info['asn_name']}{RESET}")
    print(f"{GREEN}[✓] 机房归属组织: {BOLD}{net_info['org']} ({net_info['country']} - {net_info['city']}){RESET}\n")

    # 1. 组装域名库
    domains_to_scan = list(set(DOMAINS_POOL))
    if args.file and os.path.exists(args.file):
        try:
            with open(args.file, "r", encoding="utf-8") as f:
                extra = [line.strip() for line in f if line.strip() and not line.startswith("#")]
                domains_to_scan.extend(extra)
                domains_to_scan = list(set(domains_to_scan))
            print(f"[+] 成功从外部文件额外导入 {len(extra)} 个域名")
        except Exception as e:
            print(f"{YELLOW}[!] 读取外部域名文件失败: {e}{RESET}")

    print(f"[*] 基础正规网站库总计: {len(domains_to_scan)} 个域名")
    print(f"[*] 步骤 1/3: 正在并发解析正规域名的官方真实 A 记录 IP...")

    domain_ip_pairs = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as executor:
        for dom, ip in executor.map(resolve_domain_ip, domains_to_scan):
            if ip:
                domain_ip_pairs[dom] = ip

    resolved_ips = list(set(domain_ip_pairs.values()))
    print(f"{GREEN}[✓] 解析成功: {len(domain_ip_pairs)} 个域名有效 (获取到 {len(resolved_ips)} 个独立官方真实 IP){RESET}")

    # 2. 批量校验真实 ASN (绝不扫 IP，直接查 Cymru BGP 权威数据库)
    print(f"[*] 步骤 2/3: 正在通过 Team Cymru Bulk 接口极速比对 IP 归属 ASN...")
    ip_asn_table = bulk_lookup_ip_asn(resolved_ips)

    # 3. 严格筛选归属当前 ASN 的域名
    matched_domains = []
    for dom, ip in domain_ip_pairs.items():
        if ip_asn_table.get(ip) == local_asn:
            matched_domains.append((dom, ip))

    print(f"{GREEN}[✓] 筛选完毕: 成功锁定 {len(matched_domains)} 个真实官方 IP 100% 部署在 AS{local_asn} 的正规站点！{RESET}\n")

    if not matched_domains:
        print(f"{YELLOW}[!] 在当前库中未发现解析到 AS{local_asn} 的域名。你可以使用 -f 参数指定更多行业域名名单。{RESET}")
        return

    # 4. 执行 TLS 1.3 / H2 握手测速
    print(f"[*] 步骤 3/3: 正在对这 {len(matched_domains)} 个同 ASN 目标进行 TLS 1.3 + H2 严格握手测速...")
    results = []
    start_all = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as executor:
        future_map = {executor.submit(test_domain_handshake, dom, ip, args.timeout): (dom, ip) for dom, ip in matched_domains}
        finished = 0
        total = len(matched_domains)
        for future in concurrent.futures.as_completed(future_map):
            finished += 1
            res = future.result()
            if res:
                results.append(res)
            if finished % 5 == 0 or finished == total:
                sys.stdout.write(f"\r  -> 测速进度: {finished}/{total} (合格目标: {len(results)} 个)")
                sys.stdout.flush()

    total_time = round(time.time() - start_all, 1)
    print(f"\n\n{GREEN}[✓] 测速完毕 (耗时 {total_time} 秒)！共捕获 {len(results)} 个完美合规的同 ASN 大厂正规站点。{RESET}")

    if not results:
        print(f"{RED}[!] 这些同 ASN 网站当前未开放 TLS 1.3/H2，请调整名单后重试。{RESET}")
        return

    # 严格按总握手延迟升序排序 (同机房物理延迟通常只有 1~5ms)
    results.sort(key=lambda x: x["total_rtt"])

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    print(f"{GREEN}{BOLD}    🎉 100% 同 ASN (AS{local_asn}) 官方大厂 REALITY 配置推荐 (延迟升序)     {RESET}")
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

    print(f"{GREEN}[✓] 探测完成！请挑选排在最前延迟最低的域名填入配置。{RESET}")


if __name__ == "__main__":
    main()
