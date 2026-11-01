#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: deploy_nft_block_china.sh
# 适用场景: 境外代理节点 (V2Ray / Xray / Sing-box / Shadowsocks / Clash / WireGuard 等)
# 核心功能:
#   1. 阻止本机主动访问中国大陆目标 IP (Outbound / Forward 阻断)
#   2. 绝对不影响国内客户端连入本机 (Inbound 完全放行，支持中国 IP 连入代理与 SSH)
#   3. 开机自启动热恢复规则 (systemd service)
#   4. 每日定时从境外源自动拉取最新中国 IPv4 / IPv6 地址段并热重载 (systemd timer)
#   5. 交互式操作菜单 (安装/卸载/状态检查/IP测试/白名单管理)
# ==============================================================================

set -euo pipefail

# 终端色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 关键目录与文件配置
INSTALL_DIR="/etc/geo-block"
CONFIG_FILE="${INSTALL_DIR}/config.env"
IPV4_CACHE_FILE="${INSTALL_DIR}/china_ipv4.zone"
IPV6_CACHE_FILE="${INSTALL_DIR}/china_ipv6.zone"
WHITELIST_IPV4_FILE="${INSTALL_DIR}/whitelist_ipv4.txt"
WHITELIST_IPV6_FILE="${INSTALL_DIR}/whitelist_ipv6.txt"

CORE_SCRIPT="/usr/local/bin/geo-block-update.sh"
CLI_LINK="/usr/local/bin/geo-block"

SYSTEMD_RESTORE_SERVICE="/etc/systemd/system/geo-block.service"
SYSTEMD_UPDATE_SERVICE="/etc/systemd/system/geo-block-update.service"
SYSTEMD_UPDATE_TIMER="/etc/systemd/system/geo-block-update.timer"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_title() {
    echo -e "\n${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}\n"
}

# 1. 权限检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 root 权限，请使用 'sudo bash $0' 运行。"
        exit 1
    fi
}

# 2. 检查安装与运行状态辅助函数
is_installed() {
    if [[ -f "${CORE_SCRIPT}" && -f "${SYSTEMD_RESTORE_SERVICE}" ]]; then
        return 0
    else
        return 1
    fi
}

is_running() {
    if command -v nft >/dev/null 2>&1 && nft list table inet geo_block >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 3. 安装依赖包
install_dependencies() {
    log_info "正在检查并安装必要系统依赖 (nftables, curl, systemd, gawk)..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq nftables curl gawk iproute2 || {
            log_error "apt-get 安装依赖失败，请检查网络或软件源。"
            exit 1
        }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q nftables curl gawk iproute || {
            log_error "dnf 安装依赖失败。"
            exit 1
        }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q nftables curl gawk iproute || {
            log_error "yum 安装依赖失败。"
            exit 1
        }
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed nftables curl gawk iproute2 || {
            log_error "pacman 安装依赖失败。"
            exit 1
        }
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nftables curl gawk iproute2 || {
            log_error "apk 安装依赖失败。"
            exit 1
        }
    else
        log_warn "未识别到已知包管理器，直接检查 nftables 与 curl 命令..."
        if ! command -v nft >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
            log_error "系统中未检测到 nftables 或 curl，请先手动安装。"
            exit 1
        fi
    fi

    if systemctl is-enabled nftables >/dev/null 2>&1; then
        log_info "系统原生 nftables 服务已激活。"
    else
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
    log_info "依赖组件检测与安装完成。"
}

# 4. 创建配置与工作目录
setup_directories() {
    log_info "初始化配置目录: ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    chmod 750 "${INSTALL_DIR}"

    cat << 'EOF' > "${CONFIG_FILE}"
# /etc/geo-block/config.env
# 境外代理节点专用配置：阻断出站中国目标 IP

# 阻断动作: reject (推荐，TCP 立即返回 RST，UDP 返回不可达，客户端不卡死等待) 或 drop (静默丢弃)
BLOCK_ACTION="reject"

# IPv4 源 (均位于境外 CDN/服务器，防止节点在阻断大陆后无法更新)
IPV4_URLS=(
    "https://www.ipdeny.com/ipblocks/data/countries/cn.zone"
    "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    "https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
)

# IPv6 源
IPV6_URLS=(
    "https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone"
    "https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt"
)

# 最小有效条目数阈值 (避免拉取异常导致清空规则)
MIN_IPV4_LINES=500
MIN_IPV6_LINES=100

# 下载超时时间 (秒)
CURL_TIMEOUT=25
EOF
    chmod 640 "${CONFIG_FILE}"

    touch "${WHITELIST_IPV4_FILE}"
    touch "${WHITELIST_IPV6_FILE}"
    chmod 640 "${WHITELIST_IPV4_FILE}" "${WHITELIST_IPV6_FILE}"

    # 自动探测并将 /etc/resolv.conf 中的 DNS 写入白名单，防止国内 DNS 导致解析中断
    if [[ -f /etc/resolv.conf ]]; then
        local dns_ips
        dns_ips=$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf | awk '{print $2}' || true)
        for dns in $dns_ips; do
            if [[ "$dns" =~ : ]]; then
                if ! grep -qF "$dns" "${WHITELIST_IPV6_FILE}"; then
                    echo "$dns" >> "${WHITELIST_IPV6_FILE}"
                    log_info "已自动将系统当前 DNS ($dns) 加入 IPv6 白名单，确保域名解析畅通。"
                fi
            elif [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                if ! grep -qF "$dns" "${WHITELIST_IPV4_FILE}"; then
                    echo "$dns" >> "${WHITELIST_IPV4_FILE}"
                    log_info "已自动将系统当前 DNS ($dns) 加入 IPv4 白名单，确保域名解析畅通。"
                fi
            fi
        done
    fi
}

# 5. 生成核心控制脚本 (/usr/local/bin/geo-block-update.sh)
create_core_script() {
    log_info "生成核心控制脚本: ${CORE_SCRIPT}"

    cat << 'EOF' > "${CORE_SCRIPT}"
#!/usr/bin/env bash
# ==============================================================================
# geo-block-update.sh - 代理节点专用: 仅阻止本机/转发流量访问中国目标
# ==============================================================================

set -euo pipefail

INSTALL_DIR="/etc/geo-block"
CONFIG_FILE="${INSTALL_DIR}/config.env"
IPV4_CACHE_FILE="${INSTALL_DIR}/china_ipv4.zone"
IPV6_CACHE_FILE="${INSTALL_DIR}/china_ipv6.zone"
WHITELIST_IPV4_FILE="${INSTALL_DIR}/whitelist_ipv4.txt"
WHITELIST_IPV6_FILE="${INSTALL_DIR}/whitelist_ipv6.txt"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    echo "[ERROR] 配置文件 ${CONFIG_FILE} 不存在！" >&2
    exit 1
fi

BLOCK_ACTION="${BLOCK_ACTION:-reject}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化基础表结构 (table inet geo_block)
init_base_table() {
    # 策略架构:
    # 1. 绝不创建 input 过滤链: 保证国内客户端连接代理端口及 SSH 畅通无阻
    # 2. output 链:
    #    - ct state established,related: 放行发回给客户端的回程数据包
    #    - ip daddr @china_ipv4: 阻止本机主动连接中国境内目标
    # 3. forward 链: 阻止经本机转发往中国目标的流量 (针对 TUN/WireGuard 等模式)
    cat << 'NFT_BASE' | nft -f -
table inet geo_block {
    set whitelist_ipv4 {
        type ipv4_addr
        flags interval
    }

    set whitelist_ipv6 {
        type ipv6_addr
        flags interval
    }

    set china_ipv4 {
        type ipv4_addr
        flags interval
    }

    set china_ipv6 {
        type ipv6_addr
        flags interval
    }

    chain output {
        type filter hook output priority filter; policy accept;

        # 1. 放行本地回环接口流量
        oif "lo" accept

        # 2. 状态放行: 允许已建立和关联连接的回程数据包 (关键！保证国内客户端连接不断流)
        ct state established,related accept

        # 3. 放行用户自定义目标白名单
        ip daddr @whitelist_ipv4 accept
        ip6 daddr @whitelist_ipv6 accept

        # 4. 阻断本机主动发往中国大陆 IP 的新连接
        ip daddr @china_ipv4 counter reject
        ip6 daddr @china_ipv6 counter reject
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        ct state established,related accept

        ip daddr @whitelist_ipv4 accept
        ip6 daddr @whitelist_ipv6 accept

        ip daddr @china_ipv4 counter reject
        ip6 daddr @china_ipv6 counter reject
    }
}
NFT_BASE
}

format_nft_elements() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        return 0
    fi
    awk 'NF {
        sub(/^[ \t\r\n]+/, "", $1);
        sub(/[ \t\r\n]+$/, "", $1);
        if ($1 ~ /^#/) next;
        if (count++) printf ",\n";
        printf "        %s", $1;
    } END {
        if (count) print "";
    }' "$file"
}

apply_whitelist() {
    local tmp_nft
    tmp_nft=$(mktemp)

    {
        echo "table inet geo_block {"
        echo "    set whitelist_ipv4 {"
        echo "        type ipv4_addr"
        echo "        flags interval"
        echo "    }"
        echo "    set whitelist_ipv6 {"
        echo "        type ipv6_addr"
        echo "        flags interval"
        echo "    }"
        echo "}"
        echo "flush set inet geo_block whitelist_ipv4"
        if [[ -s "${WHITELIST_IPV4_FILE}" ]]; then
            echo "add element inet geo_block whitelist_ipv4 {"
            format_nft_elements "${WHITELIST_IPV4_FILE}"
            echo "}"
        fi
        echo "flush set inet geo_block whitelist_ipv6"
        if [[ -s "${WHITELIST_IPV6_FILE}" ]]; then
            echo "add element inet geo_block whitelist_ipv6 {"
            format_nft_elements "${WHITELIST_IPV6_FILE}"
            echo "}"
        fi
    } > "$tmp_nft"

    nft -f "$tmp_nft"
    rm -f "$tmp_nft"
}

download_ip_list() {
    local ip_version="$1"
    local output_file="$2"
    local min_lines="$3"
    shift 3
    local urls=("$@")

    local tmp_dl
    tmp_dl=$(mktemp)
    local success=false

    for url in "${urls[@]}"; do
        echo "[INFO] 正在尝试从源下载 IPv${ip_version} 列表: ${url} ..."
        if curl -sSL -m "${CURL_TIMEOUT}" --retry 2 "$url" -o "$tmp_dl"; then
            local valid_lines=0
            if [[ "$ip_version" == "4" ]]; then
                grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$tmp_dl" > "${tmp_dl}.clean" || true
            else
                grep -E '^[0-9a-fA-F:]+(/[0-9]{1,3})?' "$tmp_dl" > "${tmp_dl}.clean" || true
            fi

            valid_lines=$(wc -l < "${tmp_dl}.clean" | tr -d ' ')

            if [[ $valid_lines -ge $min_lines ]]; then
                mv "${tmp_dl}.clean" "$output_file"
                echo -e "${GREEN}[OK]${NC} IPv${ip_version} 数据校验通过，共获取 ${valid_lines} 条网段。"
                success=true
                break
            else
                echo -e "${YELLOW}[WARN]${NC} 有效行数不足 (${valid_lines} < ${min_lines})，尝试下一个备选源..."
            fi
        else
            echo -e "${YELLOW}[WARN]${NC} 下载超时或连接失败: ${url}，切换备选源..."
        fi
    done

    rm -f "$tmp_dl" "${tmp_dl}.clean" 2>/dev/null || true

    if [[ "$success" != "true" ]]; then
        echo -e "${RED}[ERROR]${NC} 所有 IPv${ip_version} 源均未能获取到有效数据！"
        return 1
    fi
}

apply_cached_rules() {
    init_base_table
    apply_whitelist

    local tmp_batch
    tmp_batch=$(mktemp)

    {
        echo "flush set inet geo_block china_ipv4"
        if [[ -s "${IPV4_CACHE_FILE}" ]]; then
            echo "add element inet geo_block china_ipv4 {"
            format_nft_elements "${IPV4_CACHE_FILE}"
            echo "}"
        fi

        echo "flush set inet geo_block china_ipv6"
        if [[ -s "${IPV6_CACHE_FILE}" ]]; then
            echo "add element inet geo_block china_ipv6 {"
            format_nft_elements "${IPV6_CACHE_FILE}"
            echo "}"
        fi
    } > "$tmp_batch"

    nft -f "$tmp_batch"
    rm -f "$tmp_batch"

    local count_v4=0 count_v6=0
    [[ -f "${IPV4_CACHE_FILE}" ]] && count_v4=$(wc -l < "${IPV4_CACHE_FILE}" | tr -d ' ')
    [[ -f "${IPV6_CACHE_FILE}" ]] && count_v6=$(wc -l < "${IPV6_CACHE_FILE}" | tr -d ' ')

    echo -e "${GREEN}[SUCCESS]${NC} 已成功原子装载规则: 阻断对外访问中国目标 (IPv4: ${count_v4} 网段, IPv6: ${count_v6} 网段)。"
}

action_update() {
    echo -e "${CYAN}>>> 开始从境外镜像源拉取最新中国 IP 列表...${NC}"
    local err=0

    download_ip_list "4" "${IPV4_CACHE_FILE}.new" "${MIN_IPV4_LINES}" "${IPV4_URLS[@]}" || err=$((err + 1))
    download_ip_list "6" "${IPV6_CACHE_FILE}.new" "${MIN_IPV6_LINES}" "${IPV6_URLS[@]}" || err=$((err + 1))

    if [[ -f "${IPV4_CACHE_FILE}.new" ]]; then
        mv "${IPV4_CACHE_FILE}.new" "${IPV4_CACHE_FILE}"
    fi

    if [[ -f "${IPV6_CACHE_FILE}.new" ]]; then
        mv "${IPV6_CACHE_FILE}.new" "${IPV6_CACHE_FILE}"
    fi

    if [[ $err -eq 2 ]]; then
        echo -e "${RED}[FAIL]${NC} 所有 IPv4 与 IPv6 源均拉取失败，保留旧规则继续运行。"
        return 1
    fi

    apply_cached_rules
}

action_restore() {
    echo -e "${CYAN}>>> 正在从本地缓存恢复 geo_block 出站拦截规则...${NC}"
    if [[ ! -s "${IPV4_CACHE_FILE}" ]] && [[ ! -s "${IPV6_CACHE_FILE}" ]]; then
        echo -e "${YELLOW}[WARN]${NC} 未检测到本地 IP 缓存，将触发全量更新..."
        action_update
    else
        apply_cached_rules
    fi
}

action_stop() {
    echo -e "${YELLOW}>>> 正在清除 geo_block 拦截规则表...${NC}"
    nft delete table inet geo_block 2>/dev/null || true
    echo -e "${GREEN}[OK]${NC} geo_block 规则已卸载，本机对外访问限制已解除。"
}

action_status() {
    echo -e "${CYAN}================== nftables 代理节点出站阻断状态 ==================${NC}"
    if ! nft list table inet geo_block >/dev/null 2>&1; then
        echo -e "运行状态: ${RED}未生效 (table inet geo_block 规则表不存在)${NC}"
        return 0
    fi

    echo -e "运行状态: ${GREEN}运行中 (已成功阻断本机/转发访问中国 IP)${NC}\n"

    echo -e "${CYAN}[拦截统计计数 (Reject/Drop Counters)]${NC}"
    echo "--- Output 链 (本机主动发起的出站访问):"
    nft list chain inet geo_block output 2>/dev/null | grep -E "reject|drop|counter" || echo "  无匹配计数"
    echo "--- Forward 链 (路由/转发的流量):"
    nft list chain inet geo_block forward 2>/dev/null | grep -E "reject|drop|counter" || echo "  无匹配计数"

    echo -e "\n${CYAN}[Set 规则库规模]${NC}"
    local v4_lines=0 v6_lines=0 wl4_lines=0 wl6_lines=0
    [[ -f "${IPV4_CACHE_FILE}" ]] && v4_lines=$(wc -l < "${IPV4_CACHE_FILE}" | tr -d ' ')
    [[ -f "${IPV6_CACHE_FILE}" ]] && v6_lines=$(wc -l < "${IPV6_CACHE_FILE}" | tr -d ' ')
    [[ -f "${WHITELIST_IPV4_FILE}" ]] && wl4_lines=$(grep -cvE '^\s*$' "${WHITELIST_IPV4_FILE}" || true)
    [[ -f "${WHITELIST_IPV6_FILE}" ]] && wl6_lines=$(grep -cvE '^\s*$' "${WHITELIST_IPV6_FILE}" || true)

    echo "  - 中国 IPv4 网段数: ${v4_lines}"
    echo "  - 中国 IPv6 网段数: ${v6_lines}"
    echo "  - 目标 IPv4 白名单数: ${wl4_lines}"
    echo "  - 目标 IPv6 白名单数: ${wl6_lines}"

    echo -e "\n${CYAN}[当前允许访问的目标白名单]${NC}"
    if [[ $wl4_lines -gt 0 ]]; then
        echo "IPv4 白名单:"
        sed 's/^/  * /' "${WHITELIST_IPV4_FILE}"
    fi
    if [[ $wl6_lines -gt 0 ]]; then
        echo "IPv6 白名单:"
        sed 's/^/  * /' "${WHITELIST_IPV6_FILE}"
    fi
    if [[ $wl4_lines -eq 0 && $wl4_lines -eq 0 ]]; then
        echo "  (暂无手动添加的白名单 IP)"
    fi

    echo -e "\n${CYAN}[每日定时更新器 (Systemd Timer)]${NC}"
    systemctl status geo-block-update.timer --no-pager 2>/dev/null | grep -E "Loaded|Active|Trigger" || true
    echo -e "${CYAN}===================================================================${NC}"
}

action_test() {
    local target_ip="${1:-}"
    if [[ -z "$target_ip" ]]; then
        read -r -p "请输入要测试的目标 IP 地址: " target_ip
        if [[ -z "$target_ip" ]]; then
            echo "输入为空，取消测试。"
            return 1
        fi
    fi

    echo -e "${CYAN}>>> 正在测试目标 IP: ${target_ip}${NC}"
    if [[ "$target_ip" =~ : ]]; then
        if nft get element inet geo_block china_ipv6 "{ $target_ip }" >/dev/null 2>&1; then
            echo -e "${RED}[阻断]${NC} $target_ip 匹配到中国 IPv6 列表，本机主动访问将被 ${BLOCK_ACTION}！"
        else
            echo -e "${GREEN}[放行]${NC} $target_ip 不在中国 IPv6 列表中，本机可正常访问。"
        fi
    else
        if nft get element inet geo_block china_ipv4 "{ $target_ip }" >/dev/null 2>&1; then
            echo -e "${RED}[阻断]${NC} $target_ip 匹配到中国 IPv4 列表，本机主动访问将被 ${BLOCK_ACTION}！"
        else
            echo -e "${GREEN}[放行]${NC} $target_ip 不在中国 IPv4 列表中，本机可正常访问。"
        fi
    fi
}

action_whitelist() {
    local op="${1:-}"
    local ip="${2:-}"

    if [[ -z "$op" ]]; then
        echo "请选择白名单操作:"
        echo "  1) 添加白名单 IP"
        echo "  2) 删除白名单 IP"
        echo "  3) 查看当前白名单"
        read -r -p "请输入选项 [1-3]: " wl_choice
        case "$wl_choice" in
            1) op="add" ;;
            2) op="del" ;;
            3)
                echo -e "\n${CYAN}当前 IPv4 白名单:${NC}"
                cat "${WHITELIST_IPV4_FILE}" 2>/dev/null || echo "无"
                echo -e "\n${CYAN}当前 IPv6 白名单:${NC}"
                cat "${WHITELIST_IPV6_FILE}" 2>/dev/null || echo "无"
                return 0
                ;;
            *) echo "无效选项"; return 1 ;;
        esac
    fi

    if [[ -z "$ip" ]]; then
        read -r -p "请输入目标 IP 地址: " ip
        if [[ -z "$ip" ]]; then
            echo "IP 不能为空。"
            return 1
        fi
    fi

    local target_file="${WHITELIST_IPV4_FILE}"
    if [[ "$ip" =~ : ]]; then
        target_file="${WHITELIST_IPV6_FILE}"
    fi

    case "$op" in
        add)
            if grep -qF "$ip" "$target_file" 2>/dev/null; then
                echo -e "${YELLOW}[WARN]${NC} 目标 IP $ip 已在白名单中。"
            else
                echo "$ip" >> "$target_file"
                echo -e "${GREEN}[OK]${NC} 已添加 $ip 到目标允许白名单。"
                apply_whitelist
            fi
            ;;
        del)
            if grep -qF "$ip" "$target_file" 2>/dev/null; then
                sed -i "/^${ip//\//\\/}$/d" "$target_file"
                echo -e "${GREEN}[OK]${NC} 已从白名单中删除 $ip。"
                apply_whitelist
            else
                echo -e "${YELLOW}[WARN]${NC} 目标 IP $ip 不在白名单中。"
            fi
            ;;
        *)
            echo "无效操作: $op。仅支持 add 或 del。"
            return 1
            ;;
    esac
}

case "${1:-status}" in
    --update|update)
        action_update
        ;;
    --restore|restore)
        action_restore
        ;;
    --stop|stop)
        action_stop
        ;;
    --status|status)
        action_status
        ;;
    test)
        shift
        action_test "${1:-}"
        ;;
    whitelist)
        shift
        action_whitelist "${1:-}" "${2:-}"
        ;;
    *)
        echo "用法: $0 {status|test <IP>|update|restore|stop|whitelist}"
        exit 1
        ;;
esac
EOF

    chmod 750 "${CORE_SCRIPT}"
    ln -sf "${CORE_SCRIPT}" "${CLI_LINK}"
    log_info "核心脚本配置完成，已创建软链接: ${CLI_LINK}"
}

# 6. 配置 systemd 服务与定时器
setup_systemd() {
    log_info "配置开机自启系统服务与定时更新任务..."

    cat << EOF > "${SYSTEMD_RESTORE_SERVICE}"
[Unit]
Description=Nftables Geo-Block China Outbound Service (Proxy Node Edition)
After=network-pre.target nftables.service
Before=network.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${CORE_SCRIPT} restore
ExecStop=${CORE_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF

    cat << EOF > "${SYSTEMD_UPDATE_SERVICE}"
[Unit]
Description=Daily Update Service for nftables China IP Blocklist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CORE_SCRIPT} update
EOF

    cat << EOF > "${SYSTEMD_UPDATE_TIMER}"
[Unit]
Description=Daily Timer for nftables China IP Blocklist Update

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable geo-block.service
    systemctl enable --now geo-block-update.timer

    log_info "开机自启服务 (geo-block.service) 与定时器 (geo-block-update.timer) 配置成功并已启用！"
}

# 7. 安装流程主函数
do_install() {
    log_title "开始自动化部署 nftables 代理节点出站阻断系统"

    check_root
    install_dependencies
    setup_directories
    create_core_script
    setup_systemd

    log_title "正在从境外镜像源拉取最新中国 IP 列表并装载"
    "${CORE_SCRIPT}" update || {
        log_warn "首次下载 IP 列表波动，尝试从已有缓存或重试加载..."
        "${CORE_SCRIPT}" restore || true
    }

    log_title "部署成功！当前运行状态如下"
    "${CORE_SCRIPT}" status

    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${GREEN} 恭喜！代理节点出站拦截系统已成功激活！${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo -e "架构特点说明:"
    echo -e "  * ${GREEN}完全放行入站连接${NC}: 国内客户端连入代理端口、SSH 完全不受限制。"
    echo -e "  * ${YELLOW}阻断出站中国目标${NC}: 代理节点无法访问中国境内的 Web/API/服务器 (返回 Reject)。"
    echo -e "  * ${CYAN}开机自启动生效${NC}: 系统重启后秒级恢复规则，无需手动干预。"
    echo -e "  * ${CYAN}每日境外源自动更新${NC}: 每天凌晨通过境外源同步最新 CIDR 网段。"
    echo -e "================================================================\n"
}

# 8. 卸载流程函数
do_uninstall() {
    log_title "正在卸载 nftables 代理节点出站阻断系统..."
    check_root

    systemctl stop geo-block-update.timer 2>/dev/null || true
    systemctl disable geo-block-update.timer 2>/dev/null || true
    systemctl stop geo-block.service 2>/dev/null || true
    systemctl disable geo-block.service 2>/dev/null || true

    rm -f "${SYSTEMD_RESTORE_SERVICE}" "${SYSTEMD_UPDATE_SERVICE}" "${SYSTEMD_UPDATE_TIMER}"
    systemctl daemon-reload 2>/dev/null || true

    if [[ -x "${CORE_SCRIPT}" ]]; then
        "${CORE_SCRIPT}" stop 2>/dev/null || true
    else
        nft delete table inet geo_block 2>/dev/null || true
    fi

    rm -f "${CLI_LINK}" "${CORE_SCRIPT}"
    rm -rf "${INSTALL_DIR}"

    log_info "卸载已完成！所有 nftables 规则、定时器、系统服务及配置文件已彻底清除。"
}

# 9. 查看状态流程函数
do_status() {
    log_title "nftables Geo-Block 服务状态检测"

    echo -e "${BOLD}1. 安装状态检测:${NC}"
    if is_installed; then
        echo -e "   安装状态: ${GREEN}已安装${NC} (主控脚本与 Systemd 单元就绪)"
    else
        echo -e "   安装状态: ${RED}未安装${NC} (尚未部署此服务)"
    fi

    echo -e "\n${BOLD}2. 规则运行状态检测:${NC}"
    if is_running; then
        echo -e "   运行状态: ${GREEN}运行中 (Active)${NC} (nftables geo_block 表已加载生效)"
    else
        echo -e "   运行状态: ${RED}未运行 (Inactive)${NC} (未检测到 geo_block 规则表)"
    fi

    echo -e "\n${BOLD}3. 开机自启服务状态:${NC}"
    if systemctl is-enabled geo-block.service >/dev/null 2>&1; then
        echo -e "   开机自启: ${GREEN}已启用 (Enabled)${NC}"
    else
        echo -e "   开机自启: ${YELLOW}未启用或服务不存在${NC}"
    fi

    echo -e "\n${BOLD}4. 每日定时器状态:${NC}"
    if systemctl is-active geo-block-update.timer >/dev/null 2>&1; then
        echo -e "   每日更新定时器: ${GREEN}运行中 (Active)${NC}"
        local next_run
        next_run=$(systemctl list-timers geo-block-update.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}' || true)
        [[ -n "$next_run" ]] && echo -e "   下次触发时间:   ${CYAN}${next_run}${NC}"
    else
        echo -e "   每日更新定时器: ${YELLOW}未激活${NC}"
    fi

    if is_installed && is_running; then
        echo -e "\n${BOLD}5. 规则与拦截详细数据:${NC}"
        "${CORE_SCRIPT}" status
    fi
}

# 10. 交互式菜单展示
show_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}          nftables 代理节点出站中国 IP 拦截自动化系统           ${NC}"
    echo -e "${CYAN}================================================================${NC}"

    # 动态显示状态看板
    local install_status run_status
    if is_installed; then
        install_status="${GREEN}已安装${NC}"
    else
        install_status="${RED}未安装${NC}"
    fi

    if is_running; then
        run_status="${GREEN}运行中${NC}"
    else
        run_status="${RED}未运行${NC}"
    fi

    echo -e "系统状态: 安装状态: [${install_status}] | 拦截状态: [${run_status}]"
    echo -e "节点定位: 境外代理节点 (国内客户端正常连入，仅禁止服务器访问中国目标)"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo -e "  ${BOLD}1.${NC} 安装 / 重新安装拦截服务"
    echo -e "  ${BOLD}2.${NC} 卸载拦截服务"
    echo -e "  ${BOLD}3.${NC} 查看状态 (检查是否安装、是否运行及拦截统计)"
    echo -e "  ${BOLD}4.${NC} 手动立即拉取更新中国 IP 列表"
    echo -e "  ${BOLD}5.${NC} 测试目标 IP 是否会被节点阻断 (诊断工具)"
    echo -e "  ${BOLD}6.${NC} 目标 IP 白名单管理 (添加 / 删除 / 查看)"
    echo -e "  ${BOLD}7.${NC} 暂停 / 恢复拦截规则"
    echo -e "  ${BOLD}0.${NC} 退出菜单"
    echo -e "${CYAN}================================================================${NC}"

    read -r -p "请输入选项数字 [0-7]: " menu_choice
    echo ""

    case "$menu_choice" in
        1)
            do_install
            ;;
        2)
            read -r -p "确定要彻底卸载拦截服务吗？[y/N]: " confirm_un
            if [[ "$confirm_un" =~ ^[yY]$ ]]; then
                do_uninstall
            else
                echo "已取消卸载。"
            fi
            ;;
        3)
            do_status
            ;;
        4)
            if is_installed; then
                "${CORE_SCRIPT}" update
            else
                log_error "服务尚未安装，请先选择 1 进行安装。"
            fi
            ;;
        5)
            if is_installed && is_running; then
                "${CORE_SCRIPT}" test
            else
                log_error "服务尚未运行，请先安装或启动服务。"
            fi
            ;;
        6)
            if is_installed; then
                "${CORE_SCRIPT}" whitelist
            else
                log_error "服务尚未安装，请先选择 1 进行安装。"
            fi
            ;;
        7)
            if ! is_installed; then
                log_error "服务尚未安装，请先选择 1 进行安装。"
            elif is_running; then
                read -r -p "当前正在运行拦截，是否暂停拦截？[y/N]: " confirm_pause
                if [[ "$confirm_pause" =~ ^[yY]$ ]]; then
                    "${CORE_SCRIPT}" stop
                fi
            else
                read -r -p "当前拦截未运行，是否恢复拦截？[y/N]: " confirm_resume
                if [[ "$confirm_resume" =~ ^[yY]$ ]]; then
                    "${CORE_SCRIPT}" restore
                fi
            fi
            ;;
        0)
            echo "感谢使用，再见！"
            exit 0
            ;;
        *)
            echo -e "${RED}输入无效，请输入数字 0 到 7。${NC}"
            ;;
    esac
}

# 主程序入口：支持直接带参数运行，无参数时启动交互式菜单
main() {
    check_root

    local action="${1:-menu}"
    case "$action" in
        1|install|--install)
            do_install
            ;;
        2|uninstall|--uninstall)
            do_uninstall
            ;;
        3|status|--status)
            do_status
            ;;
        4|update|--update)
            if is_installed; then
                "${CORE_SCRIPT}" update
            else
                log_error "服务尚未安装，请先运行 '$0 1' 进行安装。"
            fi
            ;;
        5|test)
            shift
            if is_installed && is_running; then
                "${CORE_SCRIPT}" test "${1:-}"
            else
                log_error "服务未运行。"
            fi
            ;;
        6|whitelist)
            shift
            if is_installed; then
                "${CORE_SCRIPT}" whitelist "$@"
            else
                log_error "服务尚未安装。"
            fi
            ;;
        menu|--menu|"")
            while true; do
                show_menu
                echo ""
                read -r -p "按回车键返回主菜单，或按 Ctrl+C 退出..." _
            done
            ;;
        *)
            echo "用法: $0 [1|install | 2|uninstall | 3|status | 4|update | 5|test <IP> | 6|whitelist]"
            echo "直接运行 '$0' 可进入全功能交互式菜单。"
            exit 1
            ;;
    esac
}

main "$@"
