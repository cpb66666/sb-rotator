#!/usr/bin/env bash
# ==============================================================================
# install.sh - 233boy/sing-box 面板动态合租同步 & Clash API 多IP共享限速 一键安装脚本 (v3.0.0)
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
    if [[ -t 0 ]]; then read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]]; then read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else read -rp "${prompt_str}" "${var_name}" || return 1; fi
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
# sb-rotator.sh - 233boy/sing-box 面板动态合租同步 & Clash API 多IP共享限速系统 (v3.0.0)
# 核心能力:
#   1. 自动扫描 /etc/sing-box/conf/*.json，提取管理员默认链接并通过 POST /api/v1/server/register 上报注册
#   2. 同步响应 & Push 回调监听 (POST /api/v1/sync): 按协议 cred_type (uuid/password) 动态注入/移除合租用户，保留管理员默认账号
#   3. 自动开启内置 Clash API (127.0.0.1:9090) + 注入 auth_user 路由标记，完整保留原 DNS 配置
#   4. 实时监控各用户名活跃源 IP 数量: 超过阈值 (默认 2) 时将该用户所有源 IP 加入共享限速集合 (默认合计 10Mbps)，恢复后自动移出
# ==============================================================================

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="3.0.0"
INSTALL_DIR="${INSTALL_DIR:-/etc/sb-rotator}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_DIR}/config.env}"
ADMIN_ACCOUNTS_FILE="${ADMIN_ACCOUNTS_FILE:-${INSTALL_DIR}/admin_accounts.json}"
ACTIVE_USERS_FILE="${ACTIVE_USERS_FILE:-${INSTALL_DIR}/active_users.json}"
RUNTIME_STATUS_FILE="${RUNTIME_STATUS_FILE:-${INSTALL_DIR}/runtime_status.json}"
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
    if [[ -t 0 ]]; then read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]]; then read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else read -rp "${prompt_str}" "${var_name}" || return 1; fi
}

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'; }

ensure_dirs() {
    mkdir -p "${INSTALL_DIR}" "${BACKUP_DIR}" "${CACHE_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
    [[ ! -f "${ADMIN_ACCOUNTS_FILE}" ]] && echo "{}" > "${ADMIN_ACCOUNTS_FILE}" 2>/dev/null || true
    [[ ! -f "${ACTIVE_USERS_FILE}" ]] && echo "[]" > "${ACTIVE_USERS_FILE}" 2>/dev/null || true
    [[ ! -f "${RUNTIME_STATUS_FILE}" ]] && echo "{}" > "${RUNTIME_STATUS_FILE}" 2>/dev/null || true
    chmod 600 "${CONFIG_FILE}" "${ADMIN_ACCOUNTS_FILE}" 2>/dev/null || true
    # 移除旧版换密定时任务（v3.0.0 不再使用定时换密）
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
    IP_THRESHOLD="2"
    LIMIT_MBPS="10"
    CHECK_INTERVAL="5"
    ACTIVE_WINDOW_SEC="15"
    LIMIT_ADMIN="false"
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
# sb-rotator v3.0.0 配置文件 (面板同步 + Clash API 动态限速)
PANEL_URL="${PANEL_URL}"
API_KEY="${API_KEY}"
SERVER_ID="${SERVER_ID:-1}"
AGENT_PORT="${AGENT_PORT:-18080}"
AGENT_URL="${AGENT_URL}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"
CLASH_API_SECRET="${CLASH_API_SECRET:-}"
IP_THRESHOLD="${IP_THRESHOLD:-2}"
LIMIT_MBPS="${LIMIT_MBPS:-10}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
ACTIVE_WINDOW_SEC="${ACTIVE_WINDOW_SEC:-15}"
LIMIT_ADMIN="${LIMIT_ADMIN:-false}"
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
        # 如果填了之前旧版的 /api/v1/node/rotate，自动修正为 /api/v1/server/register
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
sb_agent_daemon.py - 233boy/sing-box 节点注册、Push 同步回调与 Clash API 多IP共享限速守护进程 (v3.0.0)
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
from http.server import HTTPServer, BaseHTTPRequestHandler

INSTALL_DIR = os.environ.get("INSTALL_DIR", "/etc/sb-rotator")
CONFIG_FILE = os.environ.get("CONFIG_FILE", os.path.join(INSTALL_DIR, "config.env"))
ADMIN_ACCOUNTS_FILE = os.environ.get("ADMIN_ACCOUNTS_FILE", os.path.join(INSTALL_DIR, "admin_accounts.json"))
ACTIVE_USERS_FILE = os.environ.get("ACTIVE_USERS_FILE", os.path.join(INSTALL_DIR, "active_users.json"))
RUNTIME_STATUS_FILE = os.environ.get("RUNTIME_STATUS_FILE", os.path.join(INSTALL_DIR, "runtime_status.json"))
CACHE_DIR = os.environ.get("CACHE_DIR", os.path.join(INSTALL_DIR, "cache"))
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/sb-rotator.log")
SB_CONF_DIR = os.environ.get("SB_CONF_DIR", "/etc/sing-box/conf")
SB_GLOBAL_CONFIG = os.environ.get("SB_GLOBAL_CONFIG", "/etc/sing-box/config.json")

SYNC_LOCK = threading.Lock()
ANSI_RE = re.compile(r"\x1B\[[0-9;]*[a-zA-Z]|\r")
PROXY_URL_RE = re.compile(
    r"((?:vless|vmess|trojan|hysteria2|hy2|tuic|ss|shadowsocks|anytls|socks5?|hysteria)://[^\s\"']+)",
    re.IGNORECASE,
)
AD_BLACKLIST_RE = re.compile(r"(getjms\.com|233boy\.com|github\.com|t\.me)", re.IGNORECASE)
AUTH_USER_RULE_RE = re.compile(r"auth_user=\[?([^\s\]=>,]+)")


def now_cst_str():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(time.time() + 8 * 3600))


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
        "IP_THRESHOLD": "2",
        "LIMIT_MBPS": "10",
        "CHECK_INTERVAL": "5",
        "ACTIVE_WINDOW_SEC": "15",
        "LIMIT_ADMIN": "false",
        "NET_IFACE": "",
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
    """
    自动扫描 /etc/sing-box/conf/*.json，固定保存每个配置文件的管理员默认账号 (users[0])，
    并提取每个协议的管理员默认分享链接 (default_links & protocols)。
    """
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

        # 读取或固定管理员默认凭据
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

        # 提取默认分享链接：若当前 users 多于 1 人，临时写回单管理员用户供 233boy sing-box url 提取完整原生链接，随后立即恢复
        default_url = ""
        orig_users = ib.get("users")
        need_temp_single = isinstance(orig_users, list) and len(orig_users) > 1
        try:
            if need_temp_single:
                single_admin = dict(extra_fields or {})
                single_admin[cred_type] = admin_cred
                ib["users"] = [single_admin]
                save_json_file(fpath, conf)

            for cmd_args in (["url", shortname], ["url", str(port)], ["info", shortname]):
                out = run_sb_cmd(cmd_args, idx=idx, timeout_sec=6)
                default_url = extract_proxy_url(out)
                if default_url:
                    break
        finally:
            if need_temp_single:
                ib["users"] = orig_users
                save_json_file(fpath, conf)

        if not default_url:
            default_url = saved.get("default_url") or build_fallback_url(proto, port, admin_cred, shortname, ib, srv_ip)

        # 确保默认链接中的凭据为管理员默认凭据
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
    """
    在 /etc/sing-box/config.json 中开启内置 Clash API (127.0.0.1:9090)，
    并为所有活跃用户注入 auth_user 路由规则以便 Clash API /connections 精确上报每个连接的归属用户名。
    注意：严格保留用户原有的 log、dns、outbounds 等全局配置！
    """
    clash_port = cfg.get("CLASH_API_PORT", "9090")
    clash_secret = cfg.get("CLASH_API_SECRET", "")
    controller_addr = f"127.0.0.1:{clash_port}"

    global_conf = load_json_file(SB_GLOBAL_CONFIG, {})
    if not isinstance(global_conf, dict):
        global_conf = {}

    orig_serialized = json.dumps(global_conf, sort_keys=True, ensure_ascii=False)

    # 1. 确保 outbounds 至少有一个带 tag 的默认出站 (233boy 默认是 direct)
    outbounds = global_conf.get("outbounds")
    if not isinstance(outbounds, list) or len(outbounds) == 0:
        outbounds = [{"type": "direct", "tag": "direct"}]
        global_conf["outbounds"] = outbounds
    if not isinstance(outbounds[0], dict):
        outbounds[0] = {"type": "direct", "tag": "direct"}
    if not outbounds[0].get("tag"):
        outbounds[0]["tag"] = outbounds[0].get("type") or "direct"
    default_out_tag = outbounds[0]["tag"]

    # 2. 开启内置 Clash API
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

    # 3. 维护 route.rules 中的 auth_user 规则（保留原有的非纯 auth_user 路由规则）
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
        # 仅由本脚本生成的纯 auth_user -> outbound 追踪规则会在每次同步时重建
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


def reload_singbox():
    """直接调用系统服务管理器平滑重启 sing-box，绝不调用 fix-config.json"""
    try:
        if os.path.isdir("/run/systemd/system"):
            subprocess.run(["systemctl", "restart", "sing-box"], timeout=15, check=False)
            time.sleep(1)
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


def sync_users_to_singbox(payload_data, cfg=None):
    """
    核心用户同步逻辑：
    - 遍历本机协议配置文件 (/etc/sing-box/conf/*.json)
    - 保留管理员默认账号 (users[0], name="admin")
    - 根据协议 cred_type ("uuid" 或 "password") 为有效合租用户注入对应凭据 (name=user.email)
    - 移除不在 users 列表中的历史合租用户及已过期用户
    """
    with SYNC_LOCK:
        if cfg is None:
            cfg = load_env_config()

        # 兼容顶层或 data 包裹格式
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

        # 先确保管理员默认账号已初始化
        discover_and_get_default_protocols()
        admin_accounts = load_json_file(ADMIN_ACCOUNTS_FILE, {})

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
            # 1) 保留管理员默认账号在首位
            admin_obj = dict(extra_fields)
            admin_obj["name"] = "admin"
            admin_obj[cred_type] = admin_cred
            if proto == "tuic" and "password" not in admin_obj:
                admin_obj["password"] = first_u.get("password") or admin_cred
            new_users_arr.append(admin_obj)

            seen_creds = {admin_cred}
            seen_names = {"admin"}

            # 2) 注入全量在席合租用户
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

        if any_conf_changed or global_changed:
            reload_singbox()

        log("INFO", f"已完成节点用户同步：当前在席合租用户 {len(valid_users)} 人 (+ 管理员默认账号)")
        return True, f"synced {len(valid_users)} users across {len(files)} protocols", len(valid_users)


def compute_hmac_sha256(secret, message):
    return hmac.new(secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def register_with_panel(dry_run=False):
    """
    接口一：POST /api/v1/server/register
    上报本机 server_id、agent_url、replace_all、default_links 与 protocols，
    并立即处理同步响应中的 data.users 完成首次用户初始化。
    """
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
        print("\n=== [演练模式] POST " + endpoint + " 请求载荷 ===")
        print(payload_str)
        print("=====================================================")
        return True

    # 确保 Clash API 已开启
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
        "User-Agent": "sb-agent/3.0.0",
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
# Clash API 活跃连接监控 & Linux TC HTB 多源IP共享限速引擎
# ==============================================================================

class ClashRateLimiter:
    def __init__(self):
        self.user_ip_last_seen = {}   # {username: {ip: timestamp}}
        self.throttled_users = {}     # {username: {"cid": int, "ips": list, "limit_mbps": int, "since": int}}
        self.user_cid_map = {}        # {username: int (10..899)}
        self.next_cid = 10
        self.tc_initialized_iface = None

    def _get_cid(self, username):
        if username not in self.user_cid_map:
            cid = self.next_cid
            self.next_cid = 10 if self.next_cid >= 890 else (self.next_cid + 1)
            self.user_cid_map[username] = cid
        return self.user_cid_map[username]

    def ensure_tc_root(self, iface):
        if self.tc_initialized_iface == iface:
            return
        try:
            for mod in ("sch_htb", "sch_sfq", "cls_u32"):
                try:
                    subprocess.run(["modprobe", mod], stderr=subprocess.DEVNULL, check=False)
                except Exception:
                    pass
            subprocess.run(["tc", "qdisc", "replace", "dev", iface, "root", "handle", "1:", "htb", "default", "999"], stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["tc", "class", "replace", "dev", iface, "parent", "1:", "classid", "1:1", "htb", "rate", "10000mbit", "ceil", "10000mbit"], stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", "1:999", "htb", "rate", "10000mbit", "ceil", "10000mbit"], stderr=subprocess.DEVNULL, check=False)
            self.tc_initialized_iface = iface
        except Exception as e:
            log("WARN", f"初始化网卡 {iface} TC HTB 队列失败: {e}")

    def apply_user_limit(self, iface, username, ips, limit_mbps):
        self.ensure_tc_root(iface)
        cid = self._get_cid(username)
        rate_str = f"{max(1, int(limit_mbps))}mbit"
        try:
            # 1) 为该用户创建或更新共享的 HTB 子类 1:{cid} (该用户名下所有源 IP 共享此带宽池)
            subprocess.run(
                ["tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", f"1:{cid}", "htb", "rate", rate_str, "ceil", rate_str, "burst", "128k", "cburst", "128k"],
                stderr=subprocess.DEVNULL,
                check=False,
            )
            subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{cid}", "handle", f"{cid}:", "sfq", "perturb", "10"],
                stderr=subprocess.DEVNULL,
                check=False,
            )
            # 2) 先清空该用户 prio={cid} 的旧 IP 过滤规则，再写入最新活跃 IP 列表
            subprocess.run(
                ["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)],
                stderr=subprocess.DEVNULL,
                check=False,
            )
            for ip in ips:
                if ":" in ip:
                    subprocess.run(
                        ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ipv6", "prio", str(cid), "u32", "match", "ip6", "dst", f"{ip}/128", "flowid", f"1:{cid}"],
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
                else:
                    subprocess.run(
                        ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip", "prio", str(cid), "u32", "match", "ip", "dst", f"{ip}/32", "flowid", f"1:{cid}"],
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
        except Exception as e:
            log("WARN", f"为用户 {username} 应用 TC 限速规则异常: {e}")

    def remove_user_limit(self, iface, username):
        cid = self.user_cid_map.get(username)
        if not cid:
            return
        try:
            subprocess.run(["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)], stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "parent", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["tc", "class", "del", "dev", iface, "parent", "1:1", "classid", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False)
        except Exception:
            pass

    @staticmethod
    def clear_all_tc(iface):
        try:
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "root"], stderr=subprocess.DEVNULL, check=False)
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
        cfg = load_env_config()
        clash_port = cfg.get("CLASH_API_PORT", "9090")
        clash_secret = cfg.get("CLASH_API_SECRET", "")
        iface = cfg.get("NET_IFACE") or detect_default_iface()
        try:
            ip_threshold = max(1, int(cfg.get("IP_THRESHOLD", "2")))
        except ValueError:
            ip_threshold = 2
        try:
            default_limit_mbps = max(1, int(cfg.get("LIMIT_MBPS", "10")))
        except ValueError:
            default_limit_mbps = 10
        try:
            active_window = max(3, int(cfg.get("ACTIVE_WINDOW_SEC", "15")))
        except ValueError:
            active_window = 15
        limit_admin = cfg.get("LIMIT_ADMIN", "false").lower() == "true"

        url = f"http://127.0.0.1:{clash_port}/connections"
        headers = {}
        if clash_secret:
            headers["Authorization"] = f"Bearer {clash_secret}"

        try:
            req = urllib.request.Request(url, headers=headers, method="GET")
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
        except Exception:
            return

        conns = data.get("connections") or []
        now = time.time()

        for c in conns:
            if not isinstance(c, dict):
                continue
            user, src_ip = self.extract_user_and_ip(c)
            if not user or not src_ip:
                continue
            if user == "admin" and not limit_admin:
                continue
            self.user_ip_last_seen.setdefault(user, {})[src_ip] = now

        # 清理超过活跃时间窗口的旧 IP 记录
        active_user_ips = {}
        for user in list(self.user_ip_last_seen.keys()):
            ip_map = self.user_ip_last_seen[user]
            for ip in list(ip_map.keys()):
                if now - ip_map[ip] > active_window:
                    del ip_map[ip]
            if not ip_map:
                del self.user_ip_last_seen[user]
            else:
                active_user_ips[user] = sorted(ip_map.keys())

        # 读取用户自定义限速配置
        user_custom_mbps = {}
        for u in load_json_file(ACTIVE_USERS_FILE, []):
            if isinstance(u, dict) and u.get("email") and int(u.get("speed_limit_bps") or 0) > 0:
                user_custom_mbps[u["email"]] = max(1, int(u["speed_limit_bps"]) // 1_000_000)

        # 评估哪些用户超出源 IP 数量阈值
        currently_exceeded = set()
        for user, ips in active_user_ips.items():
            if len(ips) > ip_threshold:
                currently_exceeded.add(user)
                limit_val = user_custom_mbps.get(user, default_limit_mbps)
                prev = self.throttled_users.get(user)
                if not prev or prev.get("ips") != ips or prev.get("limit_mbps") != limit_val:
                    self.apply_user_limit(iface, user, ips, limit_val)
                    self.throttled_users[user] = {
                        "cid": self._get_cid(user),
                        "ips": ips,
                        "ip_count": len(ips),
                        "limit_mbps": limit_val,
                        "since": prev["since"] if prev else int(now),
                    }
                    if not prev:
                        log("WARN", f"[触发限速] 用户 [{user}] 活跃源 IP 数 ({len(ips)}) > 阈值 ({ip_threshold}) | IPs: {', '.join(ips)} -> 已加入共享 {limit_val}Mbps 限速集合")

        # 评估已恢复正常的用户并自动移出限速集合
        for user in list(self.throttled_users.keys()):
            if user not in currently_exceeded:
                self.remove_user_limit(iface, user)
                del self.throttled_users[user]
                rem_ips = active_user_ips.get(user, [])
                log("INFO", f"[解除限速] 用户 [{user}] 活跃源 IP 数已恢复正常 ({len(rem_ips)} <= {ip_threshold}) -> 已移出限速集合")

        # 保存实时监控快照供 CLI 查看
        status_snapshot = {
            "updated_at": int(now),
            "updated_at_cst": now_cst_str(),
            "clash_api": f"127.0.0.1:{clash_port}",
            "iface": iface,
            "ip_threshold": ip_threshold,
            "default_limit_mbps": default_limit_mbps,
            "total_connections": len(conns),
            "active_users": {u: {"ip_count": len(ips), "ips": ips} for u, ips in active_user_ips.items()},
            "throttled_users": self.throttled_users,
        }
        save_json_file(RUNTIME_STATUS_FILE, status_snapshot)


RATE_LIMITER = ClashRateLimiter()


# ==============================================================================
# 接口二：Push 回调 HTTP Server (监听 POST /api/v1/sync)
# ==============================================================================

class PushWebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/api/v1/health", "/ping"):
            status = load_json_file(RUNTIME_STATUS_FILE, {})
            self._send_json(200, {"ok": True, "version": "3.0.0", "status": status})
        else:
            self._send_json(404, {"ok": False, "message": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") not in ("/api/v1/sync", "/api/v1/node/sync", "/sync"):
            self._send_json(404, {"ok": False, "message": "unknown endpoint"})
            return

        cfg = load_env_config()
        secret = cfg.get("API_KEY", "")
        expected_sid = str(cfg.get("SERVER_ID", "")).strip()

        content_len = int(self.headers.get("Content-Length") or 0)
        raw_body = self.rfile.read(content_len).decode("utf-8", errors="replace") if content_len > 0 else "{}"

        # 校验 X-Server-Id / X-Node-Id (若请求头携带)
        hdr_sid = (self.headers.get("X-Server-Id") or self.headers.get("X-Node-Id") or "").strip()
        if hdr_sid and expected_sid and hdr_sid != expected_sid:
            log("WARN", f"[Push拒绝] 请求头 X-Server-Id ({hdr_sid}) 与本机配置 ({expected_sid}) 不匹配")
            self._send_json(403, {"ok": False, "message": "server_id mismatch"})
            return

        # 校验 Bearer Token 或 HMAC-SHA256 签名 (X-Dujiao-Signature / X-Signature)
        auth_hdr = (self.headers.get("Authorization") or "").strip()
        api_key_hdr = (self.headers.get("X-API-Key") or "").strip()
        ts_hdr = (self.headers.get("X-Dujiao-Timestamp") or self.headers.get("X-Timestamp") or "").strip()
        sig_hdr = (self.headers.get("X-Dujiao-Signature") or self.headers.get("X-Signature") or "").strip()
        if sig_hdr.startswith("sha256="):
            sig_hdr = sig_hdr[7:]

        authed = False
        if not secret:
            authed = True
        else:
            if auth_hdr == f"Bearer {secret}" or api_key_hdr == secret:
                authed = True
            elif sig_hdr:
                candidates = [
                    compute_hmac_sha256(secret, f"{ts_hdr}.{raw_body}"),
                    compute_hmac_sha256(secret, f"{ts_hdr}\n{raw_body}"),
                    compute_hmac_sha256(secret, f"{ts_hdr}{raw_body}"),
                    compute_hmac_sha256(secret, raw_body),
                ]
                if any(hmac.compare_digest(sig_hdr.lower(), c.lower()) for c in candidates):
                    authed = True

        if not authed:
            log("WARN", f"[Push拒绝] 来自 {self.client_address[0]} 的推送签名/密钥校验失败")
            self._send_json(401, {"ok": False, "message": "unauthorized"})
            return

        try:
            payload = json.loads(raw_body)
        except Exception as e:
            self._send_json(400, {"ok": False, "message": f"invalid json: {e}"})
            return

        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(os.path.join(CACHE_DIR, "last_push_payload.json"), "w", encoding="utf-8") as f:
            f.write(raw_body)

        log("STEP", f"收到面板 Push 同步请求 (来源: {self.client_address[0]})")
        ok, msg, count = sync_users_to_singbox(payload, cfg)
        if ok:
            self._send_json(200, {"ok": True, "message": msg, "synced_users": count})
        else:
            self._send_json(500, {"ok": False, "message": msg})


def run_daemon():
    cfg = load_env_config()
    port = int(cfg.get("AGENT_PORT") or 18080)
    log("INFO", f"启动 sb-agent 守护进程 (v3.0.0) | Push 监听端口: {port} | 限速阈值: >{cfg.get('IP_THRESHOLD', '2')} IPs -> 共享 {cfg.get('LIMIT_MBPS', '10')}Mbps")

    # 启动时自动向面板执行一次协议上报与全量用户初始化
    if cfg.get("PANEL_URL") and cfg.get("API_KEY"):
        threading.Thread(target=register_with_panel, kwargs={"dry_run": False}, daemon=True).start()
    else:
        discover_and_get_default_protocols()
        ensure_clash_api_and_user_routes([], cfg)

    # 启动后台 Clash API 连接轮询与动态限速线程
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

    server = HTTPServer(("0.0.0.0", port), PushWebhookHandler)
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
    elif cmd == "clear-tc":
        cfg = load_env_config()
        ClashRateLimiter.clear_all_tc(cfg.get("NET_IFACE") or detect_default_iface())
        log("INFO", "已清理网卡 TC HTB 限速规则")
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
}

setup_systemd_service() {
    load_config
    write_python_daemon
    open_firewall_port "${AGENT_PORT:-18080}"

    if [[ -d /run/systemd/system ]]; then
        cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sb-agent v3.0.0 (sing-box Panel Sync & Clash API Rate Limiter)
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
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable sb-agent.service >/dev/null 2>&1 || true
        systemctl restart sb-agent.service >/dev/null 2>&1 || true
        info "已部署并启动后台守护服务 sb-agent.service (Push 回调端口: ${AGENT_PORT:-18080})"
    else
        pkill -f "${DAEMON_SCRIPT}" 2>/dev/null || true
        nohup python3 "${DAEMON_SCRIPT}" daemon >> "${LOG_FILE}" 2>&1 &
        info "已在后台启动 sb-agent 守护进程 (Push 回调端口: ${AGENT_PORT:-18080})"
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
# 状态展示、实时连接与限速面板
# ==============================================================================

show_status_table() {
    load_config
    ensure_dirs
    write_python_daemon

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
    write_python_daemon
    python3 "${DAEMON_SCRIPT}" poll-once >/dev/null 2>&1 || true

    echo -e "\n${BOLD}${CYAN}================ Clash API 实时活跃连接与多 IP 限速状态 ================${NC}"
    if [[ ! -f "${RUNTIME_STATUS_FILE}" ]] || [[ "$(jq -r '.updated_at // 0' "${RUNTIME_STATUS_FILE}" 2>/dev/null)" == "0" ]]; then
        echo -e "${YELLOW}暂无 Clash API 实时采样数据 (请确认 sing-box 与 sb-agent 正在运行)${NC}"
        echo "================================================================================"
        return 0
    fi

    local updated_cst total_conns iface thresh limit_m
    updated_cst="$(jq -r '.updated_at_cst // "-"' "${RUNTIME_STATUS_FILE}")"
    total_conns="$(jq -r '.total_connections // 0' "${RUNTIME_STATUS_FILE}")"
    iface="$(jq -r '.iface // "eth0"' "${RUNTIME_STATUS_FILE}")"
    thresh="$(jq -r '.ip_threshold // 2' "${RUNTIME_STATUS_FILE}")"
    limit_m="$(jq -r '.default_limit_mbps // 10' "${RUNTIME_STATUS_FILE}")"

    echo -e "采样时间: ${updated_cst} CST | 活跃总连接数: ${BOLD}${total_conns}${NC} | 限速网卡: ${iface}"
    echo -e "限速策略: 单用户名活跃源 IP 数 > ${BOLD}${YELLOW}${thresh}${NC} 时，该用户所有源 IP 合计限速 ${BOLD}${RED}${limit_m}Mbps${NC}"
    echo "--------------------------------------------------------------------------------"
    echo -e "${BOLD}[各用户当前活跃源 IP 分布]${NC}"
    local active_len
    active_len="$(jq '.active_users | length' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo 0)"
    if (( active_len == 0 )); then
        echo "  当前无活跃合租用户连接"
    else
        jq -r '.active_users | to_entries[] | "  • 用户: \(.key) | 活跃源 IP 数: \(.value.ip_count) | IPs: \(.value.ips | join(", "))"' "${RUNTIME_STATUS_FILE}"
    fi

    echo "--------------------------------------------------------------------------------"
    echo -e "${BOLD}[当前处于限速集合中的用户]${NC}"
    local th_len
    th_len="$(jq '.throttled_users | length' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo 0)"
    if (( th_len == 0 )); then
        echo -e "  ${GREEN}当前无任何用户触发限速${NC}"
    else
        jq -r '.throttled_users | to_entries[] | "  ⚠️  用户: \(.key) | 共享限速: \(.value.limit_mbps)Mbps (TC Class 1:\(.value.cid)) | 受限源 IPs (\(.value.ip_count)): \(.value.ips | join(", "))"' "${RUNTIME_STATUS_FILE}"
    fi
    echo "================================================================================"
}

# ==============================================================================
# 交互式配置向导
# ==============================================================================

interactive_configure() {
    load_config
    write_python_daemon
    echo -e "\n${BOLD}${BLUE}>>> 配置 sb-rotator v${VERSION} (面板自动注册 + Push 回调 + Clash API 限速) <<<${NC}"
    show_status_table || true

    local srv_ip
    srv_ip="$(get_server_ip)"

    local in_url in_key in_sid in_port in_agent_url in_thresh in_mbps
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

    prompt_read "6. 请输入单用户名触发限速的活跃源 IP 数量阈值 (默认 ${IP_THRESHOLD:-2}) [${IP_THRESHOLD:-2}]: " in_thresh || return 1
    IP_THRESHOLD="${in_thresh:-${IP_THRESHOLD:-2}}"

    prompt_read "7. 请输入触发限速后该用户所有源 IP 合计共享带宽 (Mbps，默认 ${LIMIT_MBPS:-10}) [${LIMIT_MBPS:-10}]: " in_mbps || return 1
    LIMIT_MBPS="${in_mbps:-${LIMIT_MBPS:-10}}"

    save_config
    setup_systemd_service
    info "配置已保存至 ${CONFIG_FILE}"
}

configure_rate_limit_menu() {
    load_config
    echo -e "\n${BOLD}${CYAN}================ 动态限速参数配置与管理 ================${NC}"
    echo -e "  当前触发阈值     : 单个用户名活跃源 IP 数量 > ${YELLOW}${IP_THRESHOLD}${NC} 个"
    echo -e "  当前共享限速带宽 : 该用户名下所有源 IP 合计 ${YELLOW}${LIMIT_MBPS} Mbps${NC}"
    echo -e "  Clash API 端口   : ${YELLOW}127.0.0.1:${CLASH_API_PORT}${NC}"
    echo -e "  限速绑定网卡     : ${YELLOW}${NET_IFACE}${NC}"
    echo "--------------------------------------------------------"
    echo "  1) 修改触发限速的源 IP 数量阈值与共享限速带宽 (Mbps)"
    echo "  2) 立即清空当前所有 TC 限速规则"
    echo "  0) 返回主菜单"
    local opt=""
    prompt_read "请选择 [0-2]: " opt || return 0
    case "${opt}" in
        1)
            local in_t in_m in_w
            prompt_read "请输入单用户名触发限速的活跃源 IP 数量阈值 [${IP_THRESHOLD}]: " in_t || return 0
            IP_THRESHOLD="${in_t:-${IP_THRESHOLD}}"
            prompt_read "请输入该用户所有源 IP 合计共享限速带宽 (Mbps) [${LIMIT_MBPS}]: " in_m || return 0
            LIMIT_MBPS="${in_m:-${LIMIT_MBPS}}"
            prompt_read "请输入源 IP 活跃判定窗口秒数 (默认 ${ACTIVE_WINDOW_SEC}) [${ACTIVE_WINDOW_SEC}]: " in_w || return 0
            ACTIVE_WINDOW_SEC="${in_w:-${ACTIVE_WINDOW_SEC}}"
            save_config
            setup_systemd_service
            info "限速参数已更新并重启守护进程生效！"
            ;;
        2)
            write_python_daemon
            python3 "${DAEMON_SCRIPT}" clear-tc
            ;;
    esac
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
    echo -e "\n${RED}${BOLD}⚠️  确认卸载 sb-rotator (v3.0.0) 及其 Push 守护与限速规则吗？（不影响 sing-box 本身）${NC}"
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
    write_python_daemon
    while true; do
        load_config
        local daemon_status="${RED}未运行${NC}"
        if systemctl is-active --quiet sb-agent.service 2>/dev/null || pgrep -f "${DAEMON_SCRIPT}" >/dev/null 2>&1; then
            daemon_status="${GREEN}运行中 (Push监听: ${AGENT_PORT} | ClashAPI巡检每 ${CHECK_INTERVAL}s)${NC}"
        fi
        local user_cnt throttled_cnt
        user_cnt="$(jq 'length' "${ACTIVE_USERS_FILE}" 2>/dev/null || echo 0)"
        throttled_cnt="$(jq '.throttled_users | length' "${RUNTIME_STATUS_FILE}" 2>/dev/null || echo 0)"

        echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
        echo -e "${BOLD}   233boy/sing-box 面板动态同步 & Clash API 限速管理面板 v${VERSION}${NC}"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        echo -e "  面板地址     : ${YELLOW}${PANEL_URL:-未配置}${NC}"
        echo -e "  服务器 ID    : ${YELLOW}${SERVER_ID:-1}${NC}"
        echo -e "  Push回调地址 : ${YELLOW}${AGENT_URL:-未配置}${NC}"
        echo -e "  守护进程状态 : ${daemon_status}"
        echo -e "  在席合租用户 : ${GREEN}${user_cnt} 人${NC} (+ 管理员默认账号)"
        echo -e "  多IP限速策略 : ${CYAN}活跃源 IP > ${IP_THRESHOLD} 自动限速合计 ${LIMIT_MBPS}Mbps${NC} (当前受限: ${RED}${throttled_cnt} 人${NC})"
        echo -e "-----------------------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 立即向面板上报本机协议并同步用户 (POST /api/v1/server/register)"
        echo -e "  ${GREEN}2.${NC} 查看本机协议默认链接与在席合租用户列表 (--status)"
        echo -e "  ${GREEN}3.${NC} 查看 Clash API 实时活跃连接、各用户源 IP 与限速集合 (--connections)"
        echo -e "  ${GREEN}4.${NC} 修改多 IP 限速配置 (阈值 IP 数 / 共享带宽 Mbps / 清空限速)"
        echo -e "  ${GREEN}5.${NC} 修改面板对接配置 (面板地址 / Secret / Server ID / Push 端口)"
        echo -e "  ${GREEN}6.${NC} 演练模式 (Dry-Run：预览上报面板的 Register JSON 载荷)"
        echo -e "  ${GREEN}7.${NC} 重启后台 Push 监听与动态限速守护服务 (sb-agent.service)"
        echo -e "  ${GREEN}8.${NC} 查看运行日志与最近接收的 Push 载荷 (--logs)"
        echo -e "  ${GREEN}9.${NC} 紧急恢复为仅保留管理员默认账号状态 (--rollback)"
        echo -e "  ${RED}10.${NC} 一键卸载本程序 (--uninstall)"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        local choice=""
        prompt_read "请输入选项编号 [0-10]: " choice || exit 0
        case "${choice}" in
            1) python3 "${DAEMON_SCRIPT}" register ;;
            2) show_status_table ;;
            3) show_connections_and_limits ;;
            4) configure_rate_limit_menu ;;
            5) interactive_configure ;;
            6) python3 "${DAEMON_SCRIPT}" dry-run ;;
            7) setup_systemd_service ;;
            8) view_logs_menu ;;
            9) rollback_to_admin_only ;;
            10) uninstall_all ;;
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
--status                查看本机所有协议默认链接与当前在席合租用户
--connections           查看 Clash API 实时活跃连接、各用户源 IP 统计与当前限速集合
--dry-run               预览上报给 POST /api/v1/server/register 的 JSON 载荷
--clear-limits          立即清空网卡上的所有 TC 限速规则
--config                进入交互式配置向导
--logs                  查看最近 50 行运行与限速日志
--rollback              恢复为仅管理员默认账号并清空限速
--uninstall             一键卸载本程序
EOF
}

ensure_dirs
write_python_daemon

case "${1:-}" in
    --register|--init|--run) python3 "${DAEMON_SCRIPT}" register ;;
    --daemon)                python3 "${DAEMON_SCRIPT}" daemon ;;
    --status)                show_status_table ;;
    --connections|--limits)  show_connections_and_limits ;;
    --dry-run)               python3 "${DAEMON_SCRIPT}" dry-run ;;
    --sync-file)             python3 "${DAEMON_SCRIPT}" sync-file "${2:-}" ;;
    --poll-once)             python3 "${DAEMON_SCRIPT}" poll-once ;;
    --clear-limits)          python3 "${DAEMON_SCRIPT}" clear-tc ;;
    --config)                interactive_configure ;;
    --logs)                  tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
    --rollback)              rollback_to_admin_only ;;
    --uninstall)             uninstall_all ;;
    -h|--help)               usage ;;
    "")                      main_menu ;;
    *)                       err "未知参数: $1"; usage; exit 1 ;;
esac

__EOF_SB_ROTATOR_CORE__

    chmod +x "${INSTALL_BIN}"
    ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
}

main() {
    check_root
    echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
    echo -e "${BOLD}   233boy/sing-box 面板动态同步 & Clash API 多IP限速一键脚本 v3.0.0${NC}"
    echo -e "${BOLD}${CYAN}=================================================================${NC}"

    if [[ -x "${INSTALL_BIN}" && -f "${INSTALL_DIR}/config.env" && "${1:-}" == "" ]]; then
        echo -e "${GREEN}检测到本机已安装旧版或现有版本，请选择操作：${NC}"
        echo -e "  ${GREEN}1)${NC} 升级/重装至 v3.0.0 并引导配置面板对接与多 IP 限速"
        echo -e "  ${GREEN}2)${NC} 升级核心脚本至 v3.0.0 并立即上报协议同步用户 (--register)"
        echo -e "  ${GREEN}3)${NC} 打开管理面板"
        echo -e "  ${RED}4)${NC} 一键卸载"
        echo -e "  ${GREEN}0)${NC} 退出"
        local exist_opt=""
        prompt_read "请选择 [0-4，默认 1]: " exist_opt || exit 0
        case "${exist_opt:-1}" in
            1) ;;
            2)
                check_dependencies
                deploy_core_script
                "${INSTALL_BIN}" --register || true
                exec "${INSTALL_BIN}"
                ;;
            3)
                check_dependencies
                deploy_core_script
                exec "${INSTALL_BIN}"
                ;;
            4) deploy_core_script; exec "${INSTALL_BIN}" --uninstall ;;
            0) exit 0 ;;
        esac
    fi

    check_dependencies
    deploy_core_script
    echo -e "${GREEN}[成功] 核心程序 v3.0.0 已安装至 ${INSTALL_BIN} (快捷命令: sbr)${NC}"

    "${INSTALL_BIN}" --config

    echo ""
    local do_reg=""
    prompt_read "是否立即向面板上报本机所有协议默认链接并同步合租用户？(y/n，默认 y): " do_reg || true
    if [[ "${do_reg:-y}" =~ ^[Yy]$ ]]; then
        "${INSTALL_BIN}" --register || true
    fi

    echo -e "\n${BOLD}${GREEN}=================================================================${NC}"
    echo -e "${BOLD}${GREEN} 🎉 v3.0.0 部署完成！随时输入 ${YELLOW}sbr${GREEN} 即可查看协议、用户与实时限速状态${NC}"
    echo -e "${BOLD}${GREEN}=================================================================${NC}"
}

main "$@"
