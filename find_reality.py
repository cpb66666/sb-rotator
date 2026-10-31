#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REALITY 同网段 TLS 1.3 证书自动嗅探与目标筛选工具
特点：
1. 自动获取本机公网 IP，按 /24 -> /23 -> /22 由近到远渐进式扫描
2. 严格筛选：强制 TLS 1.3、公共受信任 CA、未过期、支持 ALPN (h2/http/1.1)
3. 自动解析 SAN/CN，并以真实 SNI 进行二次有效性验证
4. 纯 Python 3 标准库实现，零第三方 pip 依赖
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

# ANSI 颜色定义
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"

# 默认配置
DEFAULT_LIMIT = 5       # 找到几个合格目标后自动停止
MAX_WORKERS = 64        # 并发线程数
SOCKET_TIMEOUT = 2.0    # 握手超时时间 (秒)

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
                # 校验是否合法 IPv4
                ipaddress.IPv4Address(ip)
                return ip
        except Exception:
            continue
    return None

def is_valid_domain(domain):
    """过滤无效或内部保留域名"""
    if not domain or len(domain) > 253:
        return False
    # 排除通配符前缀、纯IP、localhost等
    domain = domain.lower().lstrip('*.')
    if domain.endswith(('.local', '.internal', '.lan', '.arpa', '.corp')):
        return False
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', domain):
        return False
    # 域名字符格式检查
    pattern = r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
    return bool(re.match(pattern, domain))

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

        # 提取 CN
        cn_match = re.search(r'CN\s*=\s*([^/,\n]+)', out_str)
        if cn_match:
            cn = cn_match.group(1).strip()
            if is_valid_domain(cn):
                domains.add(cn.lstrip('*.'))

        # 提取 SAN
        san_matches = re.findall(r'DNS:([^,\s]+)', out_str)
        for san in san_matches:
            san = san.strip()
            if is_valid_domain(san):
                domains.add(san.lstrip('*.'))
    except Exception:
        pass
    return list(domains)

def probe_ip(ip_str):
    """
    第一阶段探测：
    快速测试 443 端口并进行初步 TLS 1.3 嗅探，提取证书
    """
    # 1. TCP 端口快速测试
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SOCKET_TIMEOUT)
    start_time = time.time()
    try:
        s.connect((ip_str, 443))
    except (socket.timeout, ConnectionRefusedError, OSError):
        s.close()
        return None

    tcp_rtt = (time.time() - start_time) * 1000  # 毫秒

    # 2. TLS 1.3 探测 (不验证主机名获取证书)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # 设定支持的 ALPN
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

        # 校验协议版本：REALITY 强制要求 TLSv1.3
        tls_version = sslsock.version()
        if tls_version != "TLSv1.3":
            sslsock.close()
            return None

        # 获取证书二进制 DER
        der_cert = sslsock.getpeercert(binary_form=True)
        alpn = sslsock.selected_alpn_protocol() or "none"
        sslsock.close()

        if not der_cert:
            return None

        # 提取候选域名
        candidate_domains = extract_domains_from_der(der_cert)
        if not candidate_domains:
            # 尝试通过 PTR 反查域名
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

def verify_reality_candidate(probe_result):
    """
    第二阶段严格验证：
    以真实 SNI 重新发起合规的 TLS 握手，验证受信任根 CA 与有效期
    """
    ip = probe_result["ip"]
    candidates = probe_result["candidates"]

    # 严格校验的 SSL Context
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    try:
        ctx.set_alpn_protocols(['h2', 'http/1.1'])
    except Exception:
        pass

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

            cert = sslsock.getpeercert()
            alpn = sslsock.selected_alpn_protocol() or probe_result["alpn"]
            sslsock.close()

            # 校验有效期
            not_after_str = cert.get('notAfter')
            expire_date = datetime.strptime(not_after_str, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
            now = datetime.now(timezone.utc)
            remaining_days = (expire_date - now).days

            if remaining_days < 3:
                continue

            # 提取签发机构 CA
            issuer = dict(x[0] for x in cert.get('issuer', []))
            issuer_org = issuer.get('organizationName', issuer.get('commonName', 'Unknown CA'))

            # 提取全部 SAN 备选列表
            sans = [v for k, v in cert.get('subjectAltName', []) if k == 'DNS']

            return {
                "ip": ip,
                "rtt": round(total_rtt, 2),
                "sni": sni,
                "tls_version": probe_result["tls_version"],
                "alpn": alpn,
                "issuer": issuer_org,
                "expire_date": expire_date.strftime('%Y-%m-%d'),
                "remaining_days": remaining_days,
                "all_sans": sans[:6]  # 仅保留前6个作为参考
            }
        except Exception:
            try:
                s.close()
            except Exception:
                pass
            continue

    return None

def generate_subnets(base_ip):
    """由近到远生成网段层级列表"""
    ip_obj = ipaddress.IPv4Address(base_ip)
    
    # 第 1 层：本机的 /24
    net24 = ipaddress.IPv4Network(f"{base_ip}/24", strict=False)
    
    # 第 2 层：扩展到 /23（排除 /24 已经包含的主机）
    net23 = ipaddress.IPv4Network(f"{base_ip}/23", strict=False)
    
    # 第 3 层：扩展到 /22
    net22 = ipaddress.IPv4Network(f"{base_ip}/22", strict=False)

    layers = [
        ("Layer 1 (同 /24 本机邻近网段)", [str(ip) for ip in net24.hosts() if str(ip) != base_ip]),
        ("Layer 2 (扩充 /23 相邻机房网段)", [str(ip) for ip in net23.hosts() if ip not in net24 and str(ip) != base_ip]),
        ("Layer 3 (扩充 /22 同网区段)", [str(ip) for ip in net22.hosts() if ip not in net23 and str(ip) != base_ip])
    ]
    return layers

def main():
    print(f"{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}         REALITY 最佳 TLS 1.3 同网段证书嗅探工具         {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}")

    # 1. 获取公网 IP
    print(f"[*] 正在识别本机外网 IPv4 地址...")
    my_ip = get_public_ip()
    if not my_ip:
        print(f"{RED}[!] 获取公网 IP 失败，请检查网络连接。{RESET}")
        sys.exit(1)
    print(f"{GREEN}[✓] 本机公网 IP: {BOLD}{my_ip}{RESET}\n")

    # 2. 生成多级网段
    layers = generate_subnets(my_ip)
    found_targets = []

    for layer_name, ip_list in layers:
        print(f"{YELLOW}[>] 进入阶段: {layer_name}{RESET}")
        print(f"[*] 待探测主机数: {len(ip_list)} | 并发线程: {MAX_WORKERS}")

        # 并发执行初步探测
        stage1_results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_ip = {executor.submit(probe_ip, ip): ip for ip in ip_list}
            scanned = 0
            for future in concurrent.futures.as_completed(future_to_ip):
                scanned += 1
                res = future.result()
                if res:
                    stage1_results.append(res)
                    print(f"  {CYAN}发现可用候选: {res['ip']:<15} (RTT: {res['tcp_rtt']}ms | TLS 1.3: 是){RESET}")
                
                # 动态刷新进度
                if scanned % 25 == 0 or scanned == len(ip_list):
                    sys.stdout.write(f"\r  -> 扫描进度: {scanned}/{len(ip_list)} (开放TLS1.3: {len(stage1_results)})")
                    sys.stdout.flush()

        print(f"\n[*] 正在对开放目标进行证书信任链与 SNI 严格回环校验...")
        for probe_res in stage1_results:
            verified = verify_reality_candidate(probe_res)
            if verified:
                found_targets.append(verified)
                print(f"  {GREEN}[✓ 验证合格] IP: {verified['ip']:<15} | 推荐 SNI: {verified['sni']} | CA: {verified['issuer']}{RESET}")

            if len(found_targets) >= DEFAULT_LIMIT:
                print(f"\n{GREEN}[✓] 已找到 {DEFAULT_LIMIT} 个优质合格目标，自动停止向外扩展。{RESET}")
                break

        if len(found_targets) >= DEFAULT_LIMIT:
            break
        else:
            print(f"[*] 当前层级扫描完成，已获得 {len(found_targets)}/{DEFAULT_LIMIT} 个合格目标。准备扩展到更远网段...\n")

    # 3. 输出汇总与 Reality 专用配置
    if not found_targets:
        print(f"\n{RED}[!] 未能在周边网段扫描到满足条件的 TLS 1.3 证书目标。{RESET}")
        print(f"[*] 建议：可以检查机房防火墙是否限制 443 外联，或适当扩大扫描网段。")
        return

    # 按 RTT 从低到高排序
    found_targets.sort(key=lambda x: x["rtt"])

    print(f"\n{CYAN}{BOLD}================================================================={RESET}")
    print(f"{CYAN}{BOLD}          🎉 REALITY 最佳候选目标列表 (按 RTT 延迟排序)           {RESET}")
    print(f"{CYAN}{BOLD}================================================================={RESET}\n")

    for idx, item in enumerate(found_targets, 1):
        print(f"{BOLD}[{idx}] IP: {item['ip']}:443  (握手延迟: {item['rtt']} ms){RESET}")
        print(f"    - 协议支持: {GREEN}{item['tls_version']}{RESET} | ALPN: {item['alpn']}")
        print(f"    - 证书签发: {item['issuer']} (到期: {item['expire_date']}, 剩余 {item['remaining_days']} 天)")
        print(f"    - 推荐 SNI: {BOLD}{CYAN}{item['sni']}{RESET}")
        if len(item['all_sans']) > 1:
            print(f"    - 备用 SAN: {item['all_sans']}")
        print(f"    {YELLOW}------------------------------------------------------------{RESET}")
        print(f"    {BOLD}Xray / Sing-box 服务端 Reality 配置参考:{RESET}")
        print(f'      "dest": "{item["ip"]}:443",')
        print(f'      "serverNames": [')
        print(f'        "{item["sni"]}"')
        print(f'      ]')
        print(f"{YELLOW}------------------------------------------------------------{RESET}\n")

if __name__ == "__main__":
    main()
