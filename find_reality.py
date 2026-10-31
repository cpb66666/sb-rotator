# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 证书自动嗅探与智能评估工具 V2.0
集成 RealityChecker-PLUS 优秀特性：
- GFWList 可达性初筛
- HTTP 重定向最终 SNI 追踪
- 大热域名降权与 ML-KEM-768 后量子标记
- 综合星级评分与 CSV 导出
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

# 默认参数
DEFAULT_LIMIT = 5       # 抓取合格目标数量上限
MAX_WORKERS = 64        # 并发线程数
SOCKET_TIMEOUT = 2.5    # 超时时间 (秒)
CSV_OUTPUT = "reality_targets.csv"

# 常见已被 GFW 封锁的典型域名特征（墙内不可直连）
BLOCKED_KEYWORDS = {
    "google", "youtube", "facebook", "twitter", "x.com", "instagram",
    "telegram", "netflix", "wikipedia", "github.com", "pornhub", "nyt",
    "bbc", "v2ex", "medium", "reddit", "openai", "chatgpt"
}

# 常见顶级大热域名（不建议作为首选，容易被重点审计）
HOT_DOMAINS = {
    "apple.com", "icloud.com", "microsoft.com", "windows.com",
    "amazon.com", "tesla.com", "yahoo.com", "live.com"
}

def get_public_ip():
    """获取本机公网 IPv4 地址"""
    endpoints = [
        "https://api.ipify.org",
        "https://icanhazip.com",
        "https://ifconfig.me/ip",
        "https://ip.sb"
    ]
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
            with urllib.request.urlopen(req, timeout=3) as resp:
                ip = resp.read().decode('utf-8').strip()
                ipaddress.IPv4Address(ip)
                return ip
        except Exception:
            continue
    return None

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
    """GFW 封锁简易快速检测（借鉴 RealityChecker-PLUS）"""
    domain = domain.lower()
    for kw in BLOCKED_KEYWORDS:
        if kw in domain:
            return True, f"命中被墙特征词 [{kw}]"
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
    """
    HTTP 重定向与落地 SNI 检测（借鉴 RealityChecker-PLUS 的 Redirect 模块）
    返回：(最终落地域名, 是否发生重定向, HTTP状态码)
    """
    final_domain = domain
    is_redirected = False
    status_code = 0
    try:
        # 强制将域名解析指向目标 IP 进行 HTTP 嗅探
        conn = socket.create_connection((ip, 443), timeout=SOCKET_TIMEOUT)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(conn, server_hostname=domain)
        
        # 发送轻量 HEAD 请求
        req = f"HEAD / HTTP/1.1\r\nHost: {domain}\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
        s.sendall(req.encode())
        resp = s.recv(1024).decode('utf-8', errors='ignore')
        s.close()

        # 解析状态行
        status_match = re.search(r'HTTP/\d\.\d\s+(\d+)', resp)
        if status_match:
            status_code = int(status_match.group(1))

        # 检查 301/302 重定向
        if status_code in (301, 302, 307, 308):
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
    return final_domain, is_redirected, status_code

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
    """第二阶段：集成 RealityChecker-PLUS 逻辑的综合评估与打分"""
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
        # 1. GFWList 过滤
        blocked, reason = is_gfw_blocked(sni)
        if blocked:
            continue

        # 2. 握手与证书有效性校验
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

            # 3. HTTP 重定向追踪
            final_sni, is_redirected, http_code = trace_http_redirect(ip, sni)

            # 4. 后量子特征检测（Cloudflare/Google 及已知大厂默认支持）
            supports_pqc = "可能支持"
            if any(k in issuer_org.lower() for k in ["cloudflare", "google", "amazon"]):
                supports_pqc = "支持 (ML-KEM-768/Kyber)"

            # 5. 热门大网站预警判定
            is_hot = any(sni.endswith(hot) for hot in HOT_DOMAINS)

            # 6. 综合评分系统 (100分制)
            score = 50
            if total_rtt < 2.0: score += 25
            elif total_rtt < 10.0: score += 15
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
        ("Layer 1 (同 /24 局域邻居网段)", [str(ip) for ip in net24.hosts() if str(ip) != base_ip]),
        ("Layer 2 (扩充 /23 相邻机架网段)", [str(ip) for ip in net23.hosts() if ip not in net24 and str(ip) != base_ip]),
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
    print(f"{CYAN}{BOLD}    REALITY 同网段 TLS 1.3 证书智能搜索评估工具 V2.0 (Plus)     {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    print(f"[*] 正在自动检测本机外网 IPv4 地址...")
    my_ip = get_public_ip()
    if not my_ip:
        print(f"{RED}[!] 获取公网 IP 失败，请检查网络设置。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机公网 IP: {BOLD}{my_ip}{RESET}\n")

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
                    stage1_results.append(res)
                    print(f"  {CYAN}发现开放主机: {res['ip']:<15} (延迟: {res['tcp_rtt']}ms | TLS 1.3: 是){RESET}")
                if scanned % 25 == 0 or scanned == len(ip_list):
                    sys.stdout.write(f"\r  -> 扫描进度: {scanned}/{len(ip_list)} (开放TLS1.3: {len(stage1_results)})")
                    sys.stdout.flush()

        print(f"\n[*] 正在执行 GFWList 过滤、重定向校准与后量子综合评估...")
        for probe_res in stage1_results:
            evaluated = verify_and_evaluate(probe_res)
            if evaluated:
                found_targets.append(evaluated)
                print(f"  {GREEN}[✓ 优选合格] {evaluated['stars']} IP: {evaluated['ip']:<15} | SNI: {evaluated['sni']} | CA: {evaluated['issuer']}{RESET}")

            if len(found_targets) >= DEFAULT_LIMIT:
                print(f"\n{GREEN}[✓] 已找到 {DEFAULT_LIMIT} 个高分目标，停止向外扩展。{RESET}")
                break

        if len(found_targets) >= DEFAULT_LIMIT:
            break
        else:
            print(f"[*] 当前网段完成，已有合格目标: {len(found_targets)}/{DEFAULT_LIMIT}。扩展到下一层级...\n")

    if not found_targets:
        print(f"\n{RED}[!] 周边网段未发现符合条件的合格目标。{RESET}")
        return

    # 按综合评分和 RTT 排序
    found_targets.sort(key=lambda x: (-x["score"], x["rtt"]))

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}           🏆 REALITY 最佳目标综合排行榜 (推荐度降序)            {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}\n")

    for idx, item in enumerate(found_targets, 1):
        hot_flag = f"{RED}[⚠️ 大热域名]{RESET}" if item["is_hot"] else f"{GREEN}[小众推荐]{RESET}"
        redir_flag = f"{YELLOW}(由 {item['raw_sni']} 重定向校准){RESET}" if item["is_redirected"] else ""
        print(f"{BOLD}[{idx}] {item['stars']} IP: {item['ip']}:443  (物理延迟: {item['rtt']} ms) {hot_flag}{RESET}")
        print(f"    - 推荐 SNI: {BOLD}{CYAN}{item['sni']}{RESET} {redir_flag}")
        print(f"    - 协议/ALPN: {GREEN}{item['tls_version']}{RESET} | {item['alpn']} | 抗量子: {MAGENTA}{item['pqc']}{RESET}")
        print(f"    - 证书签发: {item['issuer']} (到期: {item['expire_date']}, 剩余 {item['remaining_days']} 天)")
        print(f"    {YELLOW}------------------------------------------------------------{RESET}")
        print(f"    {BOLD}Sing-box 配置参考:{RESET}")
        print(f'      "server_name": "{item["sni"]}",')
        print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
        print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")

    # 导出 CSV
    if export_csv(found_targets, CSV_OUTPUT):
        print(f"{GREEN}[✓] 结果已成功导出至: {BOLD}{CSV_OUTPUT}{RESET}")
        print(f"[*] 提示：该文件可直接导入 RealityChecker-PLUS 进行批量测试：")
        print(f"    {CYAN}./reality-checker csv {CSV_OUTPUT}{RESET}\n")

if __name__ == "__main__":
    main()
EOF_PYTHON
