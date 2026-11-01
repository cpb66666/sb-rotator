#!/usr/bin/env bash
# ==============================================================================
# ip-limiter.sh - Linux 客户端 IP 流量滥用动态限速系统 (提取优化自 sing-box 限速核心)
# 
# 机制:
#   1. 非固定限速: 正常使用完全不限速 (走 10000Mbps 极速直连通道)
#   2. 滑动窗口监控: 统计每个客户端 IP 在设定窗口内 (默认 20 分钟) 的累计使用流量
#   3. 滥用自动惩罚: 20 分钟内流量超过阈值 (如 1.0GB) 自动触发限速 (如 10Mbps)，限速持续 20 分钟
#   4. 到期自动解封: 惩罚时长倒计时归零后，内核自动释放 TC 限速规则，恢复满速直连
#   5. 双引擎兼容: 优先直连 Clash API (sing-box/clash)，同时支持系统层网络监控
#   6. 规则持久化: 服务重启不丢失封禁状态与滑动窗口流量历史
# ==============================================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="2.0.0"
INSTALL_BIN="/usr/local/bin/ip-limiter"
ALIAS_BIN="/usr/local/bin/iplim"
INSTALL_DIR="/etc/ip-limiter"
CONFIG_FILE="${INSTALL_DIR}/config.env"
DAEMON_SCRIPT="${INSTALL_DIR}/ip_limiter_daemon.py"
SERVICE_FILE="/etc/systemd/system/ip-limiter.service"
RUNTIME_STATUS_FILE="${INSTALL_DIR}/runtime_status.json"
TRAFFIC_STATE_FILE="${INSTALL_DIR}/traffic_window.json"
LOG_FILE="/var/log/ip-limiter.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
    for cmd in python3 tc ip ss curl awk grep sed; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${YELLOW}[提示] 正在安装必要系统依赖 (${missing[*]}) ...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y iproute2 python3 curl sed gawk grep iptables tzdata >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute python3 curl sed gawk grep iptables tzdata >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash iproute2 python3 curl sed gawk grep iptables tzdata >/dev/null 2>&1
        fi
    fi
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

load_config() {
    LIMIT_ENABLE="true"
    DYN_WINDOW_MIN="20"          # 流量统计滑动时间窗口 (分钟，默认 20 分钟)
    DYN_THRESHOLD_GB="1.0"       # 窗口内流量超额阈值 (GB，超标即触发限速)
    DYN_LIMIT_MBPS="10"          # 触发滥用后的限制带宽 (Mbps，默认 10Mbps)
    DYN_PUNISH_MIN="20"          # 触发限速后的持续时间 (分钟，默认 20 分钟)
    CHECK_INTERVAL="3"           # 巡检与流量采样周期 (秒，默认 3 秒)
    ACTIVE_WINDOW_SEC="20"       # 连接判定活跃时间 (秒)
    CONN_SOURCE="auto"           # auto (优先 Clash API，其次系统连接) / clash / system
    CLASH_API_PORT="9090"        # Clash API 端口 (默认 9090)
    CLASH_API_SECRET=""          # Clash API Secret (无则留空)
    NET_IFACE=""                 # 物理网卡
    EXCLUDE_IPS="127.0.0.1,::1"  # 白名单 IP，用逗号隔开

    [[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"
    [[ -z "${NET_IFACE}" ]] && NET_IFACE="$(get_default_iface)"
}

save_config() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${CONFIG_FILE}" <<EOF
# ip-limiter 流量滥用动态限速配置文件
LIMIT_ENABLE="${LIMIT_ENABLE:-true}"
DYN_WINDOW_MIN="${DYN_WINDOW_MIN:-20}"
DYN_THRESHOLD_GB="${DYN_THRESHOLD_GB:-1.0}"
DYN_LIMIT_MBPS="${DYN_LIMIT_MBPS:-10}"
DYN_PUNISH_MIN="${DYN_PUNISH_MIN:-20}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3}"
ACTIVE_WINDOW_SEC="${ACTIVE_WINDOW_SEC:-20}"
CONN_SOURCE="${CONN_SOURCE:-auto}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"
CLASH_API_SECRET="${CLASH_API_SECRET:-}"
NET_IFACE="${NET_IFACE:-$(get_default_iface)}"
EXCLUDE_IPS="${EXCLUDE_IPS:-127.0.0.1,::1}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

write_python_daemon() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${DAEMON_SCRIPT}" <<'__EOF_PY_DAEMON__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ip_limiter_daemon.py - Linux 客户端 IP 流量滥用动态限速守护进程 (v2.0.0)
提取并升级自 sing-box/Clash API 限速核心引擎
"""

import os
import re
import sys
import json
import time
import socket
import ipaddress
import subprocess
import urllib.request
import urllib.error
import urllib.parse
import threading

DAEMON_VERSION = "2.0.0"
INSTALL_DIR = os.environ.get("INSTALL_DIR", "/etc/ip-limiter")
CONFIG_FILE = os.environ.get("CONFIG_FILE", os.path.join(INSTALL_DIR, "config.env"))
RUNTIME_STATUS_FILE = os.path.join(INSTALL_DIR, "runtime_status.json")
TRAFFIC_STATE_FILE = os.path.join(INSTALL_DIR, "traffic_window.json")
LOG_FILE = "/var/log/ip-limiter.log"

LIMIT_LOCK = threading.Lock()
TC_OVERHEAD_FACTOR = 1.15  # 补偿 15% 协议头与 ACK 开销，确保实测精准对齐设置的 Mbps

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
NC = "\033[0m"


def now_cst_str(ts=None):
    t = ts if ts is not None else time.time()
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


def log(level, msg):
    line = f"[{now_cst_str()}] [{level}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_env_config():
    cfg = {
        "LIMIT_ENABLE": "true",
        "DYN_WINDOW_MIN": "20",       # 滑动统计窗口 (分钟)
        "DYN_THRESHOLD_GB": "1.0",    # 阈值流量 (GB)
        "DYN_LIMIT_MBPS": "10",       # 限速带宽 (Mbps)
        "DYN_PUNISH_MIN": "20",       # 限速惩罚时长 (分钟)
        "CHECK_INTERVAL": "3",        # 采样检测周期 (秒)
        "ACTIVE_WINDOW_SEC": "20",
        "CONN_SOURCE": "auto",
        "CLASH_API_PORT": "9090",
        "CLASH_API_SECRET": "",
        "NET_IFACE": "",
        "EXCLUDE_IPS": "127.0.0.1,::1",
    }
    if os.path.isfile(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
        except Exception as e:
            log("WARN", f"读取配置文件失败: {e}")
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


def detect_default_iface():
    try:
        out = subprocess.check_output(["ip", "-o", "-4", "route", "show", "to", "default"], text=True, timeout=3)
        parts = out.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    except Exception:
        pass
    return "eth0"


def is_valid_public_ip(ip_str):
    if not ip_str:
        return False
    ip_str = ip_str.strip().strip("[]").split("%")[0]
    if ip_str.startswith("::ffff:"):
        ip_str = ip_str[7:]
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        if ip_obj.is_loopback or ip_obj.is_unspecified or ip_obj.is_multicast or ip_obj.is_reserved:
            return False
        if ip_obj.is_private:
            return False
        return True
    except Exception:
        return False


def inspect_kernel_tc(iface):
    res = {
        "iface": iface,
        "iface_exists": os.path.exists(f"/sys/class/net/{iface}"),
        "has_htb_root": False,
        "classes": {},   # cid: {rate, ceil, sent_bytes, sent_pkts, dropped, overlimits}
        "filters": {},   # cid: [ips]
    }
    if not res["iface_exists"]:
        return res
    try:
        p = subprocess.run(["tc", "qdisc", "show", "dev", iface], capture_output=True, text=True, timeout=2)
        if re.search(r"qdisc\s+htb\s+1:\s+root", p.stdout or ""):
            res["has_htb_root"] = True
    except Exception:
        pass

    if not res["has_htb_root"]:
        return res

    try:
        p_cls = subprocess.run(["tc", "-s", "class", "show", "dev", iface], capture_output=True, text=True, timeout=2)
        blocks = re.split(r"(?=^class\s+htb\s+1:\d+)", p_cls.stdout or "", flags=re.M)
        for blk in blocks:
            m = re.search(r"^class\s+htb\s+1:(\d+)\s+.*?rate\s+([^\s]+)\s+ceil\s+([^\s]+)", blk, re.M)
            if not m:
                continue
            cid = int(m.group(1))
            if cid in (1, 999):
                continue
            m_sent = re.search(r"Sent\s+(\d+)\s+bytes\s+(\d+)\s+pkt", blk)
            m_drop = re.search(r"\(dropped\s+(\d+),\s*overlimits\s+(\d+)", blk)
            res["classes"][cid] = {
                "rate": m.group(2),
                "ceil": m.group(3),
                "sent_bytes": int(m_sent.group(1)) if m_sent else 0,
                "sent_pkts": int(m_sent.group(2)) if m_sent else 0,
                "dropped": int(m_drop.group(1)) if m_drop else 0,
                "overlimits": int(m_drop.group(2)) if m_drop else 0,
            }
    except Exception:
        pass

    try:
        for proto in ("ip", "ipv6"):
            p_flt = subprocess.run(["tc", "filter", "show", "dev", iface, "parent", "1:0", "protocol", proto], capture_output=True, text=True, timeout=2)
            current_cid = None
            for line in (p_flt.stdout or "").splitlines():
                m_flow = re.search(r"flowid\s+1:(\d+)", line)
                if m_flow:
                    current_cid = int(m_flow.group(1))
                    res["filters"].setdefault(current_cid, [])
                m_match = re.search(r"match\s+([0-9a-fA-F]{8})/ffffffff\s+at\s+16", line)
                if m_match and current_cid is not None:
                    hex_ip = m_match.group(1)
                    try:
                        ip_str = ".".join(str(int(hex_ip[i:i+2], 16)) for i in range(0, 8, 2))
                        if ip_str not in res["filters"][current_cid]:
                            res["filters"][current_cid].append(ip_str)
                    except Exception:
                        pass
    except Exception:
        pass

    return res


class DynamicIpRateLimiter:
    def __init__(self):
        self.conn_last = {}            # {conn_id: 上次累计总字节数}
        self.conn_baselined = False
        self.traffic_window = {}       # {ip: [[ts, bytes_delta], ...]}
        self.punish_until = {}         # {ip: 惩罚限速到期时间戳}
        self.punish_trigger_bytes = {} # {ip: 触发限速时的窗口累计字节数}
        self.ip_cid_map = {}          # {ip: cid} (10..890)
        self.next_cid = 10
        self.tc_initialized_iface = None
        self.throttled_ips = {}        # {ip: {...}} 当前正处于限速中的 IP
        self._restore_from_disk()

    def _restore_from_disk(self):
        now = time.time()
        tstate = load_json_file(TRAFFIC_STATE_FILE, {})
        if isinstance(tstate, dict):
            tw = tstate.get("traffic_window") or {}
            if isinstance(tw, dict):
                for ip, samples in tw.items():
                    if isinstance(samples, list):
                        valid = [
                            [float(item[0]), int(item[1])]
                            for item in samples
                            if isinstance(item, (list, tuple)) and len(item) == 2 and now - float(item[0]) <= 86400
                        ]
                        if valid:
                            self.traffic_window[ip] = valid
            pu = tstate.get("punish_until") or {}
            if isinstance(pu, dict):
                for ip, du in pu.items():
                    if float(du or 0) > now:
                        self.punish_until[ip] = float(du)
            tb = tstate.get("punish_trigger_bytes") or {}
            if isinstance(tb, dict):
                for ip, b in tb.items():
                    self.punish_trigger_bytes[ip] = int(b)

    def _persist_to_disk(self):
        try:
            save_json_file(TRAFFIC_STATE_FILE, {
                "updated_at": int(time.time()),
                "traffic_window": self.traffic_window,
                "punish_until": self.punish_until,
                "punish_trigger_bytes": self.punish_trigger_bytes,
            })
        except Exception:
            pass

    def _get_cid_for_ip(self, ip):
        if ip not in self.ip_cid_map:
            cid = self.next_cid
            self.next_cid = 10 if self.next_cid >= 890 else (self.next_cid + 1)
            self.ip_cid_map[ip] = cid
        return self.ip_cid_map[ip]

    def ensure_tc_root(self, iface):
        try:
            chk = subprocess.run(["tc", "qdisc", "show", "dev", iface], capture_output=True, text=True, timeout=2)
            if self.tc_initialized_iface == iface and re.search(r"qdisc\s+htb\s+1:\s+root", chk.stdout or ""):
                return True, ""
        except Exception:
            pass

        try:
            for mod in ("sch_htb", "sch_fq_codel", "sch_sfq", "cls_u32"):
                try:
                    subprocess.run(["modprobe", mod], stderr=subprocess.DEVNULL, check=False, timeout=2)
                except Exception:
                    pass
            p1 = subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "root", "handle", "1:", "htb", "default", "999", "r2q", "10"],
                capture_output=True, text=True, check=False, timeout=3
            )
            if p1.returncode != 0:
                return False, (p1.stderr or "tc qdisc replace 失败").strip()
            # 默认直连未限速类 1:999 (10000mbit) - 正常 IP 走此直连极速通道，完全不限速！
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
            return False, str(e)

    def apply_ip_limit(self, iface, ip, limit_mbps):
        ok, err = self.ensure_tc_root(iface)
        if not ok:
            return False, err
        cid = self._get_cid_for_ip(ip)
        target_mbps = max(1, int(limit_mbps))
        wire_kbit = int(round(target_mbps * 1000 * TC_OVERHEAD_FACTOR))
        rate_str = f"{wire_kbit}kbit"
        burst_kb = max(512, target_mbps * 64)
        burst_str = f"{burst_kb}kb"

        try:
            # 1. 创建或更新针对该受限 IP 的 HTB 类
            subprocess.run(
                [
                    "tc", "class", "replace", "dev", iface, "parent", "1:1", "classid", f"1:{cid}",
                    "htb", "rate", rate_str, "ceil", rate_str,
                    "burst", burst_str, "cburst", burst_str, "quantum", "15140",
                ],
                capture_output=True, text=True, check=False, timeout=3
            )
            # 2. 挂载 fq_codel 防重传乱序队列
            p_qd = subprocess.run(
                ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{cid}", "handle", f"{cid}:", "fq_codel", "limit", "4096", "quantum", "1514"],
                capture_output=True, text=True, check=False, timeout=3
            )
            if p_qd.returncode != 0:
                subprocess.run(
                    ["tc", "qdisc", "replace", "dev", iface, "parent", f"1:{cid}", "handle", f"{cid}:", "pfifo", "limit", "2000"],
                    stderr=subprocess.DEVNULL, check=False, timeout=3
                )
            # 3. 关联 u32 过滤器 match 该目标 IP
            subprocess.run(["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)], stderr=subprocess.DEVNULL, check=False, timeout=2)
            if ":" in ip:
                subprocess.run(
                    ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ipv6", "prio", str(cid), "u32", "match", "ip6", "dst", f"{ip}/128", "flowid", f"1:{cid}"],
                    stderr=subprocess.DEVNULL, check=False, timeout=2
                )
            else:
                subprocess.run(
                    ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip", "prio", str(cid), "u32", "match", "ip", "dst", f"{ip}/32", "flowid", f"1:{cid}"],
                    stderr=subprocess.DEVNULL, check=False, timeout=2
                )
            return True, ""
        except Exception as e:
            return False, str(e)

    def remove_ip_limit(self, iface, ip):
        cid = self.ip_cid_map.get(ip)
        if not cid:
            return
        try:
            subprocess.run(["tc", "filter", "del", "dev", iface, "parent", "1:0", "prio", str(cid)], stderr=subprocess.DEVNULL, check=False, timeout=2)
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "parent", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False, timeout=2)
            subprocess.run(["tc", "class", "del", "dev", iface, "parent", "1:1", "classid", f"1:{cid}"], stderr=subprocess.DEVNULL, check=False, timeout=2)
        except Exception:
            pass

    def clear_all(self, iface):
        try:
            subprocess.run(["tc", "qdisc", "del", "dev", iface, "root"], stderr=subprocess.DEVNULL, check=False, timeout=2)
        except Exception:
            pass
        self.tc_initialized_iface = None
        self.throttled_ips.clear()
        self.punish_until.clear()
        self.punish_trigger_bytes.clear()
        self.traffic_window.clear()
        self._persist_to_disk()

    def poll_once(self):
        with LIMIT_LOCK:
            cfg = load_env_config()
            enabled = cfg.get("LIMIT_ENABLE", "true").lower() == "true"
            iface = cfg.get("NET_IFACE") or detect_default_iface()

            try:
                dyn_win_min = max(1.0, float(cfg.get("DYN_WINDOW_MIN", "20")))
                dyn_win_sec = dyn_win_min * 60.0
                dyn_thresh_gb = max(0.01, float(cfg.get("DYN_THRESHOLD_GB", "1.0")))
                dyn_thresh_bytes = dyn_thresh_gb * (1024 ** 3)
                dyn_mbps = max(1, int(float(cfg.get("DYN_LIMIT_MBPS", "10"))))
                dyn_punish_min = max(1.0, float(cfg.get("DYN_PUNISH_MIN", "20")))
                dyn_punish_sec = dyn_punish_min * 60.0
            except ValueError:
                dyn_win_min, dyn_win_sec = 20.0, 1200.0
                dyn_thresh_gb, dyn_thresh_bytes = 1.0, 1.0 * (1024 ** 3)
                dyn_mbps = 10
                dyn_punish_min, dyn_punish_sec = 20.0, 1200.0

            conn_source = cfg.get("CONN_SOURCE", "auto").lower()
            clash_port = cfg.get("CLASH_API_PORT", "9090")
            clash_secret = cfg.get("CLASH_API_SECRET", "")
            exclude_set = set(re.split(r"[,\s]+", cfg.get("EXCLUDE_IPS", "")))

            now = time.time()

            if not enabled:
                if self.tc_initialized_iface:
                    self.clear_all(iface)
                status_snapshot = {
                    "updated_at": int(now),
                    "updated_at_str": now_cst_str(now),
                    "enabled": False,
                    "active_ips": {},
                    "throttled_ips": {},
                }
                save_json_file(RUNTIME_STATUS_FILE, status_snapshot)
                return

            # 1. 采集当前连接与流量字节增量 delta
            cycle_ip_deltas = {}
            active_connected_ips = set()
            src_used = ""

            # 优先从 Clash API connections 获取
            clash_url = f"http://127.0.0.1:{clash_port}/connections"
            headers = {"Authorization": f"Bearer {clash_secret}"} if clash_secret else {}
            clash_ok = False
            try:
                req = urllib.request.Request(clash_url, headers=headers, method="GET")
                with urllib.request.urlopen(req, timeout=2) as resp:
                    data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                    conns = data.get("connections") or []
                    clash_ok = True
                    src_used = "Clash API (sing-box/clash)"
                    seen_conn_ids = set()
                    for c in conns:
                        if not isinstance(c, dict):
                            continue
                        meta = c.get("metadata") or {}
                        src_ip = str(meta.get("sourceIP") or "").strip()
                        if src_ip.startswith("[") and src_ip.endswith("]"):
                            src_ip = src_ip[1:-1]
                        if src_ip.startswith("::ffff:"):
                            src_ip = src_ip[7:]
                        if not is_valid_public_ip(src_ip) or src_ip in exclude_set:
                            continue
                        active_connected_ips.add(src_ip)

                        cid_key = str(c.get("id") or "")
                        if cid_key:
                            total = int(c.get("upload") or 0) + int(c.get("download") or 0)
                            seen_conn_ids.add(cid_key)
                            last = self.conn_last.get(cid_key)
                            self.conn_last[cid_key] = total
                            delta = (total - last) if last is not None else (total if self.conn_baselined else 0)
                            if delta > 0:
                                cycle_ip_deltas[src_ip] = cycle_ip_deltas.get(src_ip, 0) + delta

                    # 清理已关闭连接的基线记录
                    for k in list(self.conn_last.keys()):
                        if k not in seen_conn_ids:
                            del self.conn_last[k]
                    self.conn_baselined = True
            except Exception as e:
                clash_ok = False
                src_used = f"Clash API 无法连接 ({e}) -> 自动使用系统原生连接监控"

            # 若 Clash API 未开启，降级从系统连接获取活跃 IP
            if not clash_ok:
                try:
                    p = subprocess.run(["ss", "-ntH", "state", "established"], capture_output=True, text=True, timeout=2)
                    for line in (p.stdout or "").splitlines():
                        parts = line.split()
                        if len(parts) >= 4:
                            peer = parts[3]
                            cand = peer.strip("[]").rsplit(":", 1)[0]
                            if is_valid_public_ip(cand) and cand not in exclude_set:
                                active_connected_ips.add(cand)
                except Exception:
                    pass

            # 2. 将本轮新增 delta 写入每个 IP 的滑动窗口记录
            for ip, d_bytes in cycle_ip_deltas.items():
                if d_bytes > 0:
                    self.traffic_window.setdefault(ip, []).append([round(now, 1), int(d_bytes)])

            # 3. 滑动窗口清洗与累加流量计算
            ip_window_bytes = {}
            for ip in list(self.traffic_window.keys()):
                samples = [[t, b] for t, b in self.traffic_window[ip] if now - t <= dyn_win_sec]
                if not samples:
                    del self.traffic_window[ip]
                    continue
                self.traffic_window[ip] = samples
                used_bytes = int(sum(b for _, b in samples))
                ip_window_bytes[ip] = used_bytes

                # 4. 判定是否达到滥用限速阈值！
                if used_bytes >= dyn_thresh_bytes:
                    self.punish_trigger_bytes[ip] = max(used_bytes, self.punish_trigger_bytes.get(ip, 0))
                    if ip not in self.punish_until:
                        # 首次触发滥用惩罚：关进小黑屋！限速 20 分钟！
                        self.punish_until[ip] = now + dyn_punish_sec
                        log(
                            "WARN",
                            f"[触发滥用限速] IP [{ip}] 最近 {dyn_win_min:g} 分钟内使用流量 {used_bytes / (1024**3):.3f}GB >= 阈值 {dyn_thresh_gb:g}GB "
                            f"-> 自动执行限速 {dyn_mbps}Mbps，惩罚时长 {dyn_punish_min:g} 分钟！"
                        )

            # 5. 检查惩罚到期的 IP，予以解封！
            for ip in list(self.punish_until.keys()):
                if now >= self.punish_until[ip]:
                    del self.punish_until[ip]
                    self.punish_trigger_bytes.pop(ip, None)
                    # 清洗到期 IP 的旧历史记录，避免刚解封又立即重复触发
                    self.traffic_window.pop(ip, None)
                    self.remove_ip_limit(iface, ip)
                    log("INFO", f"[解除限速] IP [{ip}] 惩罚限速到期已解封！恢复极速直连通道 (重新开始窗口评估)")

            self._persist_to_disk()

            # 6. 对所有当前在惩罚期内的 IP 应用 TC HTB 限速规则
            kernel_tc = inspect_kernel_tc(iface)
            existing_cids = set(kernel_tc["classes"].keys())

            currently_punished = set(self.punish_until.keys())
            for ip in currently_punished:
                rem_sec = max(1, int(self.punish_until[ip] - now))
                cid = self._get_cid_for_ip(ip)
                prev = self.throttled_ips.get(ip)
                need_reapply = (not prev) or (cid not in existing_cids)
                if need_reapply:
                    ok, err = self.apply_ip_limit(iface, ip, dyn_mbps)
                    self.throttled_ips[ip] = {
                        "cid": cid,
                        "limit_mbps": dyn_mbps,
                        "punish_until": int(self.punish_until[ip]),
                        "punish_until_str": now_cst_str(self.punish_until[ip]),
                        "window_bytes": ip_window_bytes.get(ip, 0),
                        "trigger_bytes": self.punish_trigger_bytes.get(ip, 0),
                        "applied_ok": ok,
                    }
                    if not prev:
                        log("WARN", f"[生效规则] IP [{ip}] 成功挂载内核 TC 队列 1:{cid} -> 限速 {dyn_mbps}Mbps (剩余 {rem_sec//60}分{rem_sec%60:02d}秒)")
                else:
                    prev["punish_until"] = int(self.punish_until[ip])
                    prev["punish_until_str"] = now_cst_str(self.punish_until[ip])
                    prev["window_bytes"] = ip_window_bytes.get(ip, 0)
                    prev["trigger_bytes"] = max(ip_window_bytes.get(ip, 0), self.punish_trigger_bytes.get(ip, 0))

            # 7. 移除不在惩罚列表中的遗留规则
            for ip in list(self.throttled_ips.keys()):
                if ip not in currently_punished:
                    self.remove_ip_limit(iface, ip)
                    del self.throttled_ips[ip]

            # 8. 汇总当前状态快照
            all_known_ips = sorted(active_connected_ips | set(ip_window_bytes.keys()) | set(self.throttled_ips.keys()))
            active_ips_detail = {}
            for ip in all_known_ips:
                wb = ip_window_bytes.get(ip, 0)
                is_punished = ip in self.throttled_ips
                p_until = int(self.punish_until.get(ip, 0))
                active_ips_detail[ip] = {
                    "is_connected": ip in active_connected_ips,
                    "window_bytes": wb,
                    "window_gb": round(wb / (1024 ** 3), 4),
                    "is_throttled": is_punished,
                    "punish_until": p_until,
                    "punish_until_str": now_cst_str(p_until) if p_until > now else "-",
                    "limit_mbps": dyn_mbps if is_punished else 0,
                }

            status_snapshot = {
                "daemon_version": DAEMON_VERSION,
                "updated_at": int(now),
                "updated_at_str": now_cst_str(now),
                "enabled": enabled,
                "iface": iface,
                "source": src_used,
                "config": {
                    "window_min": dyn_win_min,
                    "threshold_gb": dyn_thresh_gb,
                    "limit_mbps": dyn_mbps,
                    "punish_min": dyn_punish_min,
                },
                "total_connected_ips": len(active_connected_ips),
                "total_throttled_ips": len(self.throttled_ips),
                "active_ips": active_ips_detail,
                "throttled_ips": self.throttled_ips,
            }
            save_json_file(RUNTIME_STATUS_FILE, status_snapshot)


LIMITER = DynamicIpRateLimiter()


def format_bytes(num_bytes):
    num_bytes = int(num_bytes or 0)
    if num_bytes >= 1024 ** 3:
        return f"{num_bytes / (1024 ** 3):.2f} GB"
    elif num_bytes >= 1024 ** 2:
        return f"{num_bytes / (1024 ** 2):.2f} MB"
    elif num_bytes >= 1024:
        return f"{num_bytes / 1024:.1f} KB"
    return f"{num_bytes} B"


def print_status():
    cfg = load_env_config()
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    snap = load_json_file(RUNTIME_STATUS_FILE, {})
    tc_info = inspect_kernel_tc(iface)

    enabled = cfg.get("LIMIT_ENABLE", "true").lower() == "true"
    win_min = float(cfg.get("DYN_WINDOW_MIN", "20"))
    thresh_gb = float(cfg.get("DYN_THRESHOLD_GB", "1.0"))
    thresh_bytes = thresh_gb * (1024 ** 3)
    mbps = int(cfg.get("DYN_LIMIT_MBPS", "10"))
    punish_min = float(cfg.get("DYN_PUNISH_MIN", "20"))

    now = time.time()

    print(f"\n{BOLD}{CYAN}================ [一] 流量滥用动态限速系统状态 ================{NC}")
    status_tag = f"{GREEN}监控中 (滥用自动触发限速){NC}" if enabled else f"{RED}已暂停{NC}"
    print(f"  • 限速功能状态 : {status_tag}")
    print(f"  • 滥用规则定义 : 单 IP 在 {BOLD}{YELLOW}{win_min:g}{NC} 分钟内累计流量 >= {BOLD}{YELLOW}{thresh_gb:g} GB{NC}")
    print(f"  • 触发惩罚动作 : 自动限制该 IP 速率为 {BOLD}{RED}{mbps} Mbps{NC}，限速惩罚持续 {BOLD}{YELLOW}{punish_min:g}{NC} 分钟")
    print(f"  • 正常连接状态 : {GREEN}完全不限速{NC} (未超额 IP 直连 10000Mbps 极速通道)")
    print(f"  • 数据采集引擎 : {snap.get('source', '自动检测')}")
    print(f"  • 绑定网卡     : {BOLD}{CYAN}{iface}{NC} (内核 HTB 根队列: {'已激活' if tc_info['has_htb_root'] else '就绪待命'})")

    print(f"\n{BOLD}{CYAN}================ [二] 当前触发滥用限速的 IP (小黑屋列表) ================{NC}")
    throttled = snap.get("throttled_ips") or {}
    if not throttled:
        print(f"  {GREEN}🟢 当前没有任何 IP 触发滥用限速 (所有客户端流量均在 {thresh_gb:g}GB 阈值内，全速运行中){NC}")
    else:
        print(f"  {RED}🔴 当前共有 {len(throttled)} 个 IP 超标限速中 (限速带宽: {mbps} Mbps):{NC}\n")
        print(f"  {'受限客户端 IP':<22} {'TC队列':<8} {'触发峰值流量':<14} {'剩余限速惩罚时间':<18} {'内核已整形流量'}")
        print("  " + "-" * 85)
        for ip, item in throttled.items():
            cid = int(item.get("cid") or 0)
            pu_ts = int(item.get("punish_until") or 0)
            rem_sec = max(0, int(pu_ts - now))
            rem_str = f"{rem_sec // 60} 分 {rem_sec % 60:02d} 秒" if rem_sec > 0 else "即将解封"
            trig_b = item.get("trigger_bytes") or item.get("window_bytes") or 0
            cls_stat = (tc_info.get("classes") or {}).get(cid) or {}
            sent_str = format_bytes(cls_stat.get("sent_bytes", 0))

            print(f"  {ip:<22} 1:{cid:<6} {format_bytes(trig_b):<14} {rem_str:<18} {sent_str}")

    print(f"\n{BOLD}{CYAN}================ [三] 所有连接 IP 最近 {win_min:g} 分钟流量监控 ================{NC}")
    active_ips = snap.get("active_ips") or {}
    if not active_ips:
        print("  当前无活跃连接或滑动窗口流量记录")
    else:
        print(f"  {'客户端 IP':<22} {'连接状态':<10} {'窗口已用流量':<16} {'使用率进度':<18} {'当前状态'}")
        print("  " + "-" * 85)
        for ip, info in active_ips.items():
            conn_str = f"{GREEN}在线{NC}" if info.get("is_connected") else f"{YELLOW}离线{NC}"
            wb = int(info.get("window_bytes") or 0)
            pct = (wb / thresh_bytes * 100.0) if thresh_bytes > 0 else 0.0
            pct_bar = f"{pct:.1f}%"
            if info.get("is_throttled"):
                state_str = f"{RED}🔴 惩罚限速中 ({mbps}Mbps){NC}"
            elif pct >= 80.0:
                state_str = f"{YELLOW}⚠️ 接近超标{NC}"
            else:
                state_str = f"{GREEN}🟢 正常{NC}"
            print(f"  {ip:<22} {conn_str:<19} {format_bytes(wb):<16} {pct_bar:<18} {state_str}")

    print(f"\n{BOLD}{CYAN}==================================================================={NC}")


def run_daemon():
    cfg = load_env_config()
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    log("INFO", f"启动流量滥用动态限速守护进程 (网卡: {iface}, 窗口: {cfg.get('DYN_WINDOW_MIN')}m, 阈值: {cfg.get('DYN_THRESHOLD_GB')}GB, 限速: {cfg.get('DYN_LIMIT_MBPS')}Mbps x {cfg.get('DYN_PUNISH_MIN')}m)")

    # 启动时重置 TC 根队列，保留 traffic_window 持久化数据
    LIMITER.ensure_tc_root(iface)

    while True:
        try:
            LIMITER.poll_once()
        except Exception as e:
            log("ERROR", f"巡检异常: {e}")
        try:
            cfg = load_env_config()
            interval = max(1, int(cfg.get("CHECK_INTERVAL", "3")))
        except Exception:
            interval = 3
        time.sleep(interval)


def test_tc_kernel():
    cfg = load_env_config()
    iface = cfg.get("NET_IFACE") or detect_default_iface()
    print(f"\n{BOLD}{CYAN}================ 内核 TC 动态限速挂载实测 ================{NC}")
    if not os.path.exists(f"/sys/class/net/{iface}"):
        print(f"  {RED}❌ 物理网卡 {iface} 不存在！{NC}")
        return False
    print(f"  [1/3] 物理网卡 {iface} 存在性测试  : {GREEN}✅ 正常{NC}")

    ok, err = LIMITER.ensure_tc_root(iface)
    if not ok:
        print(f"  [2/3] 挂载 HTB 根队列 1:0 测试   : {RED}❌ 失败 ({err}){NC}")
        return False
    print(f"  [2/3] 挂载 HTB 根队列 1:0 测试   : {GREEN}✅ 正常 (HTB default 999 极速通道已建立){NC}")

    test_cid = 888
    test_ip = "198.51.100.222"
    try:
        LIMITER.apply_ip_limit(iface, test_ip, 10)
        chk = inspect_kernel_tc(iface)
        has_cls = test_cid in chk["classes"]
        LIMITER.remove_ip_limit(iface, test_ip)
        if has_cls:
            print(f"  [3/3] 滥用触发类 1:{test_cid} & u32 规则: {GREEN}✅ 测试通过 (动态限速与解封完全正常){NC}")
            print(f"\n  🎉 {BOLD}{GREEN}恭喜！本机 Linux 内核完全支持流量超标自动限速与平滑解封机制！{NC}")
            return True
        else:
            print(f"  [3/3] 滥用触发类 1:{test_cid} & u32 规则: {RED}❌ 未检测到创建的类{NC}")
            return False
    except Exception as e:
        print(f"  [3/3] 异常 : {RED}❌ 失败 ({e}){NC}")
        return False


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "daemon"
    if cmd == "daemon":
        run_daemon()
    elif cmd == "poll-once":
        LIMITER.poll_once()
    elif cmd == "status":
        print_status()
    elif cmd == "clear":
        cfg = load_env_config()
        iface = cfg.get("NET_IFACE") or detect_default_iface()
        LIMITER.clear_all(iface)
        save_json_file(RUNTIME_STATUS_FILE, {"updated_at": int(time.time()), "enabled": False, "throttled_ips": {}, "active_ips": {}})
        print(f"{GREEN}已清空网卡 {iface} 上的所有 TC 限速队列并清空小黑屋封禁记录{NC}")
    elif cmd == "unban" and len(sys.argv) > 2:
        ip_target = sys.argv[2]
        cfg = load_env_config()
        iface = cfg.get("NET_IFACE") or detect_default_iface()
        with LIMIT_LOCK:
            LIMITER.punish_until.pop(ip_target, None)
            LIMITER.punish_trigger_bytes.pop(ip_target, None)
            LIMITER.traffic_window.pop(ip_target, None)
            LIMITER.remove_ip_limit(iface, ip_target)
            LIMITER._persist_to_disk()
        print(f"{GREEN}已提前解封 IP: {ip_target}，恢复满速直连通道{NC}")
    elif cmd == "test":
        test_tc_kernel()
    else:
        print(f"未知子命令: {cmd}")
        sys.exit(1)
__EOF_PY_DAEMON__
    chmod +x "${DAEMON_SCRIPT}"
}

setup_systemd_service() {
    load_config
    write_python_daemon

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Universal IP Dynamic Abuse Rate Limiter Service (Linux TC HTB)
After=network.target

[Service]
Type=simple
User=root
Environment="INSTALL_DIR=${INSTALL_DIR}"
Environment="CONFIG_FILE=${CONFIG_FILE}"
ExecStart=/usr/bin/env python3 ${DAEMON_SCRIPT} daemon
ExecStopPost=/usr/bin/env python3 ${DAEMON_SCRIPT} clear
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl stop ip-limiter.service >/dev/null 2>&1 || true
    pkill -9 -f "${DAEMON_SCRIPT}" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ip-limiter.service >/dev/null 2>&1 || true
    systemctl start ip-limiter.service >/dev/null 2>&1 || true
    echo -e "${GREEN}[成功] 已启动后台流量滥用限速守护服务 ip-limiter.service${NC}"
}

stop_systemd_service() {
    if [[ -d /run/systemd/system ]] && [[ -f "${SERVICE_FILE}" ]]; then
        systemctl stop ip-limiter.service >/dev/null 2>&1 || true
        systemctl disable ip-limiter.service >/dev/null 2>&1 || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    pkill -f "${DAEMON_SCRIPT}" 2>/dev/null || true
    [[ -f "${DAEMON_SCRIPT}" ]] && python3 "${DAEMON_SCRIPT}" clear >/dev/null 2>&1 || true
    echo -e "${GREEN}已停止守护服务并清空内核限速规则${NC}"
}

is_daemon_running() {
    systemctl is-active --quiet ip-limiter.service 2>/dev/null || pgrep -f "${DAEMON_SCRIPT} daemon" >/dev/null 2>&1
}

deploy_binaries() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${INSTALL_BIN}" <<EOF
#!/usr/bin/env bash
exec bash "$0" "\$@"
EOF
    cp -f "$0" "${INSTALL_BIN}" 2>/dev/null || true
    chmod +x "${INSTALL_BIN}"
    ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
}

menu_config() {
    while true; do
        load_config
        local en_desc="${GREEN}已开启${NC}"
        [[ "${LIMIT_ENABLE}" != "true" ]] && en_desc="${RED}已关闭${NC}"

        echo -e "\n${BOLD}${CYAN}================ 流量滥用动态限速参数配置 ================${NC}"
        echo -e "  1. 滥用限速总开关   : ${en_desc}"
        echo -e "  2. 流量统计时间窗口 : ${BOLD}${YELLOW}${DYN_WINDOW_MIN} 分钟${NC} (统计最近 ${DYN_WINDOW_MIN} 分钟累计流量)"
        echo -e "  3. 滥用触发流量阈值 : ${BOLD}${YELLOW}${DYN_THRESHOLD_GB} GB${NC} (超标即触发限速)"
        echo -e "  4. 触发后限制带宽   : ${BOLD}${RED}${DYN_LIMIT_MBPS} Mbps${NC} (超标后压制速率)"
        echo -e "  5. 限速惩罚持续时间 : ${BOLD}${YELLOW}${DYN_PUNISH_MIN} 分钟${NC} (到期自动恢复满速)"
        echo -e "  6. 采样巡检检测周期 : 每 ${BOLD}${YELLOW}${CHECK_INTERVAL} 秒${NC}"
        echo -e "  7. 绑定物理网卡     : ${BOLD}${CYAN}${NET_IFACE}${NC}"
        echo -e "  8. Clash API 端口   : ${BOLD}${YELLOW}${CLASH_API_PORT}${NC}"
        echo -e "  9. 白名单 IP 列表   : ${YELLOW}${EXCLUDE_IPS}${NC}"
        echo "----------------------------------------------------------"
        echo -e "  ${GREEN}S.${NC} 保存参数并立即热生效到守护服务"
        echo -e "  ${GREEN}0.${NC} 返回上一层"
        echo "=========================================================="

        local opt=""
        prompt_read "请选择需要修改的项编号 [0-9, S]: " opt || return 0
        case "${opt}" in
            1)
                [[ "${LIMIT_ENABLE}" == "true" ]] && LIMIT_ENABLE="false" || LIMIT_ENABLE="true"
                save_config
                ;;
            2)
                local in_win=""
                prompt_read "请输入流量统计滑动时间窗口 (分钟，如 20) [${DYN_WINDOW_MIN}]: " in_win || continue
                if is_pos_num "${in_win}"; then
                    DYN_WINDOW_MIN="${in_win}"
                    save_config
                fi
                ;;
            3)
                local in_gb=""
                prompt_read "请输入窗口内触发限速的累计流量阈值 (GB，如 1.0 或 2.5) [${DYN_THRESHOLD_GB}]: " in_gb || continue
                if is_pos_num "${in_gb}"; then
                    DYN_THRESHOLD_GB="${in_gb}"
                    save_config
                fi
                ;;
            4)
                local in_mbps=""
                prompt_read "请输入触发滥用后的限制带宽 (Mbps，如 10) [${DYN_LIMIT_MBPS}]: " in_mbps || continue
                if is_pos_int "${in_mbps}"; then
                    DYN_LIMIT_MBPS="${in_mbps}"
                    save_config
                fi
                ;;
            5)
                local in_pmin=""
                prompt_read "请输入触发限速后的持续时间 (分钟，如 20) [${DYN_PUNISH_MIN}]: " in_pmin || continue
                if is_pos_num "${in_pmin}"; then
                    DYN_PUNISH_MIN="${in_pmin}"
                    save_config
                fi
                ;;
            6)
                local in_int=""
                prompt_read "请输入巡检采样周期 (秒，默认 3) [${CHECK_INTERVAL}]: " in_int || continue
                if is_pos_int "${in_int}"; then
                    CHECK_INTERVAL="${in_int}"
                    save_config
                fi
                ;;
            7)
                local avail_ifaces
                avail_ifaces="$(list_available_ifaces)"
                echo -e "本机检测到可用网卡: ${CYAN}${avail_ifaces}${NC}"
                local in_iface=""
                prompt_read "请输入限速绑定网卡 [${NET_IFACE}]: " in_iface || continue
                if [[ -n "${in_iface}" && -e "/sys/class/net/${in_iface}" ]]; then
                    NET_IFACE="${in_iface}"
                    save_config
                fi
                ;;
            8)
                local in_port=""
                prompt_read "请输入 Clash API 端口 [${CLASH_API_PORT}]: " in_port || continue
                if is_pos_int "${in_port}"; then
                    CLASH_API_PORT="${in_port}"
                    save_config
                fi
                ;;
            9)
                local in_ex=""
                prompt_read "请输入白名单 IP (多个以逗号隔开) [${EXCLUDE_IPS}]: " in_ex || continue
                if [[ -n "${in_ex}" ]]; then
                    EXCLUDE_IPS="${in_ex}"
                    save_config
                fi
                ;;
            s|S)
                save_config
                write_python_daemon
                if is_daemon_running; then
                    systemctl restart ip-limiter.service >/dev/null 2>&1 || true
                    echo -e "${GREEN}[成功] 配置已保存并已平滑重启后台限速服务生效！${NC}"
                else
                    setup_systemd_service
                fi
                sleep 1
                ;;
            0)
                return 0
                ;;
        esac
    done
}

main_menu() {
    load_config
    deploy_binaries
    write_python_daemon

    while true; do
        load_config
        local d_status="${RED}未运行${NC}"
        if is_daemon_running; then
            d_status="${GREEN}运行中 (ip-limiter.service)${NC}"
        fi

        local throttled_cnt=0
        if [[ -f "${RUNTIME_STATUS_FILE}" ]]; then
            throttled_cnt="$(python3 -c "import json; d=json.load(open('${RUNTIME_STATUS_FILE}')); print(len(d.get('throttled_ips', {})))" 2>/dev/null || echo 0)"
        fi

        echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
        echo -e "${BOLD}       Linux IP 流量滥用动态限速系统 (20分钟超标限速20分钟) v${VERSION}${NC}"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        echo -e "  守护服务状态 : ${d_status}"
        echo -e "  滥用规则     : ${BOLD}${YELLOW}${DYN_WINDOW_MIN} 分钟${NC} 内累计 >= ${BOLD}${YELLOW}${DYN_THRESHOLD_GB} GB${NC} -> 限速 ${BOLD}${RED}${DYN_LIMIT_MBPS} Mbps${NC} (持续 ${BOLD}${YELLOW}${DYN_PUNISH_MIN} 分钟${NC})"
        echo -e "  正常 IP 状态 : ${GREEN}完全不限速 (满速直连 10000Mbps)${NC}"
        echo -e "  当前受限 IP  : ${BOLD}${RED}${throttled_cnt}${NC} 个 (小黑屋受限中)"
        echo -e "  绑定物理网卡 : ${CYAN}${NET_IFACE}${NC}"
        echo -e "-----------------------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 查看实时所有 IP 流量监控与超限封禁状态 (status)"
        echo -e "  ${GREEN}2.${NC} 修改限速参数 (修改统计窗口 / 流量阈值 / 惩罚时长 / 带宽)"
        echo -e "  ${GREEN}3.${NC} 启动 / 重启后台限速守护服务 (start/restart)"
        echo -e "  ${YELLOW}4.${NC} 停止后台限速守护服务 (stop)"
        echo -e "  ${GREEN}5.${NC} 手动解封某个 IP (提前从小黑屋释放)"
        echo -e "  ${YELLOW}6.${NC} 立即清空所有 TC 限速队列与封禁记录 (clear)"
        echo -e "  ${CYAN}7.${NC} 运行内核 TC 限速环境自检实测 (test)"
        echo -e "  ${CYAN}8.${NC} 查看最近 50 行运行日志 (logs)"
        echo -e "  ${RED}9.${NC} 卸载本程序与守护服务 (uninstall)"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"

        local choice=""
        prompt_read "请输入选项编号 [0-9]: " choice || exit 0
        case "${choice}" in
            1)
                python3 "${DAEMON_SCRIPT}" status
                ;;
            2)
                menu_config
                ;;
            3)
                setup_systemd_service
                ;;
            4)
                stop_systemd_service
                ;;
            5)
                local unban_ip=""
                prompt_read "请输入要提前解封的 IP: " unban_ip || continue
                if [[ -n "${unban_ip}" ]]; then
                    python3 "${DAEMON_SCRIPT}" unban "${unban_ip}"
                fi
                ;;
            6)
                python3 "${DAEMON_SCRIPT}" clear
                ;;
            7)
                python3 "${DAEMON_SCRIPT}" test
                ;;
            8)
                tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志"
                ;;
            9)
                stop_systemd_service
                rm -rf "${INSTALL_DIR}" "${INSTALL_BIN}" "${ALIAS_BIN}"
                echo -e "${GREEN}已成功卸载！${NC}"
                exit 0
                ;;
            0|"")
                exit 0
                ;;
            *)
                echo -e "${YELLOW}无效选项 [${choice}]${NC}"
                ;;
        esac
    done
}

# CLI 命令行快捷调用
check_root
check_dependencies

case "${1:-}" in
    status|--status|-s)
        write_python_daemon
        python3 "${DAEMON_SCRIPT}" status
        ;;
    start|--start)
        setup_systemd_service
        ;;
    stop|--stop)
        stop_systemd_service
        ;;
    restart|--restart)
        setup_systemd_service
        ;;
    clear|--clear)
        write_python_daemon
        python3 "${DAEMON_SCRIPT}" clear
        ;;
    unban|--unban)
        write_python_daemon
        python3 "${DAEMON_SCRIPT}" unban "${2:-}"
        ;;
    test|--test)
        write_python_daemon
        python3 "${DAEMON_SCRIPT}" test
        ;;
    config|--config)
        menu_config
        ;;
    logs|--logs)
        tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志"
        ;;
    "")
        main_menu
        ;;
    *)
        echo "用法: ip-limiter [status|start|stop|restart|unban <ip>|test|clear|config|logs]"
        exit 1
        ;;
esac
