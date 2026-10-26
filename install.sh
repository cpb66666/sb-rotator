#!/usr/bin/env bash
# ==============================================================================
# install.sh - 233boy/sing-box 面板动态合租同步 & Clash API 多IP/动态流量共享限速 一键安装脚本 (v3.1.2)
# 使用方式:
#   bash <(curl -fsSL https://raw.githubusercontent.com/cpb66666/zidonghuanmi/main/install.sh)
# ==============================================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GITHUB_RAW_BASE_URL=""

INSTALL_BIN="/usr/local/bin/sb-rotator"
ALIAS_BIN="/usr/local/bin/sbr"
INSTALL_DIR="/etc/sb-rotator"

prompt_read() {
    local prompt_str="$1" var_name="$2"
    if [[ -t 0 ]]; then
        read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]] && { true < /dev/tty; } 2>/dev/null; then
        read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else
        read -rp "${prompt_str}" "${var_name}" || return 1
    fi
}

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        echo -e "${RED}[错误] 请使用 root 用户运行此脚本 (sudo -i)${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl sed awk grep timeout jq python3 tc ip; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${YELLOW}[提示] 正在安装必要系统组件 (${missing[*]}) ...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl sed gawk grep util-linux coreutils openssl ca-certificates jq python3 iproute2 iptables tzdata >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl sed gawk grep util-linux coreutils openssl ca-certificates jq python3 iproute iptables tzdata >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl sed gawk grep util-linux coreutils openssl ca-certificates jq python3 iproute2 iptables tzdata >/dev/null 2>&1
        fi
    fi
}

deploy_core_script() {
    mkdir -p "${INSTALL_DIR}"
    if [[ -n "${GITHUB_RAW_BASE_URL}" ]]; then
        if curl -fsSL --connect-timeout 10 "${GITHUB_RAW_BASE_URL%/}/sb-rotator.sh" -o "${INSTALL_BIN}"; then
            chmod +x "${INSTALL_BIN}"
            ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
            return 0
        fi
    fi

    cat > "${INSTALL_BIN}" <<'__EOF_SB_ROTATOR_CORE__'
#!/usr/bin/env bash
# ==============================================================================
# sb-rotator.sh - 233boy/sing-box 面板动态合租同步 & Clash API 多IP/动态流量限速系统 (v3.1.2)
# 核心能力:
#   1. 自动扫描 /etc/sing-box/conf/*.json，提取管理员默认链接并通过 POST /api/v1/server/register 上报注册
#   2. 同步响应 & Push 回调监听 (POST /api/v1/sync): 按协议 cred_type (uuid/password) 动态注入/移除合租用户，保留管理员默认账号
#   3. 自动开启内置 Clash API (127.0.0.1:9090) + 注入 auth_user 路由标记，完整保留原 DNS 配置
#   4. 双重共享限速引擎 (Linux TC HTB + fq_codel):
#      - 多IP共享限速: 实时监控各用户名活跃源 IP 数量，超阈值时将该用户所有源 IP 加入共享限速池
#      - 动态流量限速: 滑动时间窗口内累计流量超阈值时，自动触发指定时长的共享带宽限速
#   5. 支持交互式修改所有限速参数，并实时检验 Clash API、路由规则与内核 TC 限速队列是否真实生效
# ==============================================================================

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="3.1.2"
INSTALL_DIR="${INSTALL_DIR:-/etc/sb-rotator}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_DIR}/config.env}"
ADMIN_ACCOUNTS_FILE="${ADMIN_ACCOUNTS_FILE:-${INSTALL_DIR}/admin_accounts.json}"
ACTIVE_USERS_FILE="${ACTIVE_USERS_FILE:-${INSTALL_DIR}/active_users.json}"
RUNTIME_STATUS_FILE="${RUNTIME_STATUS_FILE:-${INSTALL_DIR}/runtime_status.json}"
TRAFFIC_STATE_FILE="${TRAFFIC_STATE_FILE:-${INSTALL_DIR}/traffic_window.json}"
DAEMON_SCRIPT="${DAEMON_SCRIPT:-${INSTALL_DIR}/sb_agent_daemon.py}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/sb-agent.service}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
CACHE_DIR="${CACHE_DIR:-${INSTALL_DIR}/cache}"
LOG_FILE="${LOG_FILE:-/var/log/sb-rotator.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/sb-rotator.lock}"
OLD_CRON_FILE="/etc/cron.d/sb-rotator"
SB_CONF_DIR="${SB_CONF_DIR:-/etc/sing-box/conf}"
SB_GLOBAL_CONFIG="${SB_GLOBAL_CONFIG:-/etc/sing-box/config.json}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# 基础工具函数
# ==============================================================================

now_beijing() { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }

log_msg() {
    local level="$1"; shift
    echo "[$(now_beijing) CST] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

info() { echo -e "${GREEN}[INFO]${NC} $*"; log_msg "INFO" "$*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; log_msg "WARN" "$*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; log_msg "ERROR" "$*"; }
step() { echo -e "${CYAN}[STEP]${NC} $*"; log_msg "STEP" "$*"; }

prompt_read() {
    local prompt_str="$1" var_name="$2"
    if [[ -t 0 ]]; then
        read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]] && { true < /dev/tty; } 2>/dev/null; then
        read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else
        read -rp "${prompt_str}" "${var_name}" || return 1
    fi
}

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'; }

ensure_dirs() {
    mkdir -p "${INSTALL_DIR}" "${BACKUP_DIR}" "${CACHE_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
    [[ ! -f "${ADMIN_ACCOUNTS_FILE}" ]] && echo "{}" > "${ADMIN_ACCOUNTS_FILE}" 2>/dev/null || true
    [[ ! -f "${ACTIVE_USERS_FILE}" ]] && echo "[]" > "${ACTIVE_USERS_FILE}" 2>/dev/null || true
    [[ ! -f "${RUNTIME_STATUS_FILE}" ]] && echo "{}" > "${RUNTIME_STATUS_FILE}" 2>/dev/null || true
    chmod 600 "${CONFIG_FILE}" "${ADMIN_ACCOUNTS_FILE}" 2>/dev/null || true
    if [[ -f "${OLD_CRON_FILE}" ]]; then
        rm -f "${OLD_CRON_FILE}" 2>/dev/null || true
        systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
    fi
}

find_sb_bin() {
    [[ -n "${SB_BIN:-}" && -x "${SB_BIN}" ]] && { echo "${SB_BIN}"; return 0; }
    local c
    for c in /usr/local/bin/sing-box /usr/local/bin/sb /etc/sing-box/sh/sing-box.sh /usr/bin/sing-box; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    command -v sing-box 2>/dev/null || command -v sb 2>/dev/null || return 1
}

run_sb_cmd_idx() {
    local default_idx="$1" timeout_sec="$2"; shift 2
    local sb_bin; sb_bin="$(find_sb_bin)" || return 1
    if command -v timeout >/dev/null 2>&1; then
        printf '%s\n' "${default_idx}" | COLUMNS=1 timeout "${timeout_sec}" "${sb_bin}" "$@" 2>&1 | strip_ansi
    else
        printf '%s\n' "${default_idx}" | COLUMNS=1 "${sb_bin}" "$@" 2>&1 | strip_ansi
    fi
}

run_sb_cmd() { local t="$1"; shift; run_sb_cmd_idx "1" "$t" "$@"; }

get_server_ip() {
    local ip=""
    ip="$(run_sb_cmd 5 ip 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    [[ -z "${ip}" ]] && ip="$(curl -fsSL4 --connect-timeout 4 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -z "${ip}" ]] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
    [[ -z "${ip}" ]] && ip="127.0.0.1"
    echo "${ip}"
}

get_default_iface() {
    local iface=""
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    [[ -z "${iface}" ]] && iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" && $2 !~ /^docker|^veth|^br-|^tun|^wg/ {print $2; exit}')"
    echo "${iface:-eth0}"
}

list_available_ifaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{split($2,a,"@"); if(a[1]!="lo") print a[1]}' | tr '\n' ' '
}

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_pos_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($1 > 0)}"; }

# ==============================================================================
# 配置加载与保存
# ==============================================================================

load_config() {
    PANEL_URL=""
    API_KEY=""
    SERVER_ID="1"
    AGENT_PORT="18080"
    AGENT_URL=""
    CLASH_API_PORT="9090"
    CLASH_API_SECRET=""
    IP_LIMIT_ENABLE="true"
    IP_THRESHOLD="2"
    LIMIT_MBPS="10"
    CHECK_INTERVAL="5"
    ACTIVE_WINDOW_SEC="15"
    LIMIT_ADMIN="false"
    DYN_LIMIT_ENABLE="true"
    DYN_WINDOW_MIN="40"
    DYN_THRESHOLD_GB="2.5"
    DYN_LIMIT_MBPS="10"
    DYN_LIMIT_MIN="60"
    NET_IFACE=""
    [[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"
    [[ -z "${NET_IFACE}" ]] && NET_IFACE="$(get_default_iface)"
    if [[ -z "${AGENT_URL}" ]]; then
        local srv_ip
        srv_ip="$(get_server_ip)"
        AGENT_URL="http://${srv_ip}:${AGENT_PORT:-18080}/api/v1/sync"
    fi
}

save_config() {
    ensure_dirs
    cat > "${CONFIG_FILE}" <<EOF
# sb-rotator v3.1.2 配置文件 (面板同步 + Clash API 多IP与动态流量限速)
PANEL_URL="${PANEL_URL}"
API_KEY="${API_KEY}"
SERVER_ID="${SERVER_ID:-1}"
AGENT_PORT="${AGENT_PORT:-18080}"
AGENT_URL="${AGENT_URL}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"
CLASH_API_SECRET="${CLASH_API_SECRET:-}"
IP_LIMIT_ENABLE="${IP_LIMIT_ENABLE:-true}"
IP_THRESHOLD="${IP_THRESHOLD:-2}"
LIMIT_MBPS="${LIMIT_MBPS:-10}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
ACTIVE_WINDOW_SEC="${ACTIVE_WINDOW_SEC:-15}"
LIMIT_ADMIN="${LIMIT_ADMIN:-false}"
DYN_LIMIT_ENABLE="${DYN_LIMIT_ENABLE:-true}"
DYN_WINDOW_MIN="${DYN_WINDOW_MIN:-40}"
DYN_THRESHOLD_GB="${DYN_THRESHOLD_GB:-2.5}"
DYN_LIMIT_MBPS="${DYN_LIMIT_MBPS:-10}"
DYN_LIMIT_MIN="${DYN_LIMIT_MIN:-60}"
NET_IFACE="${NET_IFACE:-$(get_default_iface)}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

get_register_endpoint() {
    local url="${PANEL_URL%/}"
    [[ -z "${url}" ]] && return 1
    if [[ "${url}" =~ /api/v1/(server|node)/register$ ]]; then
        echo "${url}"
    elif [[ "${url}" =~ ^https?://[^/]+$ ]]; then
        echo "${url}/api/v1/server/register"
    else
        url="$(echo "${url}" | sed -E 's|/api/v1/node/rotate$||')"
        echo "${url%/}/api/v1/server/register"
    fi
}

# ==============================================================================
# 服务安全重启 (保留 /etc/sing-box/config.json 中的 DNS 设置，严禁调用 fix-config.json)
# ==============================================================================

reload_singbox_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl restart sing-box >/dev/null 2>&1 || true
        sleep 1
        if ! systemctl is-active --quiet sing-box; then
            err "sing-box 服务重启失败，请检查日志！"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service sing-box restart >/dev/null 2>&1 || true
    else
        run_sb_cmd 10 restart >/dev/null 2>&1 || true
    fi
    info "sing-box 服务已平滑重启生效 (保留原 DNS 与全局配置)"
    return 0
}

# ==============================================================================
# 释放内置 Python 守护核心 (处理协议发现、注册、Push 回调、Clash API 配置与 TC 限速)
# ==============================================================================

write_python_daemon() {
    ensure_dirs
    cat > "${DAEMON_SCRIPT}" <<'__EOF_PY_DAEMON__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sb_agent_daemon.py - 233boy/sing-box 节点注册、Push 同步回调与 Clash API 多IP/动态流量限速守护进程 (v3.1.2)
"""

import os
import re
import sys
import json
import time
import hmac
import shlex
import socket
import hashlib
import logging
import threading
import subprocess
import urllib.request
import urllib.error
import urllib.parse
import socketserver
from http.server import HTTPServer, BaseHTTPRequestHandler


class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "sb-agent"
        self.server_port = self.server_address[1]

DAEMON_VERSION = "3.1.2"
INSTALL_DIR = os.environ.get("INSTALL_DIR", "/etc/sb-rotator")
CONFIG_FILE = os.environ.get("CONFIG_FILE", os.path.join(INSTALL_DIR, "config.env"))
ADMIN_ACCOUNTS_FILE = os.environ.get("ADMIN_ACCOUNTS_FILE", os.path.join(INSTALL_DIR, "admin_accounts.json"))
ACTIVE_USERS_FILE = os.environ.get("ACTIVE_USERS_FILE", os.path.join(INSTALL_DIR, "active_users.json"))
RUNTIME_STATUS_FILE = os.environ.get("RUNTIME_STATUS_FILE", os.path.join(INSTALL_DIR, "runtime_status.json"))
TRAFFIC_STATE_FILE = os.environ.get("TRAFFIC_STATE_FILE", os.path.join(INSTALL_DIR, "traffic_window.json"))
CACHE_DIR = os.environ.get("CACHE_DIR", os.path.join(INSTALL_DIR, "cache"))
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/sb-rotator.log")
SB_CONF_DIR = os.environ.get("SB_CONF_DIR", "/etc/sing-box/conf")
SB_GLOBAL_CONFIG = os.environ.get("SB_GLOBAL_CONFIG", "/etc/sing-box/config.json")

SYNC_LOCK = threading.Lock()
LIMIT_LOCK = threading.Lock()
ANSI_RE = re.compile(r"\x1B\[[0-9;]*[a-zA-Z]|\r")
PROXY_URL_RE = re.compile(
    r"((?:vless|vmess|trojan|hysteria2|hy2|tuic|ss|shadowsocks|anytls|socks5?|hysteria)://[^\s\"']+)",
    re.IGNORECASE,
)
AD_BLACKLIST_RE = re.compile(r"(getjms\.com|233boy\.com|github\.com|t\.me)", re.IGNORECASE)
AUTH_USER_RULE_RE = re.compile(r"auth_user=\[?([^\s\]=>,]+)")

# 协议封装开销补偿系数:
# Linux TC 在网卡出方向按二/三层原始报文(含 Ethernet + IP + TCP/UDP + TLS/VLESS/Hysteria2 头部及上行 ACK)整形，
# 补偿 15% 协议头与重传开销，使客户端测速应用层真实速度稳定对齐设定的 Mbps 数值。
TC_OVERHEAD_FACTOR = 1.15

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
NC = "\033[0m"


def now_cst_str(ts=None):
    t = ts if ts is not None else time.time()
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t + 8 * 3600))


def log(level, msg):
    line = f"[{now_cst_str()} CST] [{level}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_env_config():
    cfg = {
        "PANEL_URL": "",
        "API_KEY": "",
        "SERVER_ID": "1",
        "AGENT_PORT": "18080",
        "AGENT_URL": "",
        "CLASH_API_PORT": "9090",
        "CLASH_API_SECRET": "",
        "IP_LIMIT_ENABLE": "true",    # 多IP共享限速开关
        "IP_THRESHOLD": "2",          # 触发限速的活跃源IP数量阈值
        "LIMIT_MBPS": "10",           # 多IP触发限速后的共享带宽(Mbps)
        "CHECK_INTERVAL": "5",        # Clash API 轮询间隔(秒)
        "ACTIVE_WINDOW_SEC": "15",    # 源IP活跃判定时间窗口(秒)
        "LIMIT_ADMIN": "false",       # 是否对管理员默认账号限速
        "NET_IFACE": "",              # 限速绑定物理网卡
        "DYN_LIMIT_ENABLE": "true",   # 动态流量限速开关
        "DYN_WINDOW_MIN": "40",       # 流量统计滑动时间窗口(分钟)
        "DYN_THRESHOLD_GB": "2.5",    # 窗口内用户累计总流量阈值(GB)
        "DYN_LIMIT_MBPS": "10",       # 动态流量触发后的共享带宽(Mbps)
        "DYN_LIMIT_MIN": "60",        # 动态流量触发后的限速持续时间(分钟)
    }
    if os.path.isfile(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    cfg[k] = v
        except Exception as e:
            log("WARN", f"读取配置文件失败: {e}")
    if not cfg.get("NET_IFACE"):
        cfg["NET_IFACE"] = detect_default_iface()
    if not cfg.get("AGENT_URL"):
        ip = get_server_ip()
        cfg["AGENT_URL"] = f"http://{ip}:{cfg.get('AGENT_PORT', '18080')}/api/v1/sync"
    return cfg


def load_json_file(path, default):
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return default


def save_json_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def find_sb_bin():
    env_bin = os.environ.get("SB_BIN")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin
    for c in ("/usr/local/bin/sing-box", "/usr/local/bin/sb", "/etc/sing-box/sh/sing-box.sh", "/usr/bin/sing-box"):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "sing-box"


def run_sb_cmd(args, idx=1, timeout_sec=6):
    sb_bin = find_sb_bin()
    env = os.environ.copy()
    env["COLUMNS"] = "1"
    try:
        p = subprocess.run(
            [sb_bin] + list(args),
            input=f"{idx}\n",
            text=True,
            capture_output=True,
            timeout=timeout_sec,
            env=env,
        )
        out = (p.stdout or "") + "\n" + (p.stderr or "")
        return ANSI_RE.sub("", out)
    except Exception:
        return ""


def get_server_ip():
    out = run_sb_cmd(["ip"], idx=1, timeout_sec=5)
    m = re.search(r"((?:\d{1,3}\.){3}\d{1,3})", out)
    if m:
        return m.group(1)
    for url in ("https://icanhazip.com", "https://api.ipify.org"):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                ip = resp.read().decode("utf-8", errors="ignore").strip()
                if re.match(r"^(?:\d{1,3}\.){3}\d{1,3}$", ip):
                    return ip
        except Exception:
            pass
    try:
        out = subprocess.check_output(["ip", "-4", "route", "get", "1.1.1.1"], text=True, timeout=3)
        m = re.search(r"src\s+((?:\d{1,3}\.){3}\d{1,3})", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    return "127.0.0.1"


def detect_default_iface():
    try:
        out = subprocess.check_output(["ip", "-o", "-4", "route", "show", "to", "default"], text=True, timeout=3)
        parts = out.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    except Exception:
        pass
    try:
        out = subprocess.check_output(["ip", "-o", "link", "show"], text=True, timeout=3)
        for line in out.splitlines():
            parts = line.split(": ")
            if len(parts) >= 2:
                name = parts[1].split("@")[0].strip()
                if name != "lo" and not re.match(r"^(docker|veth|br-|tun|wg)", name):
                    return name
    except Exception:
        pass
    return "eth0"


def normalize_protocol_info(inbound_type, shortname, first_user):
    raw = (inbound_type or "").lower().strip()
    if not raw:
        raw = re.sub(r"-\d+$", "", shortname).lower()
    if "vless" in raw or "reality" in raw:
        proto = "vless"
    elif "hysteria2" in raw or raw == "hy2" or raw == "hy":
        proto = "hysteria2"
    elif "anytls" in raw:
        proto = "anytls"
    elif "trojan" in raw:
        proto = "trojan"
    elif "vmess" in raw:
        proto = "vmess"
    elif "tuic" in raw:
        proto = "tuic"
    elif "shadowsocks" in raw or raw == "ss":
        proto = "ss"
    else:
        proto = raw or "vless"

    if isinstance(first_user, dict) and "uuid" in first_user:
        cred_type = "uuid"
    elif isinstance(first_user, dict) and "password" in first_user:
        cred_type = "password"
    elif proto in ("vless", "vmess", "tuic"):
        cred_type = "uuid"
    else:
        cred_type = "password"

    tag = proto.upper()
    return proto, cred_type, tag


def extract_proxy_url(text):
    for m in PROXY_URL_RE.finditer(text or ""):
        u = m.group(1)
        if not AD_BLACKLIST_RE.search(u):
            return u
    return ""


def build_fallback_url(proto, port, cred, shortname, inbound, srv_ip):
    tls = inbound.get("tls") or {}
    sni = tls.get("server_name") or ""
    users = inbound.get("users") or [{}]
    first_u = users[0] if users else {}
    flow = first_u.get("flow") or ""
    if proto == "anytls":
        q = f"security=tls&sni={sni}&insecure=1" if sni else "security=tls&insecure=1"
        return f"anytls://{cred}@{srv_ip}:{port}?{q}#{shortname}"
    elif proto in ("hysteria2", "hy2"):
        return f"hysteria2://{cred}@{srv_ip}:{port}?alpn=h3&insecure=1&sni={sni or 'www.bing.com'}#{shortname}"
    elif proto == "vless":
        q = f"encryption=none{f'&flow={flow}' if flow else ''}&security=tls{f'&sni={sni}' if sni else ''}"
        return f"vless://{cred}@{srv_ip}:{port}?{q}#{shortname}"
    elif proto == "trojan":
        return f"trojan://{cred}@{srv_ip}:{port}?security=tls{f'&sni={sni}' if sni else ''}#{shortname}"
    return f"{proto}://{cred}@{srv_ip}:{port}#{shortname}"


def discover_and_get_default_protocols():
    if not os.path.isdir(SB_CONF_DIR):
        return [], []

    files = sorted([f for f in os.listdir(SB_CONF_DIR) if f.endswith(".json")])
    admin_accounts = load_json_file(ADMIN_ACCOUNTS_FILE, {})
    srv_ip = get_server_ip()
    protocols_list = []
    default_links = []
    admin_changed = False

    for idx, fname in enumerate(files, start=1):
        fpath = os.path.join(SB_CONF_DIR, fname)
        shortname = fname[:-5]
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                conf = json.load(f)
        except Exception as e:
            log("WARN", f"解析节点配置文件 {fname} 失败: {e}")
            continue

        inbounds = conf.get("inbounds") or []
        if not inbounds or not isinstance(inbounds[0], dict):
            continue
        ib = inbounds[0]
        port = int(ib.get("listen_port") or 0)
        if not port:
            m = re.search(r"-(\d+)$", shortname)
            if m:
                port = int(m.group(1))

        users = ib.get("users") or []
        first_user = users[0] if (users and isinstance(users[0], dict)) else {}
        proto, cred_type, tag = normalize_protocol_info(ib.get("type"), shortname, first_user)

        saved = admin_accounts.get(fname) or {}
        admin_cred = saved.get("credential")
        extra_fields = saved.get("extra")
        if not admin_cred:
            admin_cred = first_user.get(cred_type) or first_user.get("uuid") or first_user.get("password") or ""
            extra_fields = {
                k: v for k, v in first_user.items() if k not in ("name", "uuid", "password")
            }
            admin_accounts[fname] = {
                "protocol": proto,
                "port": port,
                "cred_type": cred_type,
                "credential": admin_cred,
                "extra": extra_fields,
                "default_url": "",
            }
            admin_changed = True
        else:
            if extra_fields is None:
                extra_fields = {
                    k: v for k, v in first_user.items() if k not in ("name", "uuid", "password")
                }

        default_url = saved.get("default_url") or ""
        if not default_url:
            orig_users = ib.get("users")
            need_temp_single = isinstance(orig_users, list) and len(orig_users) > 1
            try:
                if need_temp_single:
                    single_admin = dict(extra_fields or {})
                    single_admin[cred_type] = admin_cred
                    ib["users"] = [single_admin]
                    save_json_file(fpath, conf)

                for cmd_args in (["url", shortname], ["url", str(port)], ["info", shortname]):
                    out = run_sb_cmd(cmd_args, idx=idx, timeout_sec=5)
                    default_url = extract_proxy_url(out)
                    if default_url:
                        break
            finally:
                if need_temp_single:
                    ib["users"] = orig_users
                    save_json_file(fpath, conf)

        if not default_url:
            default_url = saved.get("default_url") or build_fallback_url(proto, port, admin_cred, shortname, ib, srv_ip)

        if admin_cred and proto != "vmess":
            default_url = re.sub(r"^([a-zA-Z0-9]+://)[^@]+@", rf"\g<1>{admin_cred}@", default_url)

        if admin_accounts.get(fname, {}).get("default_url") != default_url:
            admin_accounts.setdefault(fname, {})["default_url"] = default_url
            admin_changed = True

        default_links.append(default_url)
        protocols_list.append({
            "protocol": proto,
            "port": port,
            "tag": tag,
            "cred_type": cred_type,
            "default_url": default_url,
            "config_name": fname,
        })

    if admin_changed:
        save_json_file(ADMIN_ACCOUNTS_FILE, admin_accounts)

    return default_links, protocols_list


def ensure_clash_api_and_user_routes(active_emails, cfg):
    clash_port = cfg.get("CLASH_API_PORT", "9090")
    clash_secret = cfg.get("CLASH_API_SECRET", "")
    controller_addr = f"127.0.0.1:{clash_port}"

    global_conf = load_json_file(SB_GLOBAL_CONFIG, {})
    if not isinstance(global_conf, dict):
        global_conf = {}

    orig_serialized = json.dumps(global_conf, sort_keys=True, ensure_ascii=False)

    outbounds = global_conf.get("outbounds")
    if not isinstance(outbounds, list) or len(outbounds) == 0:
        outbounds = [{"type": "direct", "tag": "direct"}]
        global_conf["outbounds"] = outbounds
    if not isinstance(outbounds[0], dict):
        outbounds[0] = {"type": "direct", "tag": "direct"}
    if not outbounds[0].get("tag"):
        outbounds[0]["tag"] = outbounds[0].get("type") or "direct"
    default_out_tag = outbounds[0]["tag"]

    exp = global_conf.get("experimental")
    if not isinstance(exp, dict):
        exp = {}
        global_conf["experimental"] = exp
    clash_api = exp.get("clash_api")
    if not isinstance(clash_api, dict):
        clash_api = {}
        exp["clash_api"] = clash_api
    clash_api["external_controller"] = controller_addr
    if clash_secret:
        clash_api["secret"] = clash_secret

    route = global_conf.get("route")
    if not isinstance(route, dict):
        route = {}
        global_conf["route"] = route
    existing_rules = route.get("rules")
    if not isinstance(existing_rules, list):
        existing_rules = []

    preserved_rules = []
    for r in existing_rules:
        if not isinstance(r, dict):
            continue
        keys = set(r.keys())
        if keys in ({"auth_user", "outbound"}, {"auth_user", "action", "outbound"}):
            continue
        preserved_rules.append(r)

    user_rules = []
    seen_emails = set()
    for email in ["admin"] + list(active_emails):
        email = str(email).strip()
        if not email or email in seen_emails:
            continue
        seen_emails.add(email)
        user_rules.append({
            "auth_user": [email],
            "outbound": default_out_tag,
        })

    route["rules"] = preserved_rules + user_rules

    new_serialized = json.dumps(global_conf, sort_keys=True, ensure_ascii=False)
    if new_serialized != orig_serialized:
        save_json_file(SB_GLOBAL_CONFIG, global_conf)
        return True
    return False


RELOAD_LOCK = threading.Lock()
RELOAD_PENDING = False


def reload_singbox():
    with RELOAD_LOCK:
        try:
            if os.path.isdir("/run/systemd/system"):
                subprocess.run(["systemctl", "restart", "sing-box"], timeout=15, check=False)
                time.sleep(0.5)
                res = subprocess.run(["systemctl", "is-active", "--quiet", "sing-box"], timeout=5)
                if res.returncode != 0:
                    log("ERROR", "sing-box 服务重启后未处于 active 状态！")
                    return False
                log("INFO", "sing-box 服务已平滑重启生效 (保留原 DNS 与 Clash API 配置)")
                return True
        except Exception as e:
            log("ERROR", f"重启 sing-box 异常: {e}")
        run_sb_cmd(["restart"], idx=1, timeout_sec=10)
        return True


def schedule_singbox_reload():
    def _worker():
        try:
            reload_singbox()
        except Exception as e:
            log("ERROR", f"异步重启 sing-box 失败: {e}")

    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def ensure_admin_accounts_fast():
    """
    纯内存/文件级毫秒级初始化管理员默认凭据 (不调用耗时的 sing-box url 子进程)，
    供 /api/v1/sync Push 接口高速处理使用，避免阻塞面板 HTTP 请求导致超时。
    """
    if not os.path.isdir(SB_CONF_DIR):
        return {}
    files = sorted([f for f in os.listdir(SB_CONF_DIR) if f.endswith(".json")])
    admin_accounts = load_json_file(ADMIN_ACCOUNTS_FILE, {})
    changed = False
    for fname in files:
        saved = admin_accounts.get(fname)
        if isinstance(saved, dict) and saved.get("credential"):
            continue
        fpath = os.path.join(SB_CONF_DIR, fname)
        shortname = fname[:-5]
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                conf = json.load(f)
        except Exception:
            continue
        inbounds = conf.get("inbounds") or []
        if not inbounds or not isinstance(inbounds[0], dict):
            continue
        ib = inbounds[0]
        port = int(ib.get("listen_port") or 0)
        users = ib.get("users") or []
        first_user = users[0] if (users and isinstance(users[0], dict)) else {}
        proto, cred_type, _ = normalize_protocol_info(ib.get("type"), shortname, first_user)
        admin_cred = first_user.get(cred_type) or first_user.get("uuid") or first_user.get("password") or ""
        extra_fields = {k: v for k, v in first_user.items() if k not in ("name", "uuid", "password")}
        admin_accounts[fname] = {
            "protocol": proto,
            "port": port,
            "cred_type": cred_type,
            "credential": admin_cred,
            "extra": extra_fields,
            "default_url": (saved or {}).get("default_url", ""),
        }
        changed = True
    if changed:
        save_json_file(ADMIN_ACCOUNTS_FILE, admin_accounts)
    return admin_accounts


def sync_users_to_singbox(payload_data, cfg=None, async_reload=False):
    with SYNC_LOCK:
        if cfg is None:
            cfg = load_env_config()

        data_block = payload_data.get("data") if isinstance(payload_data.get("data"), dict) else payload_data
        if not isinstance(data_block, dict):
            return False, "invalid payload format", 0

        raw_users = data_block.get("users")
        if raw_users is None:
            raw_users = []
        if not isinstance(raw_users, list):
            return False, "users field must be a list", 0

        raw_protocols = data_block.get("protocols") or []
        proto_cred_map = {}
        if isinstance(raw_protocols, list):
            for p in raw_protocols:
                if isinstance(p, dict):
                    p_name = str(p.get("protocol") or "").lower().strip()
                    p_port = int(p.get("port") or 0)
                    c_type = str(p.get("cred_type") or "").lower().strip()
                    if c_type in ("uuid", "password"):
                        if p_name and p_port:
                            proto_cred_map[f"{p_name}:{p_port}"] = c_type
                        if p_name:
                            proto_cred_map[p_name] = c_type

        admin_accounts = ensure_admin_accounts_fast()

        now_ts = int(time.time())
        valid_users = []
        active_emails = []
        for u in raw_users:
            if not isinstance(u, dict):
                continue
            exp = int(u.get("expire_at") or u.get("expires_at") or 0)
            if exp > 0 and exp <= now_ts:
                continue
            email = str(u.get("email") or u.get("name") or f"sub_{u.get('subscription_id', '')}").strip()
            if not email:
                continue
            valid_users.append({
                "subscription_id": u.get("subscription_id", 0),
                "email": email,
                "uuid": str(u.get("uuid") or "").strip(),
                "password": str(u.get("password") or "").strip(),
                "expire_at": exp,
                "speed_limit_bps": int(u.get("speed_limit_bps") or 0),
            })
            active_emails.append(email)

        save_json_file(ACTIVE_USERS_FILE, valid_users)

        any_conf_changed = False
        files = sorted([f for f in os.listdir(SB_CONF_DIR) if f.endswith(".json")]) if os.path.isdir(SB_CONF_DIR) else []

        for fname in files:
            fpath = os.path.join(SB_CONF_DIR, fname)
            shortname = fname[:-5]
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    conf = json.load(f)
            except Exception:
                continue

            inbounds = conf.get("inbounds") or []
            if not inbounds or not isinstance(inbounds[0], dict):
                continue
            ib = inbounds[0]
            port = int(ib.get("listen_port") or 0)
            users_orig = ib.get("users") or []
            first_u = users_orig[0] if (users_orig and isinstance(users_orig[0], dict)) else {}
            proto, detected_cred_type, _ = normalize_protocol_info(ib.get("type"), shortname, first_u)

            cred_type = (
                proto_cred_map.get(f"{proto}:{port}")
                or proto_cred_map.get(proto)
                or detected_cred_type
            )

            saved_admin = admin_accounts.get(fname) or {}
            admin_cred = saved_admin.get("credential") or first_u.get(cred_type) or first_u.get("uuid") or first_u.get("password") or ""
            extra_fields = saved_admin.get("extra")
            if extra_fields is None:
                extra_fields = {k: v for k, v in first_u.items() if k not in ("name", "uuid", "password")}

            new_users_arr = []
            admin_obj = dict(extra_fields)
            admin_obj["name"] = "admin"
            admin_obj[cred_type] = admin_cred
            if proto == "tuic" and "password" not in admin_obj:
                admin_obj["password"] = first_u.get("password") or admin_cred
            new_users_arr.append(admin_obj)

            seen_creds = {admin_cred}
            seen_names = {"admin"}

            for u in valid_users:
                email = u["email"]
                cred_val = u["uuid"] if cred_type == "uuid" else u["password"]
                if not cred_val or email in seen_names or cred_val in seen_creds:
                    continue
                u_obj = dict(extra_fields)
                u_obj["name"] = email
                u_obj[cred_type] = cred_val
                if proto == "tuic":
                    u_obj["uuid"] = u["uuid"] or admin_cred
                    u_obj["password"] = u["password"] or u_obj.get("password") or admin_cred
                new_users_arr.append(u_obj)
                seen_names.add(email)
                seen_creds.add(cred_val)

            if json.dumps(ib.get("users"), sort_keys=True, ensure_ascii=False) != json.dumps(new_users_arr, sort_keys=True, ensure_ascii=False):
                ib["users"] = new_users_arr
                save_json_file(fpath, conf)
                any_conf_changed = True

        global_changed = ensure_clash_api_and_user_routes(active_emails, cfg)
        need_reload = any_conf_changed or global_changed
        user_cnt = len(valid_users)
        proto_cnt = len(files)

    if need_reload:
        if async_reload:
            schedule_singbox_reload()
        else:
            reload_singbox()

    log("INFO", f"已完成节点用户同步：当前在席合租用户 {user_cnt} 人 (+ 管理员默认账号)")
    return True, f"synced {user_cnt} users across {proto_cnt} protocols", user_cnt


def compute_hmac_sha256(secret, message):
    return hmac.new(secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def register_with_panel(dry_run=False):
    cfg = load_env_config()
    default_links, protocols_list = discover_and_get_default_protocols()
    if not default_links:
        log("ERROR", "未在 /etc/sing-box/conf 中发现任何可用节点配置，请先使用 sb add 添加节点")
        return False

    try:
        server_id_val = int(cfg.get("SERVER_ID", "1"))
    except ValueError:
        server_id_val = cfg.get("SERVER_ID", "1")

    clean_protocols = [
        {
            "protocol": p["protocol"],
            "port": p["port"],
            "tag": p["tag"],
            "cred_type": p["cred_type"],
            "default_url": p["default_url"],
        }
        for p in protocols_list
    ]

    payload_dict = {
        "server_id": server_id_val,
        "agent_url": cfg.get("AGENT_URL", ""),
        "replace_all": True,
        "default_links": default_links,
        "protocols": clean_protocols,
    }
    payload_bytes = json.dumps(payload_dict, ensure_ascii=False, indent=2).encode("utf-8")
    payload_str = payload_bytes.decode("utf-8")

    panel_url = (cfg.get("PANEL_URL") or "").rstrip("/")
    if not panel_url and not dry_run:
        log("ERROR", "未配置面板地址 (PANEL_URL)，请先运行 sbr 配置")
        return False

    if re.search(r"/api/v1/(server|node)/register$", panel_url):
        endpoint = panel_url
    else:
        panel_base = re.sub(r"/api/v1/node/rotate$", "", panel_url)
        endpoint = f"{panel_base.rstrip('/')}/api/v1/server/register"

    if dry_run:
        print(payload_str)
        return True

    active_users = load_json_file(ACTIVE_USERS_FILE, [])
    if ensure_clash_api_and_user_routes([u.get("email", "") for u in active_users if isinstance(u, dict)], cfg):
        reload_singbox()

    api_key = cfg.get("API_KEY", "")
    ts = str(int(time.time()))
    sig = compute_hmac_sha256(api_key, f"{ts}.{payload_str}")

    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "Authorization": f"Bearer {api_key}",
        "X-API-Key": api_key,
        "X-Server-Id": str(server_id_val),
        "X-Node-Id": str(server_id_val),
        "X-Dujiao-Timestamp": ts,
        "X-Dujiao-Signature": sig,
        "X-Timestamp": ts,
        "X-Signature": sig,
        "User-Agent": f"sb-agent/{DAEMON_VERSION}",
    }

    log("STEP", f"正在向面板注册本机协议 ({len(default_links)} 个协议) -> {endpoint}")
    os.makedirs(CACHE_DIR, exist_ok=True)

    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(endpoint, data=payload_bytes, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=20) as resp:
                resp_body = resp.read().decode("utf-8", errors="replace")
                http_code = resp.getcode()
                log("INFO", f"面板协议注册成功 (HTTP {http_code})")
                with open(os.path.join(CACHE_DIR, "last_register_response.json"), "w", encoding="utf-8") as f:
                    f.write(resp_body)
                try:
                    resp_json = json.loads(resp_body)
                    if isinstance(resp_json, dict):
                        ok, msg, cnt = sync_users_to_singbox(resp_json, cfg)
                        log("INFO", f"首次注册同步响应处理完成: {msg}")
                except Exception as pe:
                    log("WARN", f"解析注册响应中的用户列表时跳过: {pe}")
                return True
        except urllib.error.HTTPError as he:
            err_body = ""
            try:
                err_body = he.read().decode("utf-8", errors="replace")[:400]
            except Exception:
                pass
            log("WARN", f"面板注册请求失败 (第 {attempt}/3 次, HTTP {he.code}): {err_body}")
        except Exception as e:
            log("WARN", f"面板注册网络异常 (第 {attempt}/3 次): {e}")
        if attempt < 3:
            time.sleep(3 * attempt)

    with open(os.path.join(CACHE_DIR, "last_failed_register.json"), "w", encoding="utf-8") as f:
        f.write(payload_str)
    log("ERROR", "向面板注册协议失败，请检查面板地址与通信密钥")
    return False


# ==============================================================================
# 内核 TC 与 Clash API 状态深度检查工具
# ==============================================================================

def inspect_kernel_tc(iface):
    """
    实时读取 Linux 内核 tc qdisc / class / filter 状态与流量整形计数器，
    用于精确判断限速规则是否在内核层真实生效。
    """
    result = {
        "iface": iface,
        "iface_exists": os.path.exists(f"/sys/class/net/{iface}"),
        "has_htb_root": False,
        "qdisc_summary": "",
        "classes": {},   # {cid_int: {"rate": str, "ceil": str, "sent_bytes": int, "sent_pkts": int, "dropped": int, "overlimits": int}}
        "filters": {},   # {cid_int: [ip_str, ...]}
        "error": "",
    }
    if not result["iface_exists"]:
        result["error"] = f"网卡 {iface} 不存在"
        return result

    try:
        p_qdisc = subprocess.run(["tc", "qdisc", "show", "dev", iface], capture_output=True, text=True, timeout=3)
        q_out = (p_qdisc.stdout or "").strip()
        result["qdisc_summary"] = q_out.splitlines()[0] if q_out else "无队列"
        if re.search(r"qdisc\s+htb\s+1:\s+root", q_out):
            result["has_htb_root"] = True
    except Exception as e:
        result["error"] = f"执行 tc qdisc 失败: {e}"
        return result

    if not result["has_htb_root"]:
        return result

    try:
        p_cls = subprocess.run(["tc", "-s", "class", "show", "dev", iface], capture_output=True, text=True, timeout=3)
        c_out = p_cls.stdout or ""
        blocks = re.split(r"(?=^class\s+htb\s+1:\d+)", c_out, flags=re.M)
        for blk in blocks:
            m_hdr = re.search(r"^class\s+htb\s+1:(\d+)\s+.*?rate\s+([^\s]+)\s+ceil\s+([^\s]+)", blk, re.M)
            if not m_hdr:
                continue
            cid = int(m_hdr.group(1))
            if cid in (1, 999):
                continue
            rate_s, ceil_s = m_hdr.group(2), m_hdr.group(3)
            m_sent = re.search(r"Sent\s+(\d+)\s+bytes\s+(\d+)\s+pkt", blk)
            m_drop = re.search(r"\(dropped\s+(\d+),\s*overlimits\s+(\d+)", blk)
            result["classes"][cid] = {
                "rate": rate_s,
                "ceil": ceil_s,
                "sent_bytes": int(m_sent.group(1)) if m_sent else 0,
                "sent_pkts": int(m_sent.group(2)) if m_sent else 0,
                "dropped": int(m_drop.group(1)) if m_drop else 0,
                "overlimits": int(m_drop.group(2)) if m_drop else 0,
            }
    except Exception:
        pass

    try:
        for proto in ("ip", "ipv6"):
            p_flt = subprocess.run(["tc", "filter", "show", "dev", iface, "parent", "1:0", "protocol", proto], capture_output=True, text=True, timeout=3)
            f_out = p_flt.stdout or ""
            current_cid = None
            for line in f_out.splitlines():
                m_flow = re.search(r"flowid\s+1:(\d+)", line)
                if m_flow:
                    current_cid = int(m_flow.group(1))
                    result["filters"].setdefault(current_cid, [])
                m_match = re.search(r"match\s+([0-9a-fA-F]{8})/ffffffff\s+at\s+16", line)
                if m_match and current_cid is not None:
                    hex_ip = m_match.group(1)
                    try:
                        ip_str = ".".join(str(int(hex_ip[i:i+2], 16)) for i in range(0, 8, 2))
                        if ip_str not in result["filters"][current_cid]:
                            result["filters"][current_cid].append(ip_str)
                    except Exception:
                        pass
    except Exception:
        pass

    return result


def inspect_clash_and_routes(cfg):
    clash_port = cfg.get("CLASH_API_PORT", "9090")
    clash_secret = cfg.get("CLASH_API_SECRET", "")
    info = {
        "clash_addr": f"127.0.0.1:{clash_port}",
        "config_clash_enabled": False,
        "config_auth_user_count": 0,
        "api_reachable": False,
        "api_error": "",
        "live_total_conns": 0,
        "live_identified_conns": 0,
    }

    global_conf = load_json_file(SB_GLOBAL_CONFIG, {})
    if isinstance(global_conf, dict):
        exp_clash = (global_conf.get("experimental") or {}).get("clash_api") or {}
        if isinstance(exp_clash, dict) and exp_clash.get("external_controller"):
            info["config_clash_enabled"] = True
        rules = (global_conf.get("route") or {}).get("rules") or []
        if isinstance(rules, list):
            for r in rules:
                if isinstance(r, dict) and r.get("auth_user"):
                    au = r.get("auth_user")
                    info["config_auth_user_count"] += len(au) if isinstance(au, list) else 1

    url = f"http://127.0.0.1:{clash_port}/connections"
    headers = {"Authorization": f"Bearer {clash_secret}"} if clash_secret else {}
    try:
        req = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            conns = data.get("connections") or []
            info["api_reachable"] = True
            info["live_total_conns"] = len(conns)
            identified = 0
            for c in conns:
                if isinstance(c, dict):
                    u, ip = ClashRateLimiter.extract_user_and_ip(c)
                    if u and ip:
                        identified += 1
            info["live_identified_conns"] = identified
    except Exception as e:
        info["api_error"] = str(e)

    return info


# ==============================================================================
# Clash API 活跃连接监控 & Linux TC HTB 多源IP/动态流量共享限速引擎
# ==============================================================================

class ClashRateLimiter:
    def __init__(self):
        self.user_ip_last_seen = {}   # {username: {ip: timestamp}}
        self.last_known_ips = {}      # {username: [ips]} 供动态限速期间短暂断连保持规则
        self.throttled_users = {}     # {username: {...}}
        self.user_cid_map = {}        # {username: int (10..890)}
        self.next_cid = 10
        self.tc_initialized_iface = None
        self.conn_last = {}           # {conn_id: 上次累计字节数}
        self.conn_baselined = False   # 首轮仅建立基线，不计入历史流量
        self.traffic_window = {}      # {username: [[ts, bytes], ...]}
        self.dyn_until = {}           # {username: 动态限速结束时间戳}
        self.dyn_trigger_bytes = {}   # {username: 触发动态限速时的窗口累计字节数}
        self._restore_state_from_disk()

    def _restore_state_from_disk(self):
        now = time.time()
        # 1. 恢复持久化的滑动窗口流量记录与动态限速状态
        tstate = load_json_file(TRAFFIC_STATE_FILE, {})
        if isinstance(tstate, dict):
            tw = tstate.get("traffic_window") or {}
            if isinstance(tw, dict):
                for u, samples in tw.items():
                    if isinstance(samples, list):
                        valid_s = [
                            [float(item[0]), int(item[1])]
                            for item in samples
                            if isinstance(item, (list, tuple)) and len(item) == 2 and now - float(item[0]) <= 86400
                        ]
                        if valid_s:
                            self.traffic_window[u] = valid_s
            du_map = tstate.get("dyn_until") or {}
            if isinstance(du_map, dict):
                for u, du in du_map.items():
                    if float(du or 0) > now:
                        self.dyn_until[u] = float(du)
            tb_map = tstate.get("dyn_trigger_bytes") or {}
            if isinstance(tb_map, dict):
                for u, tb in tb_map.items():
                    if int(tb or 0) > 0:
                        self.dyn_trigger_bytes[u] = int(tb)

        # 2. 兼容从 runtime_status.json 恢复受限状态
        snap = load_json_file(RUNTIME_STATUS_FILE, {})
        if isinstance(snap, dict):
            throttled = snap.get("throttled_users") or {}
            if isinstance(throttled, dict):
                for user, info in throttled.items():
                    if not isinstance(info, dict):
                        continue
                    du = int(info.get("dynamic_until") or 0)
                    if du > now:
                        self.dyn_until[user] = float(du)
                    wb = int(info.get("window_bytes") or 0)
                    if wb > 0 and user not in self.dyn_trigger_bytes:
                        self.dyn_trigger_bytes[user] = wb
                    ips = info.get("ips") or []
                    if ips:
                        self.last_known_ips[user] = list(ips)

    def _persist_traffic_state(self):
        try:
            save_json_file(TRAFFIC_STATE_FILE, {
                "updated_at": int(time.time()),
                "traffic_window": self.traffic_window,
                "dyn_until": self.dyn_until,
                "dyn_trigger_bytes": self.dyn_trigger_bytes,
            })
        except Exception:
            pass

    def _get_cid(self, username):
        if username not in self.user_cid_map:
            cid = self.next_cid
            self.next_cid = 10 if self.next_cid >= 890 else (self.next_cid + 1)
            self.user_cid_map[username] = cid
        return self.user_cid_map[username]

    def ensure_tc_root(self, iface):
        try:
            chk = subprocess.run(["tc", "qdisc", "show", "dev", iface], capture_output=True, text=True, timeout=3)
            if self.tc_initialized_iface == iface and re.search(r"qdisc\s+htb\s+1:\s+root", chk.stdout or ""):
                return True, ""
        except Exception:
            pass

        try:
            for mod in ("sch_htb", "sch_fq_codel", "sch_sfq", "cls_u32"):
                try:
                    subprocess.run(["modprobe", mod], stderr=subprocess.DEVNULL, check=False, timeout=3)
                except Exception:
                    pass
            p1 = subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "root", "handle", "1:", "htb", "default", "999", "r2q", "10"],
                capture_output=True, text=True, check=False, timeout=3
            )
            if p1.returncode != 0:
                return False, (p1.stderr or "tc qdisc replace 失败").strip()
            subprocess.run(
                ["tc", "class", "replace", "dev", iface, "parent", "1:", "classid", "1:1", "htb", "rate", "10000mbit", "ceil", "10000mbit", "burst", "2048kb", "cburst", "2048kb"],
                stderr=subprocess.DEVNULL, check=False, timeout=3
            )
            subprocess.run(
                ["tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", "1:999", "htb", "rate", "10000mbit", "ceil", "10000mbit", "burst", "2048kb", "cburst", "2048kb"],
                stderr=subprocess.DEVNULL, check=False, timeout=3
            )
            self.tc_initialized_iface = iface
            return True, ""
        except Exception as e:
            log("WARN", f"初始化网卡 {iface} TC HTB 队列失败: {e}")
            return False, str(e)

    def apply_user_limit(self, iface, username, ips, limit_mbps):
        ok, err_msg = self.ensure_tc_root(iface)
        if not ok:
            return False, err_msg
        cid = self._get_cid(username)
        target_mbps = max(1, int(limit_mbps))
        # 补偿二/三层帧头、TCP/TLS/代理协议开销与上行 ACK 占用，并使用充足的 KB 级突发桶深以兼容网卡 64KB TSO/GSO 大包，
        # 彻底解决原 burst 128k (仅16KB) + sfq perturb 10 乱序导致实测速度只有设定值一半 (~5Mbps) 的问题
        wire_kbit = int(round(target_mbps * 1000 * TC_OVERHEAD_FACTOR))
        rate_str = f"{wire_kbit}kbit"
        burst_kb = max(512, target_mbps * 64)
        burst_str = f"{burst_kb}kb"

        try:
            p_cls = subprocess.run(
                [
                    "tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", f"1:{cid}",
                    "htb", "rate", rate_str, "ceil", rate_str,
                    "burst", burst_str, "cburst", burst_str, "quantum", "15140",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=3,
            )
            if p_cls.returncode != 0:
                return False, (p_cls.stderr or "tc class replace 失败").strip()

            # 优先使用 fq_codel (不重排同连接包序，支持高并发连接)，若内核不支持则回退至大队列 pfifo
            p_qd = subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{cid}", "handle", f"{cid}:", "fq_codel", "limit", "4096", "quantum", "1514"],
                capture_output=True,
                text=True,
                check=False,
                timeout=3,
            )
            if p_qd.returncode != 0:
                subprocess.run(
                    ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{cid}", "handle", f"{cid}:", "pfifo", "limit", "2000"],
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=3,
                )

            subprocess.run(
                ["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)],
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=3,
            )
            for ip in ips:
                if ":" in ip:
                    subprocess.run(
                        ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ipv6", "prio", str(cid), "u32", "match", "ip6", "dst", f"{ip}/128", "flowid", f"1:{cid}"],
                        stderr=subprocess.DEVNULL,
                        check=False,
                        timeout=3,
                    )
                else:
                    subprocess.run(
                        ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip", "prio", str(cid), "u32", "match", "ip", "dst", f"{ip}/32", "flowid", f"1:{cid}"],
                        stderr=subprocess.DEVNULL,
                        check=False,
                        timeout=3,
                    )
            return True, ""
        except Exception as e:
            log("WARN", f"为用户 {username} 应用 TC 限速规则异常: {e}")
            return False, str(e)

    def remove_user_limit(self, iface, username):
        cid = self.user_cid_map.get(username)
        if not cid:
            return
        try:
            subprocess.run(["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)], stderr=subprocess.DEVNULL, check=False, timeout=3)
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "parent", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False, timeout=3)
            subprocess.run(["tc", "class", "del", "dev", iface, "parent", "1:1", "classid", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False, timeout=3)
        except Exception:
            pass

    def reset_all_state(self, iface):
        with LIMIT_LOCK:
            self.clear_all_tc(iface)
            self.tc_initialized_iface = None
            self.throttled_users.clear()
            self.dyn_until.clear()
            self.dyn_trigger_bytes.clear()
            self.traffic_window.clear()
            self.user_ip_last_seen.clear()
            self.last_known_ips.clear()
            self._persist_traffic_state()
        self.poll_once()

    @staticmethod
    def clear_all_tc(iface):
        try:
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "root"], stderr=subprocess.DEVNULL, check=False, timeout=3)
        except Exception:
            pass

    @staticmethod
    def extract_user_and_ip(conn):
        meta = conn.get("metadata") or {}
        src_ip = str(meta.get("sourceIP") or "").strip()
        if src_ip.startswith("[") and src_ip.endswith("]"):
            src_ip = src_ip[1:-1]
        if src_ip.startswith("::ffff:"):
            src_ip = src_ip[7:]
        if not src_ip or src_ip in ("127.0.0.1", "::1", "0.0.0.0"):
            return "", ""

        user = str(meta.get("user") or meta.get("authUser") or meta.get("inboundUser") or "").strip()
        if not user:
            rule_str = f"{conn.get('rule', '')} {conn.get('rulePayload', '')}"
            m = AUTH_USER_RULE_RE.search(rule_str)
            if m:
                user = m.group(1).strip()
        return user, src_ip

    def poll_once(self):
        with LIMIT_LOCK:
            cfg = load_env_config()
            clash_port = cfg.get("CLASH_API_PORT", "9090")
            clash_secret = cfg.get("CLASH_API_SECRET", "")
            iface = cfg.get("NET_IFACE") or detect_default_iface()

            ip_limit_enable = cfg.get("IP_LIMIT_ENABLE", "true").lower() == "true"
            try:
                ip_threshold = max(1, int(cfg.get("IP_THRESHOLD", "2")))
            except ValueError:
                ip_threshold = 2
            try:
                default_limit_mbps = max(1, int(float(cfg.get("LIMIT_MBPS", "10"))))
            except ValueError:
                default_limit_mbps = 10
            try:
                active_window = max(3, int(cfg.get("ACTIVE_WINDOW_SEC", "15")))
            except ValueError:
                active_window = 15
            try:
                check_interval = max(2, int(cfg.get("CHECK_INTERVAL", "5")))
            except ValueError:
                check_interval = 5
            limit_admin = cfg.get("LIMIT_ADMIN", "false").lower() == "true"

            dyn_enabled = cfg.get("DYN_LIMIT_ENABLE", "true").lower() == "true"
            try:
                dyn_window_min = max(1.0, float(cfg.get("DYN_WINDOW_MIN", "40")))
                dyn_window = dyn_window_min * 60.0
                dyn_threshold_gb = max(0.001, float(cfg.get("DYN_THRESHOLD_GB", "2.5")))
                dyn_bytes = dyn_threshold_gb * (1024 ** 3)
                dyn_mbps = max(1, int(float(cfg.get("DYN_LIMIT_MBPS", "10"))))
                dyn_limit_min = max(1.0, float(cfg.get("DYN_LIMIT_MIN", "60")))
                dyn_dur = dyn_limit_min * 60.0
            except ValueError:
                dyn_window_min, dyn_window = 40.0, 2400.0
                dyn_threshold_gb, dyn_bytes = 2.5, 2.5 * (1024 ** 3)
                dyn_mbps = 10
                dyn_limit_min, dyn_dur = 60.0, 3600.0

            config_summary = {
                "ip_limit_enable": ip_limit_enable,
                "ip_threshold": ip_threshold,
                "default_limit_mbps": default_limit_mbps,
                "active_window_sec": active_window,
                "check_interval": check_interval,
                "limit_admin": limit_admin,
                "dyn_limit_enable": dyn_enabled,
                "dyn_window_min": dyn_window_min,
                "dyn_threshold_gb": dyn_threshold_gb,
                "dyn_limit_mbps": dyn_mbps,
                "dyn_limit_min": dyn_limit_min,
            }

            now = time.time()
            url = f"http://127.0.0.1:{clash_port}/connections"
            headers = {"Authorization": f"Bearer {clash_secret}"} if clash_secret else {}

            try:
                req = urllib.request.Request(url, headers=headers, method="GET")
                with urllib.request.urlopen(req, timeout=3) as resp:
                    data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            except Exception as e:
                status_snapshot = {
                    "daemon_version": DAEMON_VERSION,
                    "updated_at": int(now),
                    "updated_at_cst": now_cst_str(now),
                    "clash_api": f"127.0.0.1:{clash_port}",
                    "clash_api_ok": False,
                    "clash_api_error": str(e),
                    "iface": iface,
                    "ip_threshold": ip_threshold,
                    "default_limit_mbps": default_limit_mbps,
                    "config": config_summary,
                    "total_connections": 0,
                    "identified_connections": 0,
                    "active_users": {},
                    "throttled_users": self.throttled_users,
                }
                save_json_file(RUNTIME_STATUS_FILE, status_snapshot)
                return

            conns = data.get("connections") or []
            seen_conn_ids = set()
            identified_conns = 0
            cycle_user_deltas = {}

            for c in conns:
                if not isinstance(c, dict):
                    continue
                user, src_ip = self.extract_user_and_ip(c)
                if not user or not src_ip:
                    continue
                identified_conns += 1
                if user == "admin" and not limit_admin:
                    continue
                self.user_ip_last_seen.setdefault(user, {})[src_ip] = now
                cid_key = str(c.get("id") or "")
                if cid_key:
                    total = int(c.get("upload") or 0) + int(c.get("download") or 0)
                    seen_conn_ids.add(cid_key)
                    last = self.conn_last.get(cid_key)
                    self.conn_last[cid_key] = total
                    delta = (total - last) if last is not None else (total if self.conn_baselined else 0)
                    if delta > 0:
                        cycle_user_deltas[user] = cycle_user_deltas.get(user, 0) + delta

            for u, d_bytes in cycle_user_deltas.items():
                if d_bytes > 0:
                    self.traffic_window.setdefault(u, []).append([round(now, 1), int(d_bytes)])

            for k in list(self.conn_last.keys()):
                if k not in seen_conn_ids:
                    del self.conn_last[k]
            self.conn_baselined = True

            active_user_ips = {}
            for user in list(self.user_ip_last_seen.keys()):
                ip_map = self.user_ip_last_seen[user]
                for ip in list(ip_map.keys()):
                    if now - ip_map[ip] > active_window:
                        del ip_map[ip]
                if not ip_map:
                    del self.user_ip_last_seen[user]
                else:
                    sorted_ips = sorted(ip_map.keys())
                    active_user_ips[user] = sorted_ips
                    self.last_known_ips[user] = sorted_ips

            user_custom_mbps = {}
            for u in load_json_file(ACTIVE_USERS_FILE, []):
                if isinstance(u, dict) and u.get("email") and int(u.get("speed_limit_bps") or 0) > 0:
                    user_custom_mbps[u["email"]] = max(1, int(u["speed_limit_bps"]) // 1_000_000)

            if not dyn_enabled:
                self.dyn_until.clear()
                self.dyn_trigger_bytes.clear()
                self.traffic_window.clear()

            for user in list(self.dyn_until.keys()):
                if now >= self.dyn_until[user]:
                    del self.dyn_until[user]
                    self.dyn_trigger_bytes.pop(user, None)
                    log("INFO", f"[动态限速到期] 用户 [{user}] 动态限速到期，按最近 {dyn_window_min:g} 分钟流量重新评估")

            user_window_bytes = {}
            for user in list(self.traffic_window.keys()):
                samples = [[t, b] for t, b in self.traffic_window[user] if now - t <= dyn_window]
                if not samples:
                    del self.traffic_window[user]
                    continue
                self.traffic_window[user] = samples
                used = int(sum(b for _, b in samples))
                user_window_bytes[user] = used
                if dyn_enabled and used >= dyn_bytes:
                    self.dyn_trigger_bytes[user] = max(used, self.dyn_trigger_bytes.get(user, 0))
                    if user not in self.dyn_until:
                        self.dyn_until[user] = now + dyn_dur
                        log("WARN", f"[触发动态限速] 用户 [{user}] {dyn_window_min:g} 分钟内累计流量 {used / (1024 ** 3):.3f}GB >= {dyn_threshold_gb:g}GB -> 其所有源 IP 共享 {dyn_mbps}Mbps 限速 {dyn_limit_min:g} 分钟")

            self._persist_traffic_state()

            kernel_tc = inspect_kernel_tc(iface) if (self.throttled_users or active_user_ips or self.dyn_until) else {"classes": {}}
            existing_kernel_cids = set((kernel_tc.get("classes") or {}).keys())

            currently_exceeded = set()
            all_eval_users = set(active_user_ips.keys()) | set(self.dyn_until.keys())
            for user in all_eval_users:
                ips = active_user_ips.get(user) or self.last_known_ips.get(user, [])
                active_ips_now = active_user_ips.get(user, [])
                ip_exceeded = bool(ip_limit_enable and (len(active_ips_now) > ip_threshold))
                dyn_active = bool(dyn_enabled and (user in self.dyn_until) and (self.dyn_until[user] > now))

                if ip_exceeded or dyn_active:
                    currently_exceeded.add(user)
                    limit_val = user_custom_mbps.get(user, default_limit_mbps) if ip_exceeded else None
                    if dyn_active:
                        limit_val = dyn_mbps if limit_val is None else min(limit_val, dyn_mbps)

                    cur_win_bytes = user_window_bytes.get(user, 0)
                    peak_bytes = max(cur_win_bytes, self.dyn_trigger_bytes.get(user, 0))

                    reasons = []
                    if ip_exceeded:
                        reasons.append(f"多IP超限(活跃{len(active_ips_now)}>{ip_threshold})")
                    if dyn_active:
                        rem_sec = max(1, int(self.dyn_until[user] - now))
                        rem_m, rem_s = divmod(rem_sec, 60)
                        peak_gb = peak_bytes / (1024 ** 3)
                        reasons.append(f"动态流量超限(累计{peak_gb:.2f}GB>={dyn_threshold_gb:g}GB,剩余{rem_m}分{rem_s:02d}秒)")

                    cid = self._get_cid(user)
                    prev = self.throttled_users.get(user)
                    need_reapply = (
                        not prev
                        or prev.get("ips") != ips
                        or prev.get("limit_mbps") != limit_val
                        or (ips and cid not in existing_kernel_cids)
                    )
                    if need_reapply:
                        tc_ok, tc_err = self.apply_user_limit(iface, user, ips, limit_val)
                        since_ts = prev["since"] if prev else int(now)
                        self.throttled_users[user] = {
                            "cid": cid,
                            "ips": ips,
                            "ip_count": len(active_ips_now),
                            "limit_mbps": limit_val,
                            "since": since_ts,
                            "since_cst": now_cst_str(since_ts),
                            "ip_exceeded": ip_exceeded,
                            "dyn_active": dyn_active,
                            "dynamic_until": int(self.dyn_until.get(user, 0)),
                            "reasons": reasons,
                            "window_bytes": cur_win_bytes,
                            "trigger_bytes": peak_bytes,
                            "window_gb": round(cur_win_bytes / (1024 ** 3), 4),
                            "tc_applied_ok": tc_ok,
                            "tc_error": tc_err,
                        }
                        if not prev:
                            log("WARN", f"[触发限速] 用户 [{user}] 原因: {' + '.join(reasons)} | IPs: {', '.join(ips) or '暂无'} -> 已加入共享 {limit_val}Mbps 限速池 (TC 1:{cid}, 生效={tc_ok})")
                    else:
                        prev["ip_count"] = len(active_ips_now)
                        prev["ip_exceeded"] = ip_exceeded
                        prev["dyn_active"] = dyn_active
                        prev["dynamic_until"] = int(self.dyn_until.get(user, 0))
                        prev["reasons"] = reasons
                        prev["window_bytes"] = cur_win_bytes
                        prev["trigger_bytes"] = peak_bytes
                        prev["window_gb"] = round(cur_win_bytes / (1024 ** 3), 4)

            for user in list(self.throttled_users.keys()):
                if user not in currently_exceeded:
                    self.remove_user_limit(iface, user)
                    del self.throttled_users[user]
                    rem_ips = active_user_ips.get(user, [])
                    log("INFO", f"[解除限速] 用户 [{user}] 活跃源 IP 数 ({len(rem_ips)} <= {ip_threshold}) 且无动态流量限速 -> 已移出限速池")

            active_users_detail = {}
            for u in sorted(set(active_user_ips.keys()) | set(user_window_bytes.keys()) | set(self.throttled_users.keys())):
                u_ips = active_user_ips.get(u, [])
                th_info = self.throttled_users.get(u)
                w_bytes = user_window_bytes.get(u, 0)
                t_bytes = max(w_bytes, self.dyn_trigger_bytes.get(u, 0), int((th_info or {}).get("trigger_bytes") or 0))
                active_users_detail[u] = {
                    "ip_count": len(u_ips),
                    "ips": u_ips,
                    "window_bytes": w_bytes,
                    "trigger_bytes": t_bytes,
                    "window_gb": round(w_bytes / (1024 ** 3), 4),
                    "throttled": th_info is not None,
                    "limit_mbps": th_info.get("limit_mbps", 0) if th_info else 0,
                    "ip_exceeded": bool(th_info.get("ip_exceeded")) if th_info else False,
                    "dyn_active": bool(th_info.get("dyn_active")) if th_info else False,
                    "dynamic_until": int(th_info.get("dynamic_until") or 0) if th_info else 0,
                    "reasons": th_info.get("reasons", []) if th_info else [],
                }

            status_snapshot = {
                "daemon_version": DAEMON_VERSION,
                "updated_at": int(now),
                "updated_at_cst": now_cst_str(now),
                "clash_api": f"127.0.0.1:{clash_port}",
                "clash_api_ok": True,
                "clash_api_error": "",
                "iface": iface,
                "ip_threshold": ip_threshold,
                "default_limit_mbps": default_limit_mbps,
                "config": config_summary,
                "total_connections": len(conns),
                "identified_connections": identified_conns,
                "active_users": active_users_detail,
                "throttled_users": self.throttled_users,
            }
            save_json_file(RUNTIME_STATUS_FILE, status_snapshot)


RATE_LIMITER = ClashRateLimiter()


# ==============================================================================
# CLI 限速生效详情展示与一键环境测试
# ==============================================================================

def format_bytes(num_bytes):
    num_bytes = int(num_bytes or 0)
    if num_bytes >= 1024 ** 3:
        return f"{num_bytes / (1024 ** 3):.2f} GB"
    elif num_bytes >= 1024 ** 2:
        return f"{num_bytes / (1024 ** 2):.2f} MB"
    elif num_bytes >= 1024:
        return f"{num_bytes / 1024:.1f} KB"
    return f"{num_bytes} B"


def print_limit_status():
    cfg = load_env_config()
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    ip_en = cfg.get("IP_LIMIT_ENABLE", "true").lower() == "true"
    dyn_en = cfg.get("DYN_LIMIT_ENABLE", "true").lower() == "true"
    limit_admin = cfg.get("LIMIT_ADMIN", "false").lower() == "true"

    snap = load_json_file(RUNTIME_STATUS_FILE, {})
    now = int(time.time())
    updated_at = int(snap.get("updated_at") or 0)
    age_sec = (now - updated_at) if updated_at > 0 else -1

    daemon_running = False
    try:
        if os.path.isdir("/run/systemd/system"):
            res = subprocess.run(["systemctl", "is-active", "--quiet", "sb-agent.service"], timeout=3)
            daemon_running = (res.returncode == 0)
        if not daemon_running:
            res = subprocess.run(["pgrep", "-f", "sb_agent_daemon.py daemon"], capture_output=True, timeout=3)
            daemon_running = (res.returncode == 0)
    except Exception:
        pass

    if not daemon_running:
        RATE_LIMITER.poll_once()
        snap = load_json_file(RUNTIME_STATUS_FILE, {})
        updated_at = int(snap.get("updated_at") or 0)
        age_sec = (now - updated_at) if updated_at > 0 else -1

    clash_info = inspect_clash_and_routes(cfg)
    tc_info = inspect_kernel_tc(iface)

    print(f"\n{BOLD}{CYAN}================ [一] 当前限速参数配置总览 ================{NC}")
    ip_badge = f"{GREEN}已开启{NC}" if ip_en else f"{RED}已关闭{NC}"
    dyn_badge = f"{GREEN}已开启{NC}" if dyn_en else f"{RED}已关闭{NC}"
    adm_badge = f"{YELLOW}参与限速{NC}" if limit_admin else f"{GREEN}豁免限速 (不限速){NC}"

    print(f"  • {BOLD}多 IP 共享限速{NC}   : [{ip_badge}] 活跃源 IP 数 > {BOLD}{YELLOW}{cfg.get('IP_THRESHOLD', '2')}{NC} 个 -> 共享带宽 {BOLD}{RED}{cfg.get('LIMIT_MBPS', '10')} Mbps{NC} (活跃判定窗口: {cfg.get('ACTIVE_WINDOW_SEC', '15')}s)")
    print(f"  • {BOLD}动态流量限速{NC}     : [{dyn_badge}] {BOLD}{YELLOW}{cfg.get('DYN_WINDOW_MIN', '40')}{NC} 分钟内累计 >= {BOLD}{YELLOW}{cfg.get('DYN_THRESHOLD_GB', '2.5')} GB{NC} -> 共享带宽 {BOLD}{RED}{cfg.get('DYN_LIMIT_MBPS', '10')} Mbps{NC} (持续 {BOLD}{cfg.get('DYN_LIMIT_MIN', '60')}{NC} 分钟)")
    print(f"  • {BOLD}巡检与网卡配置{NC}   : 绑定网卡 {BOLD}{CYAN}{iface}{NC} | 巡检间隔 {BOLD}{cfg.get('CHECK_INTERVAL', '5')}s{NC} | 管理员账号(admin): {adm_badge}")

    print(f"\n{BOLD}{CYAN}================ [二] 限速是否生效 (底层组件实时诊断) ================{NC}")
    if daemon_running:
        age_str = f"{age_sec} 秒前 ({snap.get('updated_at_cst', '-')})" if age_sec >= 0 else "刚刚"
        print(f"  1. 守护进程 (sb-agent) : {GREEN}✅ 运行中 (v{snap.get('daemon_version', DAEMON_VERSION)}){NC} | 最近一次巡检采样: {age_str}")
    else:
        print(f"  1. 守护进程 (sb-agent) : {RED}❌ 未运行{NC} (请在菜单中选择重启后台守护服务)")

    if clash_info["api_reachable"]:
        print(f"  2. Clash API 监控接口  : {GREEN}✅ 正常连通{NC} ({clash_info['clash_addr']}) | 实时活跃总连接: {BOLD}{clash_info['live_total_conns']}{NC} 条 (已识别用户连接: {BOLD}{clash_info['live_identified_conns']}{NC} 条)")
    else:
        print(f"  2. Clash API 监控接口  : {RED}❌ 无法连接{NC} ({clash_info['clash_addr']}) | 错误: {clash_info['api_error'] or '请确认 sing-box 正在运行'}")

    if clash_info["config_clash_enabled"] and clash_info["config_auth_user_count"] > 0:
        print(f"  3. 用户流量追踪规则    : {GREEN}✅ 已生效{NC} (config.json 已开启 Clash API 并注入 {clash_info['config_auth_user_count']} 名用户的 auth_user 规则)")
    else:
        print(f"  3. 用户流量追踪规则    : {YELLOW}⚠️ 待注入{NC} (将在面板同步或注册时自动写入 /etc/sing-box/config.json)")

    active_cls_cnt = len(tc_info.get("classes") or {})
    if not tc_info["iface_exists"]:
        print(f"  4. 内核 TC 限速引擎    : {RED}❌ 绑定网卡 {iface} 不存在{NC} (请在限速配置菜单中修改绑定网卡)")
    elif tc_info["has_htb_root"]:
        print(f"  4. 内核 TC 限速引擎    : {GREEN}✅ 已挂载生效{NC} (网卡 {iface} HTB 根队列 1: 已激活 | 当前内核活跃限速子类: {BOLD}{active_cls_cnt}{NC} 个)")
    else:
        print(f"  4. 内核 TC 限速引擎    : {GREEN}🟢 就绪待命{NC} (网卡 {iface} 正常，当前无超限用户，触发限速时自动挂载 HTB 队列)")

    push_port = int(cfg.get("AGENT_PORT") or 18080)
    push_ok = False
    push_ms = 0
    try:
        t_p0 = time.time()
        with urllib.request.urlopen(f"http://127.0.0.1:{push_port}/health", timeout=2) as presp:
            push_ok = (presp.getcode() == 200)
            push_ms = int((time.time() - t_p0) * 1000)
    except Exception:
        pass
    last_push_file = os.path.join(CACHE_DIR, "last_push_payload.json")
    last_push_str = now_cst_str(os.path.getmtime(last_push_file)) if os.path.isfile(last_push_file) else "暂无记录"
    if push_ok:
        print(f"  5. 面板 Push 回调监听  : {GREEN}✅ 正常响应{NC} (0.0.0.0:{push_port} 多线程异步服务, 本地响应 {push_ms}ms | 最近收到推送: {last_push_str})")
    else:
        print(f"  5. 面板 Push 回调监听  : {RED}❌ 未响应{NC} (端口 {push_port} 未就绪，请在主菜单选择 6 重启后台守护服务)")

    overall_ok = daemon_running and push_ok and clash_info["api_reachable"] and tc_info["iface_exists"] and (ip_en or dyn_en)
    if overall_ok:
        print(f"  >>> {BOLD}限速系统整体状态   : {GREEN}✅ 限速监控已正常生效{NC}")
    elif not (ip_en or dyn_en):
        print(f"  >>> {BOLD}限速系统整体状态   : {YELLOW}⏸️  多IP限速与动态流量限速当前均已手动关闭{NC}")
    else:
        print(f"  >>> {BOLD}限速系统整体状态   : {RED}⚠️ 存在异常项，请根据上方提示检查对应组件{NC}")

    print(f"\n{BOLD}{CYAN}================ [三] 各用户实时活跃源 IP 与窗口流量统计 ================{NC}")
    active_users = snap.get("active_users") or {}
    throttled_users = snap.get("throttled_users") or {}
    tstate_disk = load_json_file(TRAFFIC_STATE_FILE, {})
    disk_tw = (tstate_disk.get("traffic_window") or {}) if isinstance(tstate_disk, dict) else {}
    disk_tb = (tstate_disk.get("dyn_trigger_bytes") or {}) if isinstance(tstate_disk, dict) else {}

    ip_thresh = int(cfg.get("IP_THRESHOLD", "2") or 2)
    dyn_thresh_gb = float(cfg.get("DYN_THRESHOLD_GB", "2.5") or 2.5)
    dyn_thresh_bytes = dyn_thresh_gb * (1024 ** 3)
    dyn_win_min = float(cfg.get("DYN_WINDOW_MIN", "40") or 40)
    dyn_win_sec = dyn_win_min * 60.0

    all_display_users = sorted(set(active_users.keys()) | set(throttled_users.keys()))
    if not all_display_users:
        print("  当前无活跃用户连接或窗口流量记录")
    else:
        for u in all_display_users:
            info = active_users.get(u) or {}
            tinfo = throttled_users.get(u) or {}
            ips_list = info.get("ips") if info.get("ips") is not None else (tinfo.get("ips") or [])
            ip_cnt = len(ips_list)

            # 读取滑动窗口流量 (优先取 snapshot，其次从持久化文件与内核已整形流量兜底)
            w_bytes = int(info.get("window_bytes") or tinfo.get("window_bytes") or 0)
            if w_bytes == 0 and u in disk_tw and isinstance(disk_tw[u], list):
                w_bytes = int(sum(int(item[1]) for item in disk_tw[u] if isinstance(item, (list, tuple)) and len(item) == 2 and now - float(item[0]) <= dyn_win_sec))

            trig_bytes = max(
                w_bytes,
                int(info.get("trigger_bytes") or 0),
                int(tinfo.get("trigger_bytes") or 0),
                int(disk_tb.get(u) or 0),
            )

            # 若用户已处于限速但此前由旧版守护进程产生导致窗口记录为0，用内核 TC Class 已整形流量 + 阈值兜底展示
            cid_u = int(tinfo.get("cid") or 0)
            cls_u = (tc_info.get("classes") or {}).get(cid_u) or {}
            if w_bytes == 0 and cls_u.get("sent_bytes", 0) > 0:
                w_bytes = int(cls_u["sent_bytes"])

            effective_bytes = max(w_bytes, trig_bytes) if (u in throttled_users and int(tinfo.get("dynamic_until") or 0) > now) else w_bytes
            pct = (effective_bytes / dyn_thresh_bytes * 100.0) if dyn_thresh_bytes > 0 else 0.0

            is_throttled = bool(info.get("throttled")) or (u in throttled_users)
            if is_throttled:
                lim_m = tinfo.get("limit_mbps") or info.get("limit_mbps") or cfg.get("LIMIT_MBPS", "10")
                dyn_until_u = int(tinfo.get("dynamic_until") or info.get("dynamic_until") or 0)
                is_ip_ex = bool(tinfo.get("ip_exceeded")) or (ip_en and ip_cnt > ip_thresh)
                is_dyn_ex = bool(tinfo.get("dyn_active")) or (dyn_en and dyn_until_u > now)
                tag_parts = []
                if is_ip_ex:
                    tag_parts.append("多IP超限")
                if is_dyn_ex:
                    tag_parts.append("动态流量超限")
                if not tag_parts:
                    tag_parts.append("限速生效中")
                status_tag = f"{RED}🔴 限速生效中 ({lim_m}Mbps | {'+'.join(tag_parts)}){NC}"
            else:
                status_tag = f"{GREEN}正常{NC}"

            ips_str = ", ".join(ips_list) if ips_list else "当前无活跃连接"
            ip_state_str = f"{RED}(已超阈值!){NC}" if (ip_en and ip_cnt > ip_thresh) else f"{GREEN}(未超限){NC}"
            flow_note = ""
            if trig_bytes > w_bytes and (u in throttled_users and int(tinfo.get("dynamic_until") or 0) > now):
                flow_note = f" [触发限速时峰值: {format_bytes(trig_bytes)}]"

            print(f"  • 用户: {BOLD}{u}{NC} [{status_tag}]")
            print(f"    ├─ 活跃源 IP 数 : {BOLD}{ip_cnt}{NC} / 阈值 {ip_thresh} 个 {ip_state_str} (IPs: {ips_str})")
            print(f"    └─ {dyn_win_min:g}m 窗口流量 : {BOLD}{format_bytes(effective_bytes)}{NC} / 阈值 {dyn_thresh_gb:g} GB ({pct:.1f}%){flow_note}")

    print(f"\n{BOLD}{CYAN}================ [四] 当前触发限速用户及内核 TC 整形统计 ================{NC}")
    if not throttled_users:
        print(f"  {GREEN}🟢 当前无任何用户触发限速 (所有用户源 IP 数与滑动窗口流量均在阈值范围内){NC}")
    else:
        for u, tinfo in throttled_users.items():
            cid = int(tinfo.get("cid") or 0)
            limit_m = tinfo.get("limit_mbps", 10)
            ips = tinfo.get("ips") or []
            ip_cnt = len(ips)
            dyn_until = int(tinfo.get("dynamic_until") or 0)

            # 精确判定触发原因，兼容旧版状态快照，绝不在 IP 数未超阈值时误报“多IP超限”
            is_ip_ex = bool(tinfo.get("ip_exceeded")) if "ip_exceeded" in tinfo else (ip_en and ip_cnt > ip_thresh)
            is_dyn_ex = bool(tinfo.get("dyn_active")) if "dyn_active" in tinfo else (dyn_until > now)

            reasons = list(tinfo.get("reasons") or [])
            if not reasons:
                if is_ip_ex:
                    reasons.append(f"多IP超限(活跃{ip_cnt}>{ip_thresh})")
                if is_dyn_ex:
                    rem_sec = max(0, dyn_until - now)
                    rem_m, rem_s = divmod(rem_sec, 60)
                    reasons.append(f"动态流量超限(剩余{rem_m}分{rem_s:02d}秒)")
            reason_str = " + ".join(reasons) if reasons else "动态流量超限"
            dyn_str = f" | 动态限速至: {now_cst_str(dyn_until)} CST" if dyn_until > now else ""

            cls_stat = (tc_info.get("classes") or {}).get(cid)
            flt_ips = (tc_info.get("filters") or {}).get(cid) or []

            print(f"  🔴 {BOLD}受限用户: {u}{NC} | 共享限速: {BOLD}{RED}{limit_m} Mbps{NC} | 触发原因: {YELLOW}{reason_str}{NC}{dyn_str}")
            print(f"     ├─ 受限源 IP ({len(ips)}个): {', '.join(ips) if ips else '等待连接'}")
            if cls_stat:
                sent_str = format_bytes(cls_stat["sent_bytes"])
                print(
                    f"     └─ 内核 TC 验证 : {GREEN}✅ 内核规则已生效{NC} (Class 1:{cid}, 设定={limit_m}Mbps/内核线速={cls_stat['rate']}, 过滤IP数={len(flt_ips)}) | "
                    f"已整形流量: {BOLD}{sent_str}{NC} ({cls_stat['sent_pkts']} 包) | 超速整顿(overlimits): {BOLD}{cls_stat['overlimits']}{NC} 次 | 丢包(dropped): {cls_stat['dropped']}"
                )
            else:
                print(f"     └─ 内核 TC 验证 : {YELLOW}⚠️ 尚未检测到内核 Class 1:{cid} (将在下一轮巡检自动同步){NC}")
    print("================================================================================")


def run_tc_self_test():
    cfg = load_env_config()
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    print(f"\n{BOLD}{CYAN}================ 限速环境自检与内核 TC 生效实测 ================{NC}")

    all_passed = True

    if os.path.exists(f"/sys/class/net/{iface}"):
        print(f"  [1/4] 物理网卡检查 ({iface})         : {GREEN}✅ 通过 (网卡存在){NC}")
    else:
        print(f"  [1/4] 物理网卡检查 ({iface})         : {RED}❌ 失败 (网卡 {iface} 不存在，请修改绑定网卡){NC}")
        all_passed = False

    test_cid = 899
    test_ip = "198.51.100.254"
    tc_ok = False
    tc_detail = ""
    if os.path.exists(f"/sys/class/net/{iface}"):
        had_root_before = inspect_kernel_tc(iface).get("has_htb_root", False)
        ok, err = RATE_LIMITER.ensure_tc_root(iface)
        if not ok:
            tc_detail = f"挂载 HTB 根队列失败: {err}"
        else:
            p1 = subprocess.run(
                ["tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", f"1:{test_cid}", "htb", "rate", "11500kbit", "ceil", "11500kbit", "burst", "640kb", "cburst", "640kb"],
                capture_output=True, text=True, check=False, timeout=3
            )
            p2 = subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{test_cid}", "handle", f"{test_cid}:", "fq_codel", "limit", "4096"],
                capture_output=True, text=True, check=False, timeout=3
            )
            if p2.returncode != 0:
                subprocess.run(
                    ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{test_cid}", "handle", f"{test_cid}:", "pfifo", "limit", "2000"],
                    capture_output=True, text=True, check=False, timeout=3
                )
            p3 = subprocess.run(
                ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip", "prio", str(test_cid), "u32", "match", "ip", "dst", f"{test_ip}/32", "flowid", f"1:{test_cid}"],
                capture_output=True, text=True, check=False, timeout=3
            )
            after_tc = inspect_kernel_tc(iface)
            cls_exists = test_cid in (after_tc.get("classes") or {})
            flt_exists = test_ip in ((after_tc.get("filters") or {}).get(test_cid) or [])
            subprocess.run(["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(test_cid)], stderr=subprocess.DEVNULL, check=False, timeout=3)
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "parent", f"1:{test_cid}"], stderr=subprocess.DEVNULL, check=False, timeout=3)
            subprocess.run(["tc", "class", "del", "dev", iface, "parent", "1:1", "classid", f"1:{test_cid}"], stderr=subprocess.DEVNULL, check=False, timeout=3)
            if not had_root_before and not RATE_LIMITER.throttled_users:
                ClashRateLimiter.clear_all_tc(iface)
                RATE_LIMITER.tc_initialized_iface = None

            if p1.returncode == 0 and p3.returncode == 0 and cls_exists and flt_exists:
                tc_ok = True
                tc_detail = f"成功在内核创建并验证 HTB 限速类 1:{test_cid} (10Mbps 补偿线速 11500kbit, burst 640kb) 与 u32 IP 过滤规则"
            else:
                tc_detail = (p1.stderr or p3.stderr or "内核未返回创建的测试限速类").strip()

    if tc_ok:
        print(f"  [2/4] 内核 TC HTB 限速规则下发实测  : {GREEN}✅ 通过 ({tc_detail}){NC}")
    else:
        print(f"  [2/4] 内核 TC HTB 限速规则下发实测  : {RED}❌ 失败 ({tc_detail}){NC}")
        all_passed = False

    clash_info = inspect_clash_and_routes(cfg)
    if clash_info["config_clash_enabled"] and clash_info["config_auth_user_count"] > 0:
        print(f"  [3/4] sing-box auth_user 路由配置   : {GREEN}✅ 通过 (已配置 {clash_info['config_auth_user_count']} 名用户的流量追踪规则){NC}")
    else:
        print(f"  [3/4] sing-box auth_user 路由配置   : {YELLOW}⚠️ 未就绪 (正在自动修复注入...){NC}")
        active_users = load_json_file(ACTIVE_USERS_FILE, [])
        if ensure_clash_api_and_user_routes([u.get("email", "") for u in active_users if isinstance(u, dict)], cfg):
            reload_singbox()
            clash_info = inspect_clash_and_routes(cfg)
            if clash_info["config_clash_enabled"]:
                print(f"        └─ 自动修复结果               : {GREEN}✅ 已成功注入并重启 sing-box 生效{NC}")
            else:
                all_passed = False

    if clash_info["api_reachable"]:
        print(f"  [4/4] Clash API 接口连通性测试      : {GREEN}✅ 通过 ({clash_info['clash_addr']} 响应正常，当前连接数: {clash_info['live_total_conns']}){NC}")
    else:
        print(f"  [4/4] Clash API 接口连通性测试      : {RED}❌ 失败 ({clash_info['api_error'] or '无法连接 Clash API'}){NC}")
        all_passed = False

    print("--------------------------------------------------------------------------------")
    if all_passed:
        print(f"  🎉 {BOLD}{GREEN}自检结论: 本机限速环境完全正常！当用户满足多IP超限或动态流量超限时将 100% 自动触发内核限速。{NC}")
    else:
        print(f"  ⚠️  {BOLD}{YELLOW}自检结论: 部分组件存在异常，请根据上方提示排查后再试。{NC}")
    print("================================================================================")


# ==============================================================================
# 接口二：Push 回调 HTTP Server (监听 POST /api/v1/sync 及本地管理接口)
# ==============================================================================

class PushWebhookHandler(BaseHTTPRequestHandler):
    timeout = 10

    def log_message(self, format, *args):
        pass

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/api/v1/health", "/ping"):
            status = load_json_file(RUNTIME_STATUS_FILE, {})
            self._send_json(200, {"ok": True, "version": DAEMON_VERSION, "status": status})
        else:
            self._send_json(404, {"ok": False, "message": "not found"})

    def do_POST(self):
        clean_path = self.path.split("?", 1)[0].rstrip("/")

        if self.client_address[0] == "127.0.0.1" and clean_path in ("/api/v1/reload-config", "/api/v1/clear-limits"):
            cfg = load_env_config()
            iface = cfg.get("NET_IFACE") or detect_default_iface()
            if clean_path == "/api/v1/clear-limits":
                RATE_LIMITER.reset_all_state(iface)
                log("INFO", "已通过本地管理指令清空所有内核 TC 限速规则与动态限速状态")
                self._send_json(200, {"ok": True, "version": DAEMON_VERSION, "message": "all rate limits cleared"})
            else:
                # 强制刷新当前受限用户的 TC 规则参数以立即应用新带宽/补偿系数
                with LIMIT_LOCK:
                    RATE_LIMITER.throttled_users.clear()
                RATE_LIMITER.poll_once()
                log("INFO", "已热重载最新限速配置参数并立即重新下发内核 TC 规则")
                self._send_json(200, {"ok": True, "version": DAEMON_VERSION, "message": "rate limit config reloaded"})
            return

        if clean_path not in ("/api/v1/sync", "/api/v1/node/sync", "/sync"):
            self._send_json(404, {"ok": False, "message": "unknown endpoint"})
            return

        cfg = load_env_config()
        secret = cfg.get("API_KEY", "")
        expected_sid = str(cfg.get("SERVER_ID", "")).strip()

        content_len = int(self.headers.get("Content-Length") or 0)
        raw_body = self.rfile.read(content_len).decode("utf-8", errors="replace") if content_len > 0 else "{}"

        hdr_sid = (self.headers.get("X-Server-Id") or self.headers.get("X-Node-Id") or "").strip()
        if hdr_sid and expected_sid and hdr_sid != expected_sid:
            log("WARN", f"[Push拒绝] 请求头 X-Server-Id ({hdr_sid}) 与本机配置 ({expected_sid}) 不匹配")
            self._send_json(403, {"ok": False, "message": "server_id mismatch"})
            return

        auth_hdr = (self.headers.get("Authorization") or self.headers.get("authorization") or "").strip()
        token_extracted = re.sub(r"^(?:Bearer|Token)\s+", "", auth_hdr, flags=re.I).strip()
        api_key_hdr = (
            self.headers.get("X-API-Key")
            or self.headers.get("X-Server-Secret")
            or self.headers.get("X-Agent-Secret")
            or self.headers.get("X-Token")
            or self.headers.get("Token")
            or self.headers.get("Secret")
            or ""
        ).strip()

        query_params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        query_token = (
            query_params.get("token", [""])[0]
            or query_params.get("secret", [""])[0]
            or query_params.get("key", [""])[0]
            or query_params.get("api_key", [""])[0]
        ).strip()

        ts_hdr = (
            self.headers.get("X-Dujiao-Timestamp")
            or self.headers.get("X-Timestamp")
            or self.headers.get("Timestamp")
            or ""
        ).strip()
        sig_hdr = (
            self.headers.get("X-Dujiao-Signature")
            or self.headers.get("X-Signature")
            or self.headers.get("Signature")
            or ""
        ).strip()
        if sig_hdr.startswith("sha256="):
            sig_hdr = sig_hdr[7:]

        authed = False
        if not secret:
            authed = True
        else:
            clean_secret = secret.strip()
            if (
                token_extracted == clean_secret
                or auth_hdr == clean_secret
                or api_key_hdr == clean_secret
                or query_token == clean_secret
            ):
                authed = True
            elif sig_hdr:
                candidates = [
                    compute_hmac_sha256(clean_secret, f"{ts_hdr}.{raw_body}"),
                    compute_hmac_sha256(clean_secret, f"{ts_hdr}{raw_body}"),
                    compute_hmac_sha256(clean_secret, f"{ts_hdr}\n{raw_body}"),
                    compute_hmac_sha256(clean_secret, f"{ts_hdr}:{raw_body}"),
                    compute_hmac_sha256(clean_secret, f"{raw_body}.{ts_hdr}"),
                    compute_hmac_sha256(clean_secret, raw_body),
                ]
                if any(hmac.compare_digest(sig_hdr.lower(), c.lower()) for c in candidates):
                    authed = True

        if not authed:
            headers_dict = {k: v for k, v in self.headers.items()}
            masked_sec = f"{secret[:3]}***{secret[-3:]}" if len(secret) > 6 else "***"
            log("WARN", f"[Push拒绝 401] 来源: {self.client_address[0]} | 接收 Headers: {json.dumps(headers_dict, ensure_ascii=False)} | 本地配置 API_KEY: {masked_sec}")
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(os.path.join(CACHE_DIR, "last_rejected_push.json"), "w", encoding="utf-8") as f:
                json.dump({
                    "time": now_cst_str(),
                    "client_ip": self.client_address[0],
                    "path": self.path,
                    "headers": headers_dict,
                    "body": raw_body,
                    "local_configured_secret_preview": masked_sec,
                }, f, ensure_ascii=False, indent=2)
            self._send_json(401, {"ok": False, "message": "unauthorized (secret or signature mismatch)", "client_ip": self.client_address[0]})
            return

        try:
            payload = json.loads(raw_body)
        except Exception as e:
            self._send_json(400, {"ok": False, "message": f"invalid json: {e}"})
            return

        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(os.path.join(CACHE_DIR, "last_push_payload.json"), "w", encoding="utf-8") as f:
            f.write(raw_body)

        t0 = time.time()
        log("STEP", f"收到面板 Push 同步请求 (来源: {self.client_address[0]})")
        ok, msg, count = sync_users_to_singbox(payload, cfg, async_reload=True)
        elapsed_ms = int((time.time() - t0) * 1000)
        if ok:
            log("INFO", f"已响应面板 Push 同步请求 (耗时 {elapsed_ms}ms, 在席用户: {count} 人)")
            self._send_json(200, {"ok": True, "message": msg, "synced_users": count, "elapsed_ms": elapsed_ms})
        else:
            self._send_json(500, {"ok": False, "message": msg})


def notify_local_daemon(endpoint):
    cfg = load_env_config()
    port = int(cfg.get("AGENT_PORT") or 18080)
    url = f"http://127.0.0.1:{port}{endpoint}"
    try:
        req = urllib.request.Request(url, data=b"{}", headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=3) as resp:
            body = json.loads(resp.read().decode("utf-8", errors="ignore"))
            return resp.getcode() == 200 and body.get("version") == DAEMON_VERSION
    except Exception:
        return False


def run_daemon():
    cfg = load_env_config()
    port = int(cfg.get("AGENT_PORT") or 18080)
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    # 启动时清理旧版遗留的 128k/sfq TC 队列，以便按最新补偿线速与 fq_codel 重建
    ClashRateLimiter.clear_all_tc(iface)
    RATE_LIMITER.tc_initialized_iface = None
    RATE_LIMITER.throttled_users.clear()

    log(
        "INFO",
        f"启动 sb-agent 守护进程 (v{DAEMON_VERSION}) | Push端口: {port} | "
        f"多IP限速({cfg.get('IP_LIMIT_ENABLE','true')}): >{cfg.get('IP_THRESHOLD', '2')} IPs -> {cfg.get('LIMIT_MBPS', '10')}Mbps | "
        f"动态限速({cfg.get('DYN_LIMIT_ENABLE','true')}): {cfg.get('DYN_WINDOW_MIN','40')}m>={cfg.get('DYN_THRESHOLD_GB','2.5')}GB -> {cfg.get('DYN_LIMIT_MBPS','10')}Mbps({cfg.get('DYN_LIMIT_MIN','60')}m)"
    )

    server = ThreadingHTTPServer(("0.0.0.0", port), PushWebhookHandler)

    if cfg.get("PANEL_URL") and cfg.get("API_KEY"):
        threading.Thread(target=register_with_panel, kwargs={"dry_run": False}, daemon=True).start()
    else:
        threading.Thread(target=ensure_admin_accounts_fast, daemon=True).start()
        ensure_clash_api_and_user_routes([], cfg)

    def limiter_loop():
        while True:
            try:
                RATE_LIMITER.poll_once()
            except Exception as e:
                log("WARN", f"限速巡检异常: {e}")
            c = load_env_config()
            try:
                interval = max(2, int(c.get("CHECK_INTERVAL", "5")))
            except ValueError:
                interval = 5
            time.sleep(interval)

    t = threading.Thread(target=limiter_loop, daemon=True)
    t.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "daemon"
    if cmd == "register":
        ok = register_with_panel(dry_run=False)
        sys.exit(0 if ok else 1)
    elif cmd == "dry-run":
        register_with_panel(dry_run=True)
    elif cmd == "discover":
        links, protos = discover_and_get_default_protocols()
        print(json.dumps({"default_links": links, "protocols": protos}, ensure_ascii=False, indent=2))
    elif cmd == "sync-file" and len(sys.argv) > 2:
        data = load_json_file(sys.argv[2], {})
        ok, msg, _ = sync_users_to_singbox(data)
        print(msg)
        sys.exit(0 if ok else 1)
    elif cmd == "poll-once":
        RATE_LIMITER.poll_once()
    elif cmd == "limit-status":
        print_limit_status()
    elif cmd == "test-tc":
        run_tc_self_test()
    elif cmd == "reload-config":
        if not notify_local_daemon("/api/v1/reload-config"):
            sys.exit(1)
    elif cmd == "test-push":
        cfg = load_env_config()
        port = int(cfg.get("AGENT_PORT") or 18080)
        secret = cfg.get("API_KEY", "")
        test_payload = json.dumps({"server_id": int(cfg.get("SERVER_ID", 1)), "users": []}).encode()
        ts = str(int(time.time()))
        sig = compute_hmac_sha256(secret, f"{ts}.{test_payload.decode()}")
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {secret}",
            "X-Server-Id": str(cfg.get("SERVER_ID", 1)),
            "X-Dujiao-Timestamp": ts,
            "X-Dujiao-Signature": sig,
        }
        url = f"http://127.0.0.1:{port}/api/v1/sync"
        try:
            req = urllib.request.Request(url, data=test_payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(f"[测试通过] 本地 Push 响应 HTTP {resp.getcode()}: {resp.read().decode()}")
        except urllib.error.HTTPError as he:
            print(f"[测试失败] HTTP {he.code}: {he.read().decode()}")
        except Exception as e:
            print(f"[测试失败] 无法连接到本地 Push 服务: {e}")
    elif cmd == "clear-tc":
        cfg = load_env_config()
        iface = cfg.get("NET_IFACE") or detect_default_iface()
        if not notify_local_daemon("/api/v1/clear-limits"):
            ClashRateLimiter.clear_all_tc(iface)
            save_json_file(TRAFFIC_STATE_FILE, {"updated_at": int(time.time()), "traffic_window": {}, "dyn_until": {}, "dyn_trigger_bytes": {}})
            snap = load_json_file(RUNTIME_STATUS_FILE, {})
            if isinstance(snap, dict):
                snap["throttled_users"] = {}
                save_json_file(RUNTIME_STATUS_FILE, snap)
        log("INFO", "已清理网卡 TC HTB 限速规则与受限状态")
    else:
        run_daemon()
__EOF_PY_DAEMON__
    chmod +x "${DAEMON_SCRIPT}"
}

# ==============================================================================
# 防火墙放行与 systemd 守护服务管理
# ==============================================================================

open_firewall_port() {
    local port="$1"
    [[ -z "${port}" ]] && return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        fi
    fi
}

is_daemon_running() {
    systemctl is-active --quiet sb-agent.service 2>/dev/null || pgrep -f "${DAEMON_SCRIPT} daemon" >/dev/null 2>&1
}

ensure_daemon_latest() {
    write_python_daemon
    if is_daemon_running; then
        local running_ver
        running_ver="$(jq -r '.daemon_version // ""' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo "")"
        if [[ "${running_ver}" != "${VERSION}" ]]; then
            info "检测到后台守护进程版本 (${running_ver:-旧版}) 与当前脚本 (v${VERSION}) 不一致，正在自动平滑升级守护服务..."
            setup_systemd_service
            sleep 1
        fi
    fi
}

setup_systemd_service() {
    load_config
    write_python_daemon
    open_firewall_port "${AGENT_PORT:-18080}"

    if [[ -d /run/systemd/system ]]; then
        cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sb-agent v${VERSION} (sing-box Panel Sync & Clash API Rate Limiter)
After=network.target sing-box.service

[Service]
Type=simple
User=root
Environment="INSTALL_DIR=${INSTALL_DIR}"
Environment="CONFIG_FILE=${CONFIG_FILE}"
ExecStart=/usr/bin/env python3 ${DAEMON_SCRIPT} daemon
ExecStopPost=/usr/bin/env python3 ${DAEMON_SCRIPT} clear-tc
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl stop sb-agent.service >/dev/null 2>&1 || true
        pkill -9 -f "${DAEMON_SCRIPT}" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable sb-agent.service >/dev/null 2>&1 || true
        systemctl start sb-agent.service >/dev/null 2>&1 || true
        info "已部署并重启后台守护服务 sb-agent.service (v${VERSION}, Push 回调端口: ${AGENT_PORT:-18080})"
    else
        pkill -f "${DAEMON_SCRIPT}" 2>/dev/null || true
        nohup python3 "${DAEMON_SCRIPT}" daemon >> "${LOG_FILE}" 2>&1 &
        info "已在后台启动 sb-agent 守护进程 (v${VERSION}, Push 回调端口: ${AGENT_PORT:-18080})"
    fi
}

apply_rate_limit_config_live() {
    save_config
    write_python_daemon
    if is_daemon_running && python3 "${DAEMON_SCRIPT}" reload-config >/dev/null 2>&1; then
        info "限速参数已保存并实时热重载生效 (保留历史流量统计窗口)！"
    else
        setup_systemd_service
        info "限速参数已保存并已重启后台守护进程至最新 v${VERSION} 生效！"
    fi
}

stop_systemd_service() {
    if [[ -d /run/systemd/system ]] && [[ -f "${SERVICE_FILE}" ]]; then
        systemctl stop sb-agent.service >/dev/null 2>&1 || true
        systemctl disable sb-agent.service >/dev/null 2>&1 || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    pkill -f "${DAEMON_SCRIPT}" 2>/dev/null || true
    [[ -f "${DAEMON_SCRIPT}" ]] && python3 "${DAEMON_SCRIPT}" clear-tc >/dev/null 2>&1 || true
}

# ==============================================================================
# 状态展示、实时连接与限速生效面板
# ==============================================================================

show_status_table() {
    load_config
    ensure_dirs
    ensure_daemon_latest

    echo -e "\n${BOLD}${CYAN}================ 本机 sing-box 协议列表与默认分享链接 ================${NC}"
    local disc_json
    disc_json="$(python3 "${DAEMON_SCRIPT}" discover 2>/dev/null || echo '{"default_links":[],"protocols":[]}')"
    local proto_count
    proto_count="$(echo "${disc_json}" | jq '.protocols | length' 2>/dev/null || echo 0)"

    if (( proto_count == 0 )); then
        echo -e "${YELLOW}未检测到任何 sing-box 节点配置，请先运行 sb add 添加节点。${NC}"
    else
        echo "${disc_json}" | jq -r '.protocols[] | "  • [\(.tag)] 配置文件: \(.config_name) | 端口: \(.port) | 凭据类型: \(.cred_type)\n    默认链接: \(.default_url)"'
    fi

    echo -e "\n${BOLD}${CYAN}================ 当前在席合租用户列表 (面板同步) ================${NC}"
    local user_count
    user_count="$(jq 'length' "${ACTIVE_USERS_FILE}" 2>/dev/null || echo 0)"
    echo -e "在席合租用户总数: ${BOLD}${GREEN}${user_count}${NC} 人 (另含固定保留的管理员默认账号 ${BOLD}admin${NC})"
    if (( user_count > 0 )); then
        jq -r '.[] | "  • 用户: \(.email) | UUID: \(.uuid) | 密码: \(.password) | 到期TS: \(.expire_at)"' "${ACTIVE_USERS_FILE}" 2>/dev/null | head -n 30
        (( user_count > 30 )) && echo "  ... (仅展示前 30 名用户)"
    fi
    echo "================================================================================"
}

show_connections_and_limits() {
    load_config
    ensure_dirs
    ensure_daemon_latest
    python3 "${DAEMON_SCRIPT}" limit-status
}

# ==============================================================================
# 交互式配置向导与交互式限速参数管理菜单
# ==============================================================================

interactive_configure() {
    load_config
    write_python_daemon
    echo -e "\n${BOLD}${BLUE}>>> 配置 sb-rotator v${VERSION} (面板对接与基础限速向导) <<<${NC}"
    show_status_table || true

    local srv_ip
    srv_ip="$(get_server_ip)"

    local in_url in_key in_sid in_port in_agent_url in_thresh in_mbps in_dyn_en in_dyn_win in_dyn_gb in_dyn_mbps in_dyn_min
    prompt_read "1. 请输入订阅管理面板地址 (如 https://panel.example.com) [${PANEL_URL}]: " in_url || return 1
    PANEL_URL="${in_url:-${PANEL_URL}}"

    prompt_read "2. 请输入面板通信密钥 (SERVER_AGENT_SECRET) [${API_KEY}]: " in_key || return 1
    API_KEY="${in_key:-${API_KEY}}"

    prompt_read "3. 请输入本机在面板中的 Server ID (正整数，默认 ${SERVER_ID:-1}) [${SERVER_ID:-1}]: " in_sid || return 1
    SERVER_ID="${in_sid:-${SERVER_ID:-1}}"

    prompt_read "4. 请输入本机 Push 回调监听端口 (默认 ${AGENT_PORT:-18080}) [${AGENT_PORT:-18080}]: " in_port || return 1
    AGENT_PORT="${in_port:-${AGENT_PORT:-18080}}"

    local default_agent_url="http://${srv_ip}:${AGENT_PORT}/api/v1/sync"
    prompt_read "5. 请输入上报给面板的 Push 回调地址 agent_url [${default_agent_url}]: " in_agent_url || return 1
    AGENT_URL="${in_agent_url:-${default_agent_url}}"

    prompt_read "6. [多IP限速] 单用户名触发限速的活跃源 IP 数量阈值 (默认 ${IP_THRESHOLD:-2}) [${IP_THRESHOLD:-2}]: " in_thresh || return 1
    [[ -n "${in_thresh}" ]] && IP_THRESHOLD="${in_thresh}"

    prompt_read "7. [多IP限速] 触发后该用户所有源 IP 合计共享带宽 Mbps (默认 ${LIMIT_MBPS:-10}) [${LIMIT_MBPS:-10}]: " in_mbps || return 1
    [[ -n "${in_mbps}" ]] && LIMIT_MBPS="${in_mbps}"

    prompt_read "8. [动态流量限速] 是否开启滑动窗口流量超限自动限速？(y/n) [${DYN_LIMIT_ENABLE:-true}]: " in_dyn_en || return 1
    if [[ "${in_dyn_en}" =~ ^[Nn]$ || "${in_dyn_en}" == "false" ]]; then
        DYN_LIMIT_ENABLE="false"
    elif [[ "${in_dyn_en}" =~ ^[Yy]$ || "${in_dyn_en}" == "true" ]]; then
        DYN_LIMIT_ENABLE="true"
    fi

    if [[ "${DYN_LIMIT_ENABLE}" == "true" ]]; then
        prompt_read "9. [动态流量限速] 流量统计滑动窗口时长 (分钟，默认 ${DYN_WINDOW_MIN:-40}) [${DYN_WINDOW_MIN:-40}]: " in_dyn_win || return 1
        [[ -n "${in_dyn_win}" ]] && DYN_WINDOW_MIN="${in_dyn_win}"

        prompt_read "10. [动态流量限速] 窗口内触发限速的累计流量阈值 (GB，默认 ${DYN_THRESHOLD_GB:-2.5}) [${DYN_THRESHOLD_GB:-2.5}]: " in_dyn_gb || return 1
        [[ -n "${in_dyn_gb}" ]] && DYN_THRESHOLD_GB="${in_dyn_gb}"

        prompt_read "11. [动态流量限速] 触发后共享限速带宽 (Mbps，默认 ${DYN_LIMIT_MBPS:-10}) [${DYN_LIMIT_MBPS:-10}]: " in_dyn_mbps || return 1
        [[ -n "${in_dyn_mbps}" ]] && DYN_LIMIT_MBPS="${in_dyn_mbps}"

        prompt_read "12. [动态流量限速] 触发后限速持续时长 (分钟，默认 ${DYN_LIMIT_MIN:-60}) [${DYN_LIMIT_MIN:-60}]: " in_dyn_min || return 1
        [[ -n "${in_dyn_min}" ]] && DYN_LIMIT_MIN="${in_dyn_min}"
    fi

    save_config
    setup_systemd_service
    info "配置已保存至 ${CONFIG_FILE}"
}

configure_rate_limit_menu() {
    ensure_dirs
    ensure_daemon_latest
    while true; do
        load_config
        local ip_en_str="${GREEN}已开启${NC}"
        [[ "${IP_LIMIT_ENABLE:-true}" != "true" ]] && ip_en_str="${RED}已关闭${NC}"
        local dyn_en_str="${GREEN}已开启${NC}"
        [[ "${DYN_LIMIT_ENABLE:-true}" != "true" ]] && dyn_en_str="${RED}已关闭${NC}"
        local adm_str="${GREEN}豁免限速 (false)${NC}"
        [[ "${LIMIT_ADMIN:-false}" == "true" ]] && adm_str="${YELLOW}参与限速 (true)${NC}"

        local tc_state="${YELLOW}待触发挂载${NC}"
        if tc qdisc show dev "${NET_IFACE}" 2>/dev/null | grep -qE "qdisc htb 1: root"; then
            local cls_cnt
            cls_cnt="$(tc class show dev "${NET_IFACE}" 2>/dev/null | grep -cE "^class htb 1:[0-9]+" || echo 0)"
            (( cls_cnt >= 2 )) && cls_cnt=$(( cls_cnt - 2 )) || cls_cnt=0
            tc_state="${GREEN}已挂载 HTB 根队列 (当前活跃限速类: ${cls_cnt} 个)${NC}"
        fi
        local th_cnt
        th_cnt="$(jq '.throttled_users | length' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo 0)"

        echo -e "\n${BOLD}${CYAN}================ 交互式限速参数配置与生效检验菜单 ================${NC}"
        echo -e "  ${BOLD}[当前生效状态]${NC}"
        echo -e "    • 绑定网卡内核 TC : ${YELLOW}${NET_IFACE}${NC} -> ${tc_state}"
        echo -e "    • 当前触发限速人数: ${BOLD}${RED}${th_cnt} 人${NC} (Clash API 端口: ${YELLOW}127.0.0.1:${CLASH_API_PORT}${NC})"
        echo -e "  ${BOLD}[一、多 IP 共享限速当前参数]${NC}"
        echo -e "    • 功能开关        : ${ip_en_str}"
        echo -e "    • 触发源 IP 阈值  : 单用户活跃源 IP 数 > ${BOLD}${YELLOW}${IP_THRESHOLD}${NC} 个"
        echo -e "    • 触发后共享带宽  : 该用户所有源 IP 合计 ${BOLD}${YELLOW}${LIMIT_MBPS} Mbps${NC}"
        echo -e "    • 活跃判定时间窗  : ${BOLD}${YELLOW}${ACTIVE_WINDOW_SEC} 秒${NC}"
        echo -e "  ${BOLD}[二、动态流量限速当前参数 (滑动窗口)]${NC}"
        echo -e "    • 功能开关        : ${dyn_en_str}"
        echo -e "    • 流量统计时间窗  : 最近 ${BOLD}${YELLOW}${DYN_WINDOW_MIN} 分钟${NC}"
        echo -e "    • 触发累计流量阈值: >= ${BOLD}${YELLOW}${DYN_THRESHOLD_GB} GB${NC}"
        echo -e "    • 触发后共享带宽  : 该用户所有源 IP 合计 ${BOLD}${YELLOW}${DYN_LIMIT_MBPS} Mbps${NC}"
        echo -e "    • 触发后持续时长  : ${BOLD}${YELLOW}${DYN_LIMIT_MIN} 分钟${NC}"
        echo -e "  ${BOLD}[三、巡检与豁免参数]${NC}"
        echo -e "    • 巡检轮询间隔    : 每 ${BOLD}${YELLOW}${CHECK_INTERVAL} 秒${NC} | 管理员账号(admin): ${adm_str}"
        echo "------------------------------------------------------------------"
        echo -e "  ${GREEN}1)${NC} 修改【多 IP 共享限速】参数 (开关 / 源 IP 阈值 / 共享带宽 Mbps / 判定窗口)"
        echo -e "  ${GREEN}2)${NC} 修改【动态流量限速】参数 (开关 / 统计窗口分钟 / 流量阈值 GB / 限速带宽 / 持续分钟)"
        echo -e "  ${GREEN}3)${NC} 快捷切换限速开关 (一键开启或关闭 多IP限速 / 动态流量限速 / 管理员限速)"
        echo -e "  ${GREEN}4)${NC} 修改【基础巡检与网卡】参数 (巡检间隔秒数 / 限速绑定网卡 / Clash API 端口)"
        echo -e "  ${GREEN}5)${NC} 查看【限速是否生效 & 实时连接/窗口流量/内核 TC 统计详情】"
        echo -e "  ${GREEN}6)${NC} 运行【限速环境自检与内核 TC 规则下发实测】 (验证本机限速能否正常生效)"
        echo -e "  ${GREEN}7)${NC} 立即清空当前所有 TC 限速规则并重置受限状态"
        echo -e "  ${GREEN}0)${NC} 返回主菜单"
        echo "=================================================================="
        local opt=""
        prompt_read "请选择操作 [0-7]: " opt || return 0
        case "${opt}" in
            1)
                local in_en in_t in_m in_w
                prompt_read "是否开启多 IP 共享限速？(y/n，当前 ${IP_LIMIT_ENABLE}) [${IP_LIMIT_ENABLE}]: " in_en || continue
                if [[ "${in_en}" =~ ^[Nn]$ || "${in_en}" == "false" ]]; then
                    IP_LIMIT_ENABLE="false"
                elif [[ "${in_en}" =~ ^[Yy]$ || "${in_en}" == "true" ]]; then
                    IP_LIMIT_ENABLE="true"
                fi
                prompt_read "请输入单用户名触发限速的活跃源 IP 数量阈值 (正整数) [${IP_THRESHOLD}]: " in_t || continue
                if [[ -n "${in_t}" ]]; then
                    if is_pos_int "${in_t}"; then IP_THRESHOLD="${in_t}"; else warn "输入无效，保持原值 ${IP_THRESHOLD}"; fi
                fi
                prompt_read "请输入该用户所有源 IP 合计共享限速带宽 (Mbps，正整数) [${LIMIT_MBPS}]: " in_m || continue
                if [[ -n "${in_m}" ]]; then
                    if is_pos_int "${in_m}"; then LIMIT_MBPS="${in_m}"; else warn "输入无效，保持原值 ${LIMIT_MBPS}"; fi
                fi
                prompt_read "请输入源 IP 活跃判定时间窗口 (秒，正整数) [${ACTIVE_WINDOW_SEC}]: " in_w || continue
                if [[ -n "${in_w}" ]]; then
                    if is_pos_int "${in_w}"; then ACTIVE_WINDOW_SEC="${in_w}"; else warn "输入无效，保持原值 ${ACTIVE_WINDOW_SEC}"; fi
                fi
                apply_rate_limit_config_live
                ;;
            2)
                local in_den in_dwin in_dgb in_dmbps in_dmin
                prompt_read "是否开启动态流量限速？(y/n，当前 ${DYN_LIMIT_ENABLE}) [${DYN_LIMIT_ENABLE}]: " in_den || continue
                if [[ "${in_den}" =~ ^[Nn]$ || "${in_den}" == "false" ]]; then
                    DYN_LIMIT_ENABLE="false"
                elif [[ "${in_den}" =~ ^[Yy]$ || "${in_den}" == "true" ]]; then
                    DYN_LIMIT_ENABLE="true"
                fi
                prompt_read "请输入流量统计滑动时间窗口 (分钟，如 40) [${DYN_WINDOW_MIN}]: " in_dwin || continue
                if [[ -n "${in_dwin}" ]]; then
                    if is_pos_num "${in_dwin}"; then DYN_WINDOW_MIN="${in_dwin}"; else warn "输入无效，保持原值 ${DYN_WINDOW_MIN}"; fi
                fi
                prompt_read "请输入窗口内触发限速的累计总流量阈值 (GB，支持小数如 2.5) [${DYN_THRESHOLD_GB}]: " in_dgb || continue
                if [[ -n "${in_dgb}" ]]; then
                    if is_pos_num "${in_dgb}"; then DYN_THRESHOLD_GB="${in_dgb}"; else warn "输入无效，保持原值 ${DYN_THRESHOLD_GB}"; fi
                fi
                prompt_read "请输入触发动态流量限速后的共享带宽 (Mbps，正整数) [${DYN_LIMIT_MBPS}]: " in_dmbps || continue
                if [[ -n "${in_dmbps}" ]]; then
                    if is_pos_int "${in_dmbps}"; then DYN_LIMIT_MBPS="${in_dmbps}"; else warn "输入无效，保持原值 ${DYN_LIMIT_MBPS}"; fi
                fi
                prompt_read "请输入触发动态流量限速后的持续时间 (分钟，如 60) [${DYN_LIMIT_MIN}]: " in_dmin || continue
                if [[ -n "${in_dmin}" ]]; then
                    if is_pos_num "${in_dmin}"; then DYN_LIMIT_MIN="${in_dmin}"; else warn "输入无效，保持原值 ${DYN_LIMIT_MIN}"; fi
                fi
                apply_rate_limit_config_live
                ;;
            3)
                echo -e "\n  a) 切换【多 IP 共享限速】开关 (当前: ${IP_LIMIT_ENABLE})"
                echo -e "  b) 切换【动态流量限速】开关 (当前: ${DYN_LIMIT_ENABLE})"
                echo -e "  c) 切换【管理员账号(admin)限速】开关 (当前: ${LIMIT_ADMIN})"
                local t_opt=""
                prompt_read "请选择要切换的开关 [a/b/c]: " t_opt || continue
                case "${t_opt}" in
                    a|A)
                        [[ "${IP_LIMIT_ENABLE}" == "true" ]] && IP_LIMIT_ENABLE="false" || IP_LIMIT_ENABLE="true"
                        apply_rate_limit_config_live
                        ;;
                    b|B)
                        [[ "${DYN_LIMIT_ENABLE}" == "true" ]] && DYN_LIMIT_ENABLE="false" || DYN_LIMIT_ENABLE="true"
                        apply_rate_limit_config_live
                        ;;
                    c|C)
                        [[ "${LIMIT_ADMIN}" == "true" ]] && LIMIT_ADMIN="false" || LIMIT_ADMIN="true"
                        apply_rate_limit_config_live
                        ;;
                esac
                ;;
            4)
                local in_int in_iface in_cport avail_ifaces
                avail_ifaces="$(list_available_ifaces)"
                prompt_read "请输入 Clash API 状态巡检轮询间隔秒数 (正整数，建议 3-10) [${CHECK_INTERVAL}]: " in_int || continue
                if [[ -n "${in_int}" ]]; then
                    if is_pos_int "${in_int}"; then CHECK_INTERVAL="${in_int}"; else warn "输入无效，保持原值 ${CHECK_INTERVAL}"; fi
                fi
                echo -e "  本机检测到可用网卡: ${CYAN}${avail_ifaces}${NC}"
                prompt_read "请输入限速绑定的物理网卡名称 [${NET_IFACE}]: " in_iface || continue
                if [[ -n "${in_iface}" ]]; then
                    if [[ -e "/sys/class/net/${in_iface}" ]]; then
                        NET_IFACE="${in_iface}"
                    else
                        warn "未找到网卡 ${in_iface}，保持原值 ${NET_IFACE}"
                    fi
                fi
                prompt_read "请输入内置 Clash API 监听端口 [${CLASH_API_PORT}]: " in_cport || continue
                if [[ -n "${in_cport}" ]]; then
                    if is_pos_int "${in_cport}"; then CLASH_API_PORT="${in_cport}"; else warn "输入无效，保持原值 ${CLASH_API_PORT}"; fi
                fi
                apply_rate_limit_config_live
                ;;
            5)
                show_connections_and_limits
                ;;
            6)
                python3 "${DAEMON_SCRIPT}" test-tc
                ;;
            7)
                python3 "${DAEMON_SCRIPT}" clear-tc
                info "已清空所有内核 TC 限速规则并重置受限用户状态！"
                ;;
            0|"")
                return 0
                ;;
            *)
                warn "无效选项 [${opt}]"
                ;;
        esac
    done
}

rollback_to_admin_only() {
    load_config
    write_python_daemon
    warn "正在将所有协议恢复为仅保留管理员默认账号状态，并清理 TC 限速..."
    local tmp_empty="/tmp/sb_empty_users.$$.json"
    echo '{"users":[]}' > "${tmp_empty}"
    python3 "${DAEMON_SCRIPT}" sync-file "${tmp_empty}" >/dev/null 2>&1 || true
    rm -f "${tmp_empty}"
    python3 "${DAEMON_SCRIPT}" clear-tc >/dev/null 2>&1 || true
    info "已恢复为管理员单用户状态并清空所有限速规则"
}

view_logs_menu() {
    echo -e "\n${BOLD}${CYAN}================ 日志与通信载荷查看工具 ================${NC}"
    echo "  1) 查看最近 50 行运行与限速日志"
    echo "  2) 实时追踪日志输出 (Ctrl+C 退出)"
    echo "  3) 查看最近一次面板 Register 响应 JSON"
    echo "  4) 查看最近一次面板 Push 推送 JSON"
    echo "  5) 清空历史日志"
    echo "  0) 返回主菜单"
    local log_opt=""
    prompt_read "请选择操作 [0-5]: " log_opt || return 0
    case "${log_opt}" in
        1) tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
        2) tail -f "${LOG_FILE}" ;;
        3) [[ -f "${CACHE_DIR}/last_register_response.json" ]] && cat "${CACHE_DIR}/last_register_response.json" || echo "暂无记录" ;;
        4) [[ -f "${CACHE_DIR}/last_push_payload.json" ]] && cat "${CACHE_DIR}/last_push_payload.json" || echo "暂无记录" ;;
        5) : > "${LOG_FILE}"; info "已清空日志" ;;
    esac
}

uninstall_all() {
    echo -e "\n${RED}${BOLD}⚠️  确认卸载 sb-rotator (v${VERSION}) 及其 Push 守护与限速规则吗？（不影响 sing-box 本身）${NC}"
    local confirm=""
    prompt_read "输入 y 确认卸载，其他键取消: " confirm || return 0
    [[ ! "${confirm}" =~ ^[Yy]$ ]] && { info "已取消卸载"; return 0; }
    stop_systemd_service
    rm -rf "${INSTALL_DIR}" "${LOCK_FILE}" "${OLD_CRON_FILE}" /usr/local/bin/sb-rotator /usr/local/bin/sbr
    echo -e "${GREEN}✅ sb-rotator 已卸载完成！${NC}"
    exit 0
}

main_menu() {
    load_config
    ensure_dirs
    ensure_daemon_latest
    while true; do
        load_config
        local daemon_status="${RED}未运行${NC}"
        if is_daemon_running; then
            daemon_status="${GREEN}运行中 (Push监听: ${AGENT_PORT} | 巡检每 ${CHECK_INTERVAL}s)${NC}"
        fi
        local user_cnt throttled_cnt clash_ok
        user_cnt="$(jq 'length' "${ACTIVE_USERS_FILE}" 2>/dev/null || echo 0)"
        throttled_cnt="$(jq '.throttled_users | length' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo 0)"
        clash_ok="$(jq -r 'if .clash_api_ok == true then "连通" else "未就绪" end' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo "未就绪")"

        local tc_status_str="${GREEN}就绪待命${NC}"
        if tc qdisc show dev "${NET_IFACE}" 2>/dev/null | grep -qE "qdisc htb 1: root"; then
            tc_status_str="${GREEN}HTB队列已生效${NC}"
        fi

        local ip_tag="${GREEN}开启${NC}"
        [[ "${IP_LIMIT_ENABLE:-true}" != "true" ]] && ip_tag="${RED}关闭${NC}"
        local dyn_tag="${GREEN}开启${NC}"
        [[ "${DYN_LIMIT_ENABLE:-true}" != "true" ]] && dyn_tag="${RED}关闭${NC}"

        echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
        echo -e "${BOLD}   233boy/sing-box 面板动态同步 & Clash API 限速管理面板 v${VERSION}${NC}"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        echo -e "  面板地址     : ${YELLOW}${PANEL_URL:-未配置}${NC} (Server ID: ${YELLOW}${SERVER_ID:-1}${NC})"
        echo -e "  Push回调地址 : ${YELLOW}${AGENT_URL:-未配置}${NC}"
        echo -e "  守护进程状态 : ${daemon_status}"
        echo -e "  在席合租用户 : ${GREEN}${user_cnt} 人${NC} (+ 管理员默认账号)"
        echo -e "  限速生效状态 : ClashAPI ${CYAN}${clash_ok}${NC} | 网卡 ${CYAN}${NET_IFACE}${NC} (${tc_status_str}) | 当前受限: ${BOLD}${RED}${throttled_cnt} 人${NC}"
        echo -e "  多IP限速参数 : [${ip_tag}] ${CYAN}活跃源 IP > ${IP_THRESHOLD} 个 -> 共享 ${LIMIT_MBPS}Mbps (窗口 ${ACTIVE_WINDOW_SEC}s)${NC}"
        echo -e "  动态限速参数 : [${dyn_tag}] ${CYAN}${DYN_WINDOW_MIN}分钟累计 >= ${DYN_THRESHOLD_GB}GB -> 共享 ${DYN_LIMIT_MBPS}Mbps (持续 ${DYN_LIMIT_MIN}分钟)${NC}"
        echo -e "-----------------------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 立即同步面板用户 (上报协议并同步在席用户)"
        echo -e "  ${GREEN}2.${NC} 查看协议默认链接与在席用户 (--status)"
        echo -e "  ${GREEN}3.${NC} 查看限速是否生效与实时连接监控 (--limits)"
        echo -e "  ${GREEN}4.${NC} 修改限速参数与限速管理 (多IP限速 / 动态流量限速)"
        echo -e "  ${GREEN}5.${NC} 修改面板对接配置 (面板地址 / 密钥 / Server ID)"
        echo -e "  ${GREEN}6.${NC} 重启后台守护服务 (sb-agent.service)"
        echo -e "  ${GREEN}7.${NC} 查看运行日志与通信载荷 (--logs)"
        echo -e "  ${GREEN}8.${NC} 恢复仅管理员默认账号状态 (--rollback)"
        echo -e "  ${RED}9.${NC} 一键卸载本程序 (--uninstall)"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        local choice=""
        prompt_read "请输入选项编号 [0-9]: " choice || exit 0
        case "${choice}" in
            1) python3 "${DAEMON_SCRIPT}" register ;;
            2) show_status_table ;;
            3) show_connections_and_limits ;;
            4) configure_rate_limit_menu ;;
            5) interactive_configure ;;
            6) setup_systemd_service ;;
            7) view_logs_menu ;;
            8) rollback_to_admin_only ;;
            9) uninstall_all ;;
            0|"") exit 0 ;;
            *) warn "无效选项 [${choice}]" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法: sb-rotator [选项] (快捷命令: sbr)

无参数                  打开交互式管理面板
--register              立即调用 POST /api/v1/server/register 上报协议默认链接并同步在席用户
--daemon                在前台运行 Push 回调监听与 Clash API 动态限速守护进程
--restart-daemon        重新释放最新守护脚本并重启 sb-agent.service
--status                查看本机所有协议默认链接与当前在席合租用户
--limits / --connections 查看当前限速参数、限速是否生效、各用户活跃 IP 与窗口流量统计
--limit-config          进入交互式限速参数修改与管理菜单
--test-limits           运行限速环境自检与内核 TC 限速规则下发实测
--clear-limits          立即清空网卡上的所有 TC 限速规则与受限状态
--config                进入交互式配置向导
--logs                  查看最近 50 行运行与限速日志
--rollback              恢复为仅管理员默认账号并清空限速
--uninstall             一键卸载本程序
EOF
}

ensure_dirs
write_python_daemon

case "${1:-}" in
    --register|--init|--run)   ensure_daemon_latest; python3 "${DAEMON_SCRIPT}" register ;;
    --daemon)                  python3 "${DAEMON_SCRIPT}" daemon ;;
    --restart-daemon)          setup_systemd_service ;;
    --status)                  show_status_table ;;
    --connections|--limits)    show_connections_and_limits ;;
    --limit-config)            configure_rate_limit_menu ;;
    --test-limits|--test-tc)   python3 "${DAEMON_SCRIPT}" test-tc ;;
    --dry-run)                 python3 "${DAEMON_SCRIPT}" dry-run ;;
    --sync-file)               python3 "${DAEMON_SCRIPT}" sync-file "${2:-}" ;;
    --poll-once)               python3 "${DAEMON_SCRIPT}" poll-once ;;
    --test-push)               python3 "${DAEMON_SCRIPT}" test-push ;;
    --clear-limits)            python3 "${DAEMON_SCRIPT}" clear-tc ;;
    --config)                  interactive_configure ;;
    --logs)                    tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
    --rollback)                rollback_to_admin_only ;;
    --uninstall)               uninstall_all ;;
    -h|--help)                 usage ;;
    "")                        main_menu ;;
    *)                         err "未知参数: $1"; usage; exit 1 ;;
esac

__EOF_SB_ROTATOR_CORE__

    chmod +x "${INSTALL_BIN}"
    ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
}

main() {
    check_root
    echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
    echo -e "${BOLD}   233boy/sing-box 面板动态同步 & Clash API 多IP/动态限速脚本 v3.1.2${NC}"
    echo -e "${BOLD}${CYAN}=================================================================${NC}"

    if [[ -x "${INSTALL_BIN}" && -f "${INSTALL_DIR}/config.env" && "${1:-}" == "" ]]; then
        echo -e "${GREEN}检测到本机已安装旧版或现有版本，请选择操作：${NC}"
        echo -e "  ${GREEN}1)${NC} 升级核心与守护进程至 v3.1.2 并打开管理面板 (保留现有配置)"
        echo -e "  ${GREEN}2)${NC} 升级核心与守护进程至 v3.1.2 并立即上报协议同步用户 (--register)"
        echo -e "  ${GREEN}3)${NC} 升级/重装至 v3.1.2 并重新运行配置向导 (--config)"
        echo -e "  ${RED}4)${NC} 一键卸载"
        echo -e "  ${GREEN}0)${NC} 退出"
        local exist_opt=""
        prompt_read "请选择 [0-4，默认 1]: " exist_opt || exit 0
        case "${exist_opt:-1}" in
            1)
                check_dependencies
                deploy_core_script
                "${INSTALL_BIN}" --restart-daemon
                exec "${INSTALL_BIN}"
                ;;
            2)
                check_dependencies
                deploy_core_script
                "${INSTALL_BIN}" --restart-daemon
                "${INSTALL_BIN}" --register || true
                exec "${INSTALL_BIN}"
                ;;
            3) ;;
            4) deploy_core_script; exec "${INSTALL_BIN}" --uninstall ;;
            0) exit 0 ;;
        esac
    fi

    check_dependencies
    deploy_core_script
    echo -e "${GREEN}[成功] 核心程序 v3.1.2 已安装至 ${INSTALL_BIN} (快捷命令: sbr)${NC}"

    "${INSTALL_BIN}" --config

    echo ""
    local do_reg=""
    prompt_read "是否立即向面板上报本机所有协议默认链接并同步合租用户？(y/n，默认 y): " do_reg || true
    if [[ "${do_reg:-y}" =~ ^[Yy]$ ]]; then
        "${INSTALL_BIN}" --register || true
    fi

    echo -e "\n${BOLD}${GREEN}=================================================================${NC}"
    echo -e "${BOLD}${GREEN} 🎉 v3.1.2 部署完成！随时输入 ${YELLOW}sbr${GREEN} 即可修改限速参数与查看限速生效状态${NC}"
    echo -e "${BOLD}${GREEN}=================================================================${NC}"
}

main "$@"
