# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 嗅探器 V8.2 (Real-Webpage Verified 网页验真版)
核心升级：
1. 彻底剔除【只有代理协议、没有实际网页】的纯翻墙小鸡
2. 模拟真实 Chrome 发送 HTTP GET 探测，核验 HTML 标签与网页实际内容
3. 权威 DNS 直指归属认证（灭杀大厂套娃）
4. 交互式深挖，已扫 IP 绝不重复
"""

import sys
import os
import re
import ssl
import time
import socket
import ipaddress
import subprocess
import urllib.request
import concurrent.futures
from datetime import datetime, timezone

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"

BATCH_SIZE = 3
MAX_WORKERS = 64
SOCKET_TIMEOUT = 2.0
MAX_RTT = 60.0

def get_public_ip():
    for url in ["https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"]:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'curl/7.68.0'})
            with urllib.request.urlopen(req, timeout=3) as resp:
                ip = resp.read().decode('utf-8').strip()
                ipaddress.IPv4Address(ip)
                return ip
        except Exception:
            continue
    return None

def extract_domains_from_der(der_bytes):
    domains = set()
    try:
        proc = subprocess.Popen(
            ["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-ext", "subjectAltName"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        out, _ = proc.communicate(input=der_bytes, timeout=1.5)
        out_str = out.decode('utf-8', errors='ignore')

        cn_match = re.search(r'CN\s*=\s*([^/,\n]+)', out_str)
        if cn_match:
            cn = cn_match.group(1).strip().lstrip('*.')
            if "." in cn and not re.match(r'^\d+\.\d+\.\d+\.\d+$', cn):
                domains.add(cn)

        for san in re.findall(r'DNS:([^,\s]+)', out_str):
            san = san.strip().lstrip('*.')
            if "." in san and not re.match(r'^\d+\.\d+\.\d+\.\d+$', san):
                domains.add(san)
    except Exception:
        pass
    return list(domains)

def probe_ip(ip_str):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SOCKET_TIMEOUT)
    start_t = time.time()
    try:
        s.connect((ip_str, 443))
    except Exception:
        s.close()
        return None

    tcp_rtt = (time.time() - start_t) * 1000
    if tcp_rtt > MAX_RTT:
        s.close()
        return None

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        sslsock = ctx.wrap_socket(s, server_hostname=None)
        sslsock.settimeout(SOCKET_TIMEOUT)
        sslsock.do_handshake()

        if sslsock.version() != "TLSv1.3":
            sslsock.close()
            return None

        der_cert = sslsock.getpeercert(binary_form=True)
        alpn = sslsock.selected_alpn_protocol() or "http/1.1"
        sslsock.close()

        if not der_cert:
            return None

        candidates = extract_domains_from_der(der_cert)
        if not candidates:
            try:
                ptr_name, _, _ = socket.gethostbyaddr(ip_str)
                if "." in ptr_name:
                    candidates.append(ptr_name)
            except Exception:
                pass

        if not candidates:
            return None

        return {
            "ip": ip_str,
            "rtt": round(tcp_rtt, 2),
            "alpn": alpn,
            "candidates": candidates
        }
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None

def is_genuine_host(ip, domain):
    """权威 DNS 直指认证"""
    try:
        _, _, official_ips = socket.gethostbyname_ex(domain)
        if ip in official_ips:
            return True, "官方 DNS 直指本 IP"
        
        target_obj = ipaddress.IPv4Address(ip)
        for oip in official_ips:
            if target_obj in ipaddress.IPv4Network(f"{oip}/24", strict=False):
                return True, "属于同网段企业集群"
                
        return False, f"官方真实 IP 为 {official_ips[:2]}，当前探测 IP 不在列表中 (套娃机)"
    except Exception as e:
        return False, f"DNS 查询失败: {e}"

def has_real_website(ip, domain):
    """【核心升级】真实网页存活性核验：模拟 Chrome 访问，排除纯代理空壳"""
    try:
        conn = socket.create_connection((ip, 443), timeout=SOCKET_TIMEOUT)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(conn, server_hostname=domain)

        req = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {domain}\r\n"
            f"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0\r\n"
            f"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
            f"Connection: close\r\n\r\n"
        )
        s.sendall(req.encode())
        
        raw_resp = b""
        while True:
            chunk = s.recv(2048)
            if not chunk:
                break
            raw_resp += chunk
            if len(raw_resp) > 8192:
                break
        s.close()

        if not raw_resp:
            return False, "连接直接断开/未返回任何 HTTP 内容 (纯代理节点)"

        resp_text = raw_resp.decode('utf-8', errors='ignore').lower()

        status_match = re.search(r'http/\d\.\d\s+(\d+)', resp_text)
        if not status_match:
            return False, "返回非 HTTP 响应 (疑似代理流量)"

        status_code = int(status_match.group(1))

        # 301/302 重定向放行
        if status_code in (301, 302, 307, 308):
            return True, f"合法重定向站点 ({status_code})"

        # 必须包含 HTML 页面结构或具备充足的网页正文
        if "<html" in resp_text or "<!doctype" in resp_text or "<head" in resp_text or len(raw_resp) > 150:
            return True, f"真实网页内容存在 (状态: {status_code}, 正文: {len(raw_resp)}B)"

        return False, f"无实际 Web 页面内容 (状态: {status_code}, 长度仅 {len(raw_resp)}B)"
    except Exception as e:
        return False, f"Web 请求异常: {e}"

def verify_target(probe_res):
    ip = probe_res["ip"]
    candidates = probe_res["candidates"]

    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED

    for sni in candidates:
        # 1. 认证真实宿主（灭杀套娃）
        is_real, auth_msg = is_genuine_host(ip, sni)
        if not is_real:
            print(f"  {RED}[✖ 拦截套娃] IP: {ip:<15} 宣称是 {sni}，但 {auth_msg}！{RESET}")
            continue

        # 2. 【核心升级】：核验浏览器实际打开是否有真实网页（灭杀纯代理空壳）
        is_web, web_msg = has_real_website(ip, sni)
        if not is_web:
            print(f"  {YELLOW}[✖ 拦截空壳] IP: {ip:<15} 域名: {sni} -> {web_msg}！{RESET}")
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
            alpn = sslsock.selected_alpn_protocol() or probe_res["alpn"]
            sslsock.close()

            expire_date = datetime.strptime(cert.get('notAfter'), '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
            remaining_days = (expire_date - datetime.now(timezone.utc)).days
            if remaining_days < 2:
                continue

            issuer = dict(x[0] for x in cert.get('issuer', []))
            issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))

            return {
                "ip": ip,
                "rtt": round(total_rtt, 2),
                "sni": sni,
                "alpn": alpn,
                "issuer": issuer_org,
                "expire_date": expire_date.strftime('%Y-%m-%d'),
                "remaining_days": remaining_days,
                "web_info": web_msg
            }
        except Exception:
            try:
                s.close()
            except Exception:
                pass
            continue
    return None

def generate_subnets(base_ip):
    base_obj = ipaddress.IPv4Address(base_ip)
    cidr_list = [24, 23, 22, 21, 20, 19, 18, 17, 16]
    for cidr in cidr_list:
        net = ipaddress.IPv4Network(f"{base_ip}/{cidr}", strict=False)
        yield f"/{cidr} 网段 (包含 {net.num_addresses} 个地址)", [str(ip) for ip in net.hosts() if ip != base_obj]

def print_result(idx, item):
    print(f"{BOLD}[{idx}] IP: {item['ip']}:443  (握手延迟: {item['rtt']} ms){RESET}")
    print(f"    - 推荐 SNI: {BOLD}{CYAN}{item['sni']}{RESET}")
    print(f"    - 网页验证: {GREEN}{item['web_info']}{RESET}")
    print(f"    - 协议/ALPN: {GREEN}TLSv1.3{RESET} | {item['alpn']}")
    print(f"    - 证书签发: {item['issuer']} (剩余: {item['remaining_days']} 天, 到期: {item['expire_date']})")
    print(f"    {YELLOW}------------------------------------------------------------{RESET}")
    print(f"    {BOLD}Sing-box 推荐配置:{RESET}")
    print(f'      "server_name": "{item["sni"]}",')
    print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
    print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")

def main():
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}      REALITY TLS 1.3 嗅探器 V8.2 (Real-Webpage Verified 版)     {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    my_ip = get_public_ip()
    if not my_ip:
        print(f"{RED}[!] 获取本机 IP 失败。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机公网 IP: {BOLD}{my_ip}{RESET}\n")

    scanned_ips = set()
    current_batch = []
    total_found = 0

    for layer_name, ip_list in generate_subnets(my_ip):
        fresh_ips = [ip for ip in ip_list if ip not in scanned_ips]
        for ip in fresh_ips:
            scanned_ips.add(ip)

        if not fresh_ips:
            continue

        print(f"{YELLOW}[>] 正在扫描: {layer_name}{RESET}")
        print(f"[*] 待排查新主机: {len(fresh_ips)} 个 | 累计已排查: {len(scanned_ips)} 个")

        stage1_results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_ip = {executor.submit(probe_ip, ip): ip for ip in fresh_ips}
            count = 0
            for future in concurrent.futures.as_completed(future_to_ip):
                count += 1
                res = future.result()
                if res:
                    stage1_results.append(res)
                    print(f"  {CYAN}发现开放: {res['ip']:<15} (RTT: {res['rtt']}ms | TLS 1.3: 是){RESET}")
                if count % 50 == 0 or count == len(fresh_ips):
                    sys.stdout.write(f"\r  -> 进度: {count}/{len(fresh_ips)} (开放主机: {len(stage1_results)})")
                    sys.stdout.flush()

        print(f"\n[*] 正在执行【DNS 归属鉴别】与【真实网页存活性核验】...")
        for probe_res in stage1_results:
            target = verify_target(probe_res)
            if target:
                current_batch.append(target)
                total_found += 1
                print(f"  {GREEN}[✓ 捕获真身] IP: {target['ip']:<15} | SNI: {target['sni']} | CA: {target['issuer']}{RESET}")

            if len(current_batch) >= BATCH_SIZE:
                print(f"\n{CYAN}{BOLD}================================================================={RESET}")
                print(f"{CYAN}{BOLD}          🎉 成功捕获到 {len(current_batch)} 个【真有网页】的可用目标            {RESET}")
                print(f"{CYAN}{BOLD}================================================================={RESET}\n")

                current_batch.sort(key=lambda x: x["rtt"])
                for idx, item in enumerate(current_batch, 1):
                    print_result(idx, item)

                current_batch.clear()

                print(f"{BOLD}-----------------------------------------------------------------{RESET}")
                choice = input(f"👉 {GREEN}[满意请按 q 退出 | 不满意请直接回车 继续扩大范围深挖新目标]: {RESET}").strip().lower()
                print(f"{BOLD}-----------------------------------------------------------------{RESET}\n")
                if choice in ("q", "quit", "exit"):
                    print(f"{GREEN}[✓] 扫描已结束。{RESET}")
                    return

    print(f"\n{GREEN}[✓] 所有可用范围已探索完毕，累计找到 {total_found} 个可用真目标！{RESET}")

if __name__ == "__main__":
    main()
EOF_PYTHON
