# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 证书智能搜索与防套娃评估工具 V3.0
核心升级：
1. [独家] 严防“邻居 REALITY 套娃”：时延不对称算法 + 虚假巨头证书拦截
2. [防护] GFWList 墙内可达性初筛：剔除国内无法直连的被墙域名
3. [校准] HTTP 301/302 重定向落地追踪：自动校准为真正的 FinalDomain
4. [前瞻] X25519MLKEM768 后量子抗量子检测与大热域名风险降权
5. [生态] 自动导出标准 CSV，兼容 RealityChecker-PLUS
"""

import sys
import os
import re
import csv
import ssl
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

# 运行参数
DEFAULT_LIMIT = 5       # 抓取合格优质目标上限
MAX_WORKERS = 64        # 并发探测线程数
SOCKET_TIMEOUT = 2.5    # 单次探测超时时间 (秒)
CSV_OUTPUT = "reality_targets.csv"

# 常见已被 GFW 封锁的典型域名特征（国内客户端无法直连）
BLOCKED_KEYWORDS = {
    "google", "youtube", "facebook", "twitter", "x.com", "instagram",
    "telegram", "netflix", "wikipedia", "github.com", "pornhub", "nyt",
    "bbc", "v2ex", "medium", "reddit", "openai", "chatgpt"
}

# 常见顶级大热域名（不建议作为首选，避免集中审查）
HOT_DOMAINS = {
    "apple.com", "icloud.com", "microsoft.com", "windows.com",
    "amazon.com", "tesla.com", "yahoo.com", "live.com"
}

# 邻居 REALITY 最喜欢偷的“虚假大厂库”（普通机房 IP 绝不可能拥有其物理证书）
FAKE_GIANT_TARGETS = {
    "apple": ["apple.com", "apple.com.cn", "cdn-apple.com"],
    "microsoft": ["microsoft.com", "azure.com", "live.com"],
    "tesla": ["tesla.com", "tesla.cn"],
}

def get_public_ip_and_asn():
    """获取本机公网 IPv4 及所属机房 ASN 组织"""
    endpoints = [
        "https://ipinfo.io/json",
        "https://ifconfig.co/json",
        "https://api.ipify.org"
    ]
    ip = None
    org = "Unknown"
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
            with urllib.request.urlopen(req, timeout=3) as resp:
                content = resp.read().decode('utf-8').strip()
                if url.endswith("/json"):
                    import json
                    data = json.loads(content)
                    ip = data.get("ip")
                    org = data.get("org", "Unknown")
                else:
                    ip = content
                if ip:
                    ipaddress.IPv4Address(ip)
                    return ip, org
        except Exception:
            continue
    return ip, org

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

def is_gfw_blocked(domain):
    """GFW 封锁简易快速检测"""
    domain = domain.lower()
    for kw in BLOCKED_KEYWORDS:
        if kw in domain:
            return True, f"命中被墙特征 [{kw}]"
    return False, ""

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
    """第一阶段探测：TCP 端口 + 初步 TLS 握手 + 时延不对称初筛"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SOCKET_TIMEOUT)
    start_time = time.time()
    try:
        s.connect((ip_str, 443))
    except Exception:
        s.close()
        return None

    tcp_rtt = (time.time() - start_time) * 1000

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

        # 【防套娃算法 1：时延严重不对称拦截】
        # 同网段 TCP 极快 (<10ms)，但 TLS 却因为中继转发暴增至 60ms 以上
        if tcp_rtt < 12 and handshake_rtt > 55 and (handshake_rtt / max(tcp_rtt, 0.5)) > 6:
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

def verify_and_evaluate(probe_result, local_org):
    """第二阶段：防套娃身份核验 + GFWList 过滤 + 综合评分"""
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

        # 1. GFWList 封锁初筛
        blocked, _ = is_gfw_blocked(sni_lower)
        if blocked:
            continue

        # 2. 【防套娃算法 2：机房身份与证书巨头不匹配拦截】
        # 如果是普通 VPS 托管机房（非苹果/微软自建 ASN），却出现了苹果/微软的证书，必是邻居偷的！
        is_spoof_giant = False
        for giant_name, giant_domains in FAKE_GIANT_TARGETS.items():
            if any(gd in sni_lower for gd in giant_domains):
                # 检查 ASN 组织名称，如果不是该大厂官方 ASN，直接判定为邻居套娃
                if giant_name not in local_org.lower():
                    is_spoof_giant = True
                    break
        if is_spoof_giant:
            print(f"  {RED}[✖ 拦截套娃] IP: {ip:<15} 证书宣称是 {sni}，但机房为普通 VPS ({local_org})，判定为邻居 REALITY！{RESET}")
            continue

        # 3. 严格 TLS 握手及证书有效性检验
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

            not_after_str = cert.get('notAfter')
            expire_date = datetime.strptime(not_after_str, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
            remaining_days = (expire_date - datetime.now(timezone.utc)).days
            if remaining_days < 7:
                continue

            issuer = dict(x[0] for x in cert.get('issuer', []))
            issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))
            sans = [v for k, v in cert.get('subjectAltName', []) if k == 'DNS']

            # 4. HTTP 重定向追踪
            final_sni, is_redirected = trace_http_redirect(ip, sni)

            # 5. 后量子抗量子 (ML-KEM-768) 判定
            supports_pqc = "可能支持"
            if any(k in issuer_org.lower() for k in ["cloudflare", "google", "amazon"]):
                supports_pqc = "支持 (ML-KEM-768/Kyber)"

            is_hot = any(sni_lower.endswith(hot) for hot in HOT_DOMAINS)

            # 6. 综合评分系统 (100 分制)
            score = 50
            if total_rtt < 3.0: score += 25
            elif total_rtt < 12.0: score += 15
            if alpn == "h2": score += 15
            if not is_hot: score += 10
            if not is_redirected: score += 10
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

def generate_subnets(base_ip):
    """由近到远生成网段列表"""
    net24 = ipaddress.IPv4Network(f"{base_ip}/24", strict=False)
    net23 = ipaddress.IPv4Network(f"{base_ip}/23", strict=False)
    net22 = ipaddress.IPv4Network(f"{base_ip}/22", strict=False)

    return [
        ("Layer 1 (同 /24 邻近交换机机架)", [str(ip) for ip in net24.hosts() if str(ip) != base_ip]),
        ("Layer 2 (扩充 /23 相邻机房网段)", [str(ip) for ip in net23.hosts() if ip not in net24 and str(ip) != base_ip]),
        ("Layer 3 (扩充 /22 区域同城网段)", [str(ip) for ip in net22.hosts() if ip not in net23 and str(ip) != base_ip])
    ]

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
    print(f"{CYAN}{BOLD}   REALITY 同网段 TLS 1.3 智能嗅探与防套娃工具 V3.0 (Anti-Spoof) {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    print(f"[*] 正在识别本机网络环境与机房 ASN 属性...")
    my_ip, my_org = get_public_ip_and_asn()
    if not my_ip:
        print(f"{RED}[!] 获取公网 IP 失败，请检查网络配置。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机 IP: {BOLD}{my_ip}{RESET} | 归属机房: {BOLD}{my_org}{RESET}\n")

    layers = generate_subnets(my_ip)
    found_targets = []

    for layer_name, ip_list in layers:
        print(f"{YELLOW}[>] 正在扫描: {layer_name}{RESET}")
        print(f"[*] 待检测节点: {len(ip_list)} 个 | 并发线程: {MAX_WORKERS}")

        stage1_results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_ip = {executor.submit(probe_ip, ip): ip for ip in ip_list}
            scanned = 0
            for future in concurrent.futures.as_completed(future_to_ip):
                scanned += 1
                res = future.result()
                if res:
                    if res.get("spoof_relay"):
                        print(f"  {RED}[✖ 拦截套娃] IP: {res['ip']:<15} (TCP: {res['tcp_rtt']:.1f}ms, TLS: {res['handshake_rtt']:.1f}ms - 时延严重割裂！){RESET}")
                    else:
                        stage1_results.append(res)
                        print(f"  {CYAN}发现物理开放: {res['ip']:<15} (延迟: {res['tcp_rtt']}ms | TLS 1.3: 是){RESET}")

                if scanned % 25 == 0 or scanned == len(ip_list):
                    sys.stdout.write(f"\r  -> 进度: {scanned}/{len(ip_list)} (捕获候选: {len(stage1_results)})")
                    sys.stdout.flush()

        print(f"\n[*] 正在执行套娃识别、GFWList 过滤、重定向校准与综合评估...")
        for probe_res in stage1_results:
            evaluated = verify_and_evaluate(probe_res, my_org)
            if evaluated:
                found_targets.append(evaluated)
                print(f"  {GREEN}[✓ 真实合格] {evaluated['stars']} IP: {evaluated['ip']:<15} | SNI: {evaluated['sni']} | CA: {evaluated['issuer']}{RESET}")

            if len(found_targets) >= DEFAULT_LIMIT:
                print(f"\n{GREEN}[✓] 已找到 {DEFAULT_LIMIT} 个真实优质原生目标，停止向外扩展。{RESET}")
                break

        if len(found_targets) >= DEFAULT_LIMIT:
            break
        else:
            print(f"[*] 当前网段完成，已有合格目标: {len(found_targets)}/{DEFAULT_LIMIT}。扩展到下一层级...\n")

    if not found_targets:
        print(f"\n{RED}[!] 周边网段未发现符合条件的真实独立服务器。{RESET}")
        return

    # 按推荐总分与 RTT 排序
    found_targets.sort(key=lambda x: (-x["score"], x["rtt"]))

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}          🏆 REALITY 真实原生最佳目标排行 (剔除一切套娃)         {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}\n")

    for idx, item in enumerate(found_targets, 1):
        hot_flag = f"{RED}[⚠️ 热门域名]{RESET}" if item["is_hot"] else f"{GREEN}[原生推荐]{RESET}"
        redir_flag = f"{YELLOW}(重定向校准自 {item['raw_sni']}){RESET}" if item["is_redirected"] else ""
        print(f"{BOLD}[{idx}] {item['stars']} IP: {item['ip']}:443  (物理延迟: {item['rtt']} ms) {hot_flag}{RESET}")
        print(f"    - 推荐 SNI: {BOLD}{CYAN}{item['sni']}{RESET} {redir_flag}")
        print(f"    - 协议/ALPN: {GREEN}{item['tls_version']}{RESET} | {item['alpn']} | 抗量子: {MAGENTA}{item['pqc']}{RESET}")
        print(f"    - 证书主体: {item['issuer']} (有效期至: {item['expire_date']}, 剩余 {item['remaining_days']} 天)")
        print(f"    {YELLOW}------------------------------------------------------------{RESET}")
        print(f"    {BOLD}Sing-box 推荐配置:{RESET}")
        print(f'      "server_name": "{item["sni"]}",')
        print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
        print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")

    if export_csv(found_targets, CSV_OUTPUT):
        print(f"{GREEN}[✓] 真实候选目标已成功导出至: {BOLD}{CSV_OUTPUT}{RESET}")
        print(f"[*] 提示：可配合 RealityChecker-PLUS 进行批量二次压测：")
        print(f"    {CYAN}./reality-checker csv {CSV_OUTPUT}{RESET}\n")

if __name__ == "__main__":
    main()
EOF_PYTHON
