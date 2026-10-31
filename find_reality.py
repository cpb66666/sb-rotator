# 2>/dev/null; exec python3 - "$@" << 'EOF_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 精炼嗅探器 V8.0 (Minimal & Bogus SNI Probe)
特性：
1. 彻底剔除所有死板规则与白名单，轻量高速
2. 植入【伪造 SNI 盲探】：利用 REALITY 回落机制死穴，精准剔除偷证书机器
3. 由近及远 (/24 -> /16) 平滑扩扫，已扫 IP 自动去重
4. 交互式深挖：每批展示后按回车继续扩大范围，输入 q 退出
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

# 颜色控制
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"

# 基础参数
BATCH_SIZE = 3          # 每批找到几个后询问
MAX_WORKERS = 64        # 并发线程数
SOCKET_TIMEOUT = 2.0    # 握手超时 (秒)
MAX_RTT = 50.0          # 最大允许延迟 (ms)，过滤跨大洲异国 IP

def get_public_ip():
    """获取本机外网 IPv4"""
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
    """从 DER 证书中提取有效域名"""
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
    """初筛：TCP 连通性 + 初步 TLS 1.3 探测"""
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

def is_reality_spoof(ip, true_sni):
    """
    【杀招一】：伪造/随机 SNI 盲探鉴伪
    返回 True 表示是偷证书的 REALITY 伪装机；False 表示是真实 Web/CDN 服务器
    """
    bogus_sni = f"probe-test-{int(time.time())}.internal-check.org"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SOCKET_TIMEOUT)
        s.connect((ip, 443))
        sslsock = ctx.wrap_socket(s, server_hostname=bogus_sni)
        sslsock.settimeout(SOCKET_TIMEOUT)
        sslsock.do_handshake()

        # 盲探拿到证书
        der = sslsock.getpeercert(binary_form=True)
        sslsock.close()

        # 破绽判定：如果面对随机假 SNI，吐出来的证书居然还包含真 SNI，说明是死板单向转发的 REALITY！
        domains = extract_domains_from_der(der)
        if true_sni in domains:
            return True, "面对随机假 SNI 依然死板返回原特定证书"

        return False, "正常多租户服务器"
    except (ssl.SSLError, ConnectionResetError, BrokenPipeError, socket.timeout):
        # 破绽判定：REALITY 收到陌生域名，远端目标拒绝握手导致本地连接被强行掐断
        return True, "面对随机假 SNI 时握手被强行掐断/重置"
    except Exception:
        return False, "正常"

def verify_target(probe_res):
    """复验：真实 SNI 握手有效性 + 杀招一盲探"""
    ip = probe_res["ip"]
    candidates = probe_res["candidates"]

    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED

    for sni in candidates:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SOCKET_TIMEOUT)
        try:
            start_t = time.time()
            s.connect((ip, 443))
            sslsock = ctx.wrap_socket(s, server_hostname=sni)
            sslsock.settimeout(SOCKET_TIMEOUT)
            sslsock.do_handshake()
            total_rtt = (time.time() - start_t) * 1000

            if total_rtt > MAX_RTT:
                sslsock.close()
                continue

            cert = sslsock.getpeercert()
            alpn = sslsock.selected_alpn_protocol() or probe_res["alpn"]
            sslsock.close()

            # 校验有效期
            expire_date = datetime.strptime(cert.get('notAfter'), '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
            remaining_days = (expire_date - datetime.now(timezone.utc)).days
            if remaining_days < 2:
                continue

            issuer = dict(x[0] for x in cert.get('issuer', []))
            issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))

            # 【启动杀招一：伪造 SNI 盲探鉴伪】
            is_spoof, spoof_msg = is_reality_spoof(ip, sni)
            if is_spoof:
                print(f"  {RED}[✖ 盲探识破] IP: {ip:<15} 宣称是 {sni}，但 {spoof_msg} (判定为套娃机)！{RESET}")
                continue

            return {
                "ip": ip,
                "rtt": round(total_rtt, 2),
                "sni": sni,
                "alpn": alpn,
                "issuer": issuer_org,
                "expire_date": expire_date.strftime('%Y-%m-%d'),
                "remaining_days": remaining_days
            }
        except Exception:
            try:
                s.close()
            except Exception:
                pass
            continue
    return None

def generate_subnets(base_ip):
    """由近到远生成物理网段 (/24 一路平滑扩展到 /16)"""
    base_obj = ipaddress.IPv4Address(base_ip)
    cidr_list = [24, 23, 22, 21, 20, 19, 18, 17, 16]
    for cidr in cidr_list:
        net = ipaddress.IPv4Network(f"{base_ip}/{cidr}", strict=False)
        yield f"/{cidr} 网段 (包含 {net.num_addresses} 个地址)", [str(ip) for ip in net.hosts() if ip != base_obj]

def print_result(idx, item):
    print(f"{BOLD}[{idx}] IP: {item['ip']}:443  (握手延迟: {item['rtt']} ms){RESET}")
    print(f"    - 推荐 SNI: {BOLD}{CYAN}{item['sni']}{RESET}")
    print(f"    - 协议/ALPN: {GREEN}TLSv1.3{RESET} | {item['alpn']}")
    print(f"    - 证书签发: {item['issuer']} (剩余: {item['remaining_days']} 天, 到期: {item['expire_date']})")
    print(f"    {YELLOW}------------------------------------------------------------{RESET}")
    print(f"    {BOLD}Sing-box 推荐配置:{RESET}")
    print(f'      "server_name": "{item["sni"]}",')
    print(f'      "reality": {{ "handshake": {{ "server": "{item["ip"]}", "server_port": 443 }} }}')
    print(f"    {YELLOW}------------------------------------------------------------{RESET}\n")

def main():
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}      REALITY TLS 1.3 精炼嗅探器 V8.0 (Bogus SNI Probe)         {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    my_ip = get_public_ip()
    if not my_ip:
        print(f"{RED}[!] 获取本机外网 IP 失败，请检查网络。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机公网 IP: {BOLD}{my_ip}{RESET} | 延迟阈值: <= {MAX_RTT}ms\n")

    scanned_ips = set()
    current_batch = []
    total_found = 0

    for layer_name, ip_list in generate_subnets(my_ip):
        # 严格过滤已扫 IP
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

        print(f"\n[*] 正在执行真实 SNI 握手与【伪造 SNI 盲探鉴伪】...")
        for probe_res in stage1_results:
            target = verify_target(probe_res)
            if target:
                current_batch.append(target)
                total_found += 1
                print(f"  {GREEN}[✓ 捕获真身] IP: {target['ip']:<15} | SNI: {target['sni']} | CA: {target['issuer']}{RESET}")

            # 凑满一批暂停并询问
            if len(current_batch) >= BATCH_SIZE:
                print(f"\n{CYAN}{BOLD}================================================================={RESET}")
                print(f"{CYAN}{BOLD}             🎉 成功捕获到 {len(current_batch)} 个真实可用目标                   {RESET}")
                print(f"{CYAN}{BOLD}================================================================={RESET}\n")

                current_batch.sort(key=lambda x: x["rtt"])
                for idx, item in enumerate(current_batch, 1):
                    print_result(idx, item)

                current_batch.clear()

                print(f"{BOLD}-----------------------------------------------------------------{RESET}")
                choice = input(f"👉 {GREEN}[满意请按 q 退出 | 不满意请直接回车 继续扩大范围深挖新目标]: {RESET}").strip().lower()
                print(f"{BOLD}-----------------------------------------------------------------{RESET}\n")
                if choice in ("q", "quit", "exit"):
                    print(f"{GREEN}[✓] 扫描已结束，感谢使用。{RESET}")
                    return

    print(f"\n{GREEN}[✓] 所有 /16 范围已全部探索完毕，累计找到 {total_found} 个可用真目标！{RESET}")

if __name__ == "__main__":
    main()
EOF_PYTHON
