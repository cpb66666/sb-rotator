#!/usr/bin/env bash
# ==============================================================================
# Sing-box (233boy) 代理协议 (VMess-WS-TLS / VLESS-REALITY) & Caddy 一键伪装优化脚本
# 功能：
#   1. 交互式菜单选择：
#      - [1] 一键优化 VMess-WS-TLS 协议 + Caddy 反代 + 随机行业静态网站
#      - [2] 一键修改 VLESS-REALITY 协议 (偷自己域名 Self-Steal) + Caddy 自动申请证书与静态站
#      - [3] 仅随机更换 / 手动选择 /var/www/html 静态伪装网站模板
#   2. 自动检测并安装缺失的依赖 (jq / Caddy) 及初始化 /etc/caddy/Caddyfile 与 /etc/caddy/233boy 目录
#   3. 内置 5 套不同行业的精美响应式 HTML 静态网站模板
#   4. 自动备份原始配置并校验、重启 sing-box 与 caddy 服务
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. 权限与基础目录检查
if [[ $EUID -ne 0 ]]; then
    log_err "请使用 root 用户运行此脚本 (sudo bash $0)"
    exit 1
fi

SINGBOX_CONF_DIR="/etc/sing-box/conf"
CADDY_MAIN_CONF="/etc/caddy/Caddyfile"
CADDY_CONF_DIR="/etc/caddy/233boy"
WEB_ROOT="/var/www/html"
DEFAULT_WS_PATH="/api/v3/telemetry/stream"
EARLY_DATA_SIZE=2048
DEFAULT_REALITY_CADDY_PORT=8443
BACKUP_DIR="/root/singbox_caddy_backup_$(date +%Y%m%d_%H%M%S)"
SITE_NAME=""
PARSER=""

# ==============================================================================
# 工具检测与自动安装函数
# ==============================================================================
ensure_parser() {
    if command -v jq >/dev/null 2>&1; then
        PARSER="jq"
        return
    elif command -v python3 >/dev/null 2>&1; then
        PARSER="python3"
        return
    fi

    log_info "正在安装 jq 以解析 JSON 配置文件..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq >/dev/null 2>&1
    fi

    if command -v jq >/dev/null 2>&1; then
        PARSER="jq"
    else
        log_err "无法自动安装 jq 且未检测到 python3，请先手动安装 jq (如 apt install -y jq)"
        exit 1
    fi
}

ensure_caddy() {
    local mode="${1:-vmess}"       # vmess 或 reality
    local https_port="${2:-8443}"  # 当 mode=reality 且全新初始化 Caddyfile 时使用的 https_port

    if ! command -v caddy >/dev/null 2>&1; then
        log_warn "未检测到 Caddy，正在为您自动安装 Caddy..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null 2>&1 || true
            if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
                apt-get update -y >/dev/null 2>&1 || true
            fi
            apt-get install -y caddy >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y 'dnf-command(copr)' >/dev/null 2>&1 || true
            dnf copr enable -y @caddy/caddy >/dev/null 2>&1 || true
            dnf install -y caddy >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y yum-plugin-copr >/dev/null 2>&1 || true
            yum copr enable -y @caddy/caddy >/dev/null 2>&1 || true
            yum install -y caddy >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache caddy >/dev/null 2>&1
        fi

        if ! command -v caddy >/dev/null 2>&1; then
            log_err "Caddy 自动安装失败，请先手动安装 Caddy 后重试！"
            exit 1
        fi
        systemctl enable caddy >/dev/null 2>&1 || true
        log_ok "Caddy 安装完成"
    fi

    mkdir -p "$CADDY_CONF_DIR" "$WEB_ROOT"

    # 确保 /etc/caddy/Caddyfile 存在且包含 import /etc/caddy/233boy/*.conf
    if [[ ! -f "$CADDY_MAIN_CONF" ]]; then
        log_info "正在创建默认主配置文件 $CADDY_MAIN_CONF ..."
        if [[ "$mode" == "reality" ]]; then
            cat << EOF > "$CADDY_MAIN_CONF"
{
    http_port 80
    https_port ${https_port}
}
import ${CADDY_CONF_DIR}/*.conf
EOF
        else
            cat << EOF > "$CADDY_MAIN_CONF"
import ${CADDY_CONF_DIR}/*.conf
EOF
        fi
        log_ok "已初始化 $CADDY_MAIN_CONF"
    else
        if ! grep -q "${CADDY_CONF_DIR}" "$CADDY_MAIN_CONF"; then
            cp -a "$CADDY_MAIN_CONF" "$BACKUP_DIR/caddy/Caddyfile.bak"
            echo "" >> "$CADDY_MAIN_CONF"
            echo "import ${CADDY_CONF_DIR}/*.conf" >> "$CADDY_MAIN_CONF"
            log_ok "已在 $CADDY_MAIN_CONF 中追加 import ${CADDY_CONF_DIR}/*.conf"
        fi
    fi
}

# ==============================================================================
# 部署随机/指定行业静态网站到 /var/www/html
# ==============================================================================
deploy_random_website() {
    local specified="${1:-}"
    local templates=("cloud_saas" "ai_robotics" "quant_fintech" "creative_studio" "green_energy")
    local chosen=""

    if [[ -n "$specified" ]]; then
        chosen="$specified"
    else
        local idx=$(( RANDOM % ${#templates[@]} ))
        chosen="${templates[$idx]}"
    fi

    mkdir -p "$WEB_ROOT"

    case "$chosen" in
        "cloud_saas")
            SITE_NAME="NebulaCloud Enterprise — 云原生可观测性与边缘计算平台"
            cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NebulaCloud | Distributed Edge & Telemetry Infrastructure</title>
<style>
    :root { --bg: #0b0f19; --card: #131b2e; --accent: #38bdf8; --text: #f1f5f9; --muted: #94a3b8; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
    header { display: flex; justify-content: space-between; align-items: center; max-width: 1200px; margin: 0 auto; padding: 24px 20px; border-bottom: 1px solid rgba(255,255,255,0.07); }
    .logo { font-size: 1.35rem; font-weight: 700; color: var(--accent); letter-spacing: -0.5px; }
    nav a { color: var(--muted); text-decoration: none; margin-left: 28px; font-size: 0.95rem; transition: color .2s; }
    nav a:hover { color: var(--text); }
    .hero { max-width: 960px; margin: 90px auto 70px; text-align: center; padding: 0 20px; }
    .badge { display: inline-block; background: rgba(56,189,248,0.12); color: var(--accent); padding: 6px 16px; border-radius: 999px; font-size: 0.82rem; font-weight: 600; margin-bottom: 24px; }
    h1 { font-size: 3.1rem; line-height: 1.18; margin-bottom: 22px; background: linear-gradient(90deg, #fff, #94a3b8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    .hero p { font-size: 1.18rem; color: var(--muted); max-width: 680px; margin: 0 auto 36px; }
    .btn { display: inline-block; background: var(--accent); color: #0b0f19; font-weight: 600; padding: 13px 28px; border-radius: 8px; text-decoration: none; margin: 0 8px; }
    .btn-outline { background: transparent; color: var(--text); border: 1px solid rgba(255,255,255,0.2); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 24px; max-width: 1140px; margin: 40px auto 90px; padding: 0 20px; }
    .card { background: var(--card); padding: 32px; border-radius: 14px; border: 1px solid rgba(255,255,255,0.06); }
    .card h3 { font-size: 1.2rem; margin-bottom: 12px; color: #fff; }
    .card p { color: var(--muted); font-size: 0.95rem; }
    footer { text-align: center; padding: 36px 20px; border-top: 1px solid rgba(255,255,255,0.06); color: var(--muted); font-size: 0.88rem; }
</style>
</head>
<body>
<header>
    <div class="logo">NebulaCloud.io</div>
    <nav>
        <a href="#platform">Platform</a>
        <a href="#telemetry">Telemetry</a>
        <a href="#security">Zero-Trust</a>
        <a href="#status">System Status</a>
    </nav>
</header>
<section class="hero">
    <span class="badge">NEW: Real-Time Telemetry Pipeline v3.4</span>
    <h1>Sub-Millisecond Observability for Global Edge Workloads</h1>
    <p>Ingest, correlate, and analyze distributed traces, metrics, and container logs across 45+ global PoPs with zero configuration overhead.</p>
    <a href="#platform" class="btn">Explore Documentation</a>
    <a href="#status" class="btn btn-outline">Live Network Map</a>
</section>
<section class="grid" id="platform">
    <div class="card">
        <h3>High-Throughput Ingestion</h3>
        <p>Built on lock-free ring buffers and eBPF collectors capable of handling 10M+ events per second per node with minimal CPU footprint.</p>
    </div>
    <div class="card">
        <h3>Automated Anomaly Detection</h3>
        <p>Streaming seasonal decomposition isolates tail-latency spikes and packet loss across multi-cloud Kubernetes clusters in real time.</p>
    </div>
    <div class="card">
        <h3>Cryptographic Audit Logs</h3>
        <p>Immutable Merkle-tree backed telemetry archives ensure SOC2 Type II, ISO 27001, and GDPR compliance out of the box.</p>
    </div>
</section>
<footer>
    &copy; 2026 NebulaCloud Systems Inc. All rights reserved. | Edge Node Status: Operational (99.998% SLA)
</footer>
</body>
</html>
EOF
            ;;

        "ai_robotics")
            SITE_NAME="Synapse Dynamics — 具身智能与工业自动化研究院"
            cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Synapse Dynamics | Embodied AI & Autonomous Robotics</title>
<style>
    :root { --bg: #090a0f; --surface: #12151f; --primary: #a855f7; --secondary: #6366f1; --text: #f3f4f6; --sub: #9ca3af; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: "Inter", -apple-system, sans-serif; background: var(--bg); color: var(--text); line-height: 1.65; }
    header { max-width: 1180px; margin: 0 auto; padding: 26px 24px; display: flex; justify-content: space-between; align-items: center; }
    .brand { font-weight: 800; font-size: 1.3rem; letter-spacing: 1px; text-transform: uppercase; color: #fff; }
    .brand span { color: var(--primary); }
    nav a { color: var(--sub); text-decoration: none; margin-left: 26px; font-size: 0.92rem; }
    .hero { max-width: 940px; margin: 80px auto; padding: 0 24px; text-align: center; }
    h1 { font-size: 3rem; font-weight: 800; margin-bottom: 20px; line-height: 1.2; }
    .hero p { color: var(--sub); font-size: 1.15rem; max-width: 660px; margin: 0 auto 34px; }
    .cta { background: linear-gradient(135deg, var(--primary), var(--secondary)); color: #fff; padding: 14px 32px; border-radius: 999px; text-decoration: none; font-weight: 600; display: inline-block; }
    .metrics { display: flex; justify-content: center; gap: 48px; flex-wrap: wrap; margin: 60px auto; max-width: 900px; border-top: 1px solid #1f2437; border-bottom: 1px solid #1f2437; padding: 32px 20px; }
    .metric h2 { font-size: 2.2rem; color: var(--primary); }
    .metric span { font-size: 0.88rem; color: var(--sub); text-transform: uppercase; letter-spacing: 1px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(290px, 1fr)); gap: 26px; max-width: 1140px; margin: 0 auto 90px; padding: 0 24px; }
    .card { background: var(--surface); padding: 30px; border-radius: 16px; border: 1px solid #1e2336; }
    .card h3 { margin-bottom: 12px; color: #fff; }
    .card p { color: var(--sub); font-size: 0.94rem; }
    footer { text-align: center; padding: 32px; color: var(--sub); font-size: 0.85rem; border-top: 1px solid #161926; }
</style>
</head>
<body>
<header>
    <div class="brand">Synapse<span>Dynamics</span></div>
    <nav>
        <a href="#research">Research</a>
        <a href="#hardware">Kinematic Platforms</a>
        <a href="#publications">Publications</a>
    </nav>
</header>
<section class="hero">
    <h1>Foundation Models for Dexterous Physical Manipulation</h1>
    <p>We train unified vision-language-action (VLA) architectures that enable general-purpose bi-manual robots to operate safely in unstructured industrial environments.</p>
    <a href="#research" class="cta">Read Technical Whitepaper</a>
</section>
<section class="metrics">
    <div class="metric"><h2>1,000 Hz</h2><span>Closed-Loop Torque Control</span></div>
    <div class="metric"><h2>24 DOF</h2><span>Anthropomorphic Hand</span></div>
    <div class="metric"><h2>99.4%</h2><span>Zero-Shot Pick Success</span></div>
</section>
<section class="cards" id="research">
    <div class="card">
        <h3>Sim-to-Real Reinforcement Learning</h3>
        <p>Domain-randomized physics simulation trains tactile policies across millions of contact scenarios before physical deployment.</p>
    </div>
    <div class="card">
        <h3>Proprioceptive Sensor Fusion</h3>
        <p>Low-latency joint encoders combined with high-dynamic-range stereo vision deliver sub-millimeter spatial awareness.</p>
    </div>
    <div class="card">
        <h3>Fleet Telemetry & Safety</h3>
        <p>Deterministic hardware watchdogs and formal control barrier functions guarantee ISO 10218 human-robot collaboration safety.</p>
    </div>
</section>
<footer>
    &copy; 2026 Synapse Dynamics Research Lab. Zurich &middot; Boston &middot; Tokyo
</footer>
</body>
</html>
EOF
            ;;

        "quant_fintech")
            SITE_NAME="Aethelgard Quantitative — 量化算法与流动性研究机构"
            cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Aethelgard Quantitative | Systematic Market Making & Alpha Research</title>
<style>
    :root { --bg: #f8fafc; --navy: #0f172a; --gold: #0284c7; --muted: #475569; --border: #e2e8f0; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: "Georgia", "Times New Roman", serif; background: var(--bg); color: var(--navy); line-height: 1.7; }
    header { background: #fff; border-bottom: 1px solid var(--border); padding: 24px 32px; display: flex; justify-content: space-between; align-items: center; }
    .logo { font-size: 1.35rem; font-weight: 700; letter-spacing: 0.5px; }
    nav a { font-family: -apple-system, sans-serif; font-size: 0.9rem; color: var(--muted); text-decoration: none; margin-left: 28px; }
    .hero { max-width: 920px; margin: 85px auto; padding: 0 24px; }
    .eyebrow { font-family: -apple-system, sans-serif; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 2px; color: var(--gold); font-weight: 700; margin-bottom: 14px; }
    h1 { font-size: 2.85rem; font-weight: 400; line-height: 1.22; margin-bottom: 24px; }
    .hero p { font-size: 1.15rem; color: var(--muted); max-width: 720px; margin-bottom: 32px; }
    .pillars { display: grid; grid-template-columns: repeat(auto-fit, minmax(270px, 1fr)); gap: 28px; max-width: 1100px; margin: 40px auto 90px; padding: 0 24px; font-family: -apple-system, sans-serif; }
    .pillar { background: #fff; padding: 32px; border: 1px solid var(--border); border-top: 3px solid var(--navy); }
    .pillar h3 { font-size: 1.15rem; margin-bottom: 12px; }
    .pillar p { font-size: 0.94rem; color: var(--muted); }
    footer { background: var(--navy); color: #94a3b8; text-align: center; padding: 40px 24px; font-family: -apple-system, sans-serif; font-size: 0.85rem; }
</style>
</head>
<body>
<header>
    <div class="logo">AETHELGARD QUANTITATIVE</div>
    <nav>
        <a href="#approach">Approach</a>
        <a href="#infrastructure">Infrastructure</a>
        <a href="#careers">Careers</a>
        <a href="#investor">Investor Portal</a>
    </nav>
</header>
<section class="hero">
    <div class="eyebrow">Systematic Liquidity & Statistical Arbitrage</div>
    <h1>Scientific Rigor Applied to Global Capital Markets</h1>
    <p>Aethelgard combines stochastic calculus, high-dimensional machine learning, and ultra-low-latency execution engines to provide continuous liquidity across global equities, futures, and FX venues.</p>
</section>
<section class="pillars" id="approach">
    <div class="pillar">
        <h3>Empirical Signal Discovery</h3>
        <p>Petabyte-scale tick data pipelines evaluate microstructure hypotheses across thousands of correlated instruments with strict out-of-sample validation.</p>
    </div>
    <div class="pillar">
        <h3>Deterministic Execution</h3>
        <p>Custom kernel-bypass networking and FPGA-accelerated risk checks ensure sub-microsecond order routing across 60+ global exchanges.</p>
    </div>
    <div class="pillar">
        <h3>Automated Risk Governance</h3>
        <p>Real-time factor exposure neutralization and tail-risk stress testing protect portfolio capital across turbulent market regimes.</p>
    </div>
</section>
<footer>
    &copy; 2026 Aethelgard Quantitative Management LP. For institutional and qualified purchasers only.
</footer>
</body>
</html>
EOF
            ;;

        "creative_studio")
            SITE_NAME="Kinetix Nord — 北欧数字建筑与品牌交互设计工作室"
            cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kinetix Nord | Spatial Architecture & Digital Craft</title>
<style>
    :root { --bg: #141413; --card: #1f1f1d; --accent: #eab308; --text: #fafaf9; --muted: #a8a29e; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: "Helvetica Neue", Arial, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
    header { max-width: 1200px; margin: 0 auto; padding: 32px 24px; display: flex; justify-content: space-between; align-items: center; }
    .logo { font-size: 1.2rem; font-weight: 700; letter-spacing: 3px; }
    nav a { color: var(--muted); text-decoration: none; margin-left: 30px; font-size: 0.9rem; }
    .hero { max-width: 1200px; margin: 70px auto 80px; padding: 0 24px; }
    h1 { font-size: 3.6rem; font-weight: 500; line-height: 1.1; max-width: 880px; margin-bottom: 28px; }
    .hero p { color: var(--muted); font-size: 1.2rem; max-width: 600px; }
    .showcase { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 28px; max-width: 1200px; margin: 0 auto 100px; padding: 0 24px; }
    .work { background: var(--card); padding: 36px; border-radius: 4px; border-left: 3px solid var(--accent); }
    .work span { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 1.5px; color: var(--accent); }
    .work h3 { font-size: 1.4rem; margin: 10px 0 14px; font-weight: 500; }
    .work p { color: var(--muted); font-size: 0.95rem; }
    footer { max-width: 1200px; margin: 0 auto; padding: 40px 24px; border-top: 1px solid #292524; color: var(--muted); font-size: 0.85rem; display: flex; justify-content: space-between; }
</style>
</head>
<body>
<header>
    <div class="logo">KINETIX / NORD</div>
    <nav>
        <a href="#works">Selected Works</a>
        <a href="#philosophy">Philosophy</a>
        <a href="#contact">Copenhagen &middot; Oslo</a>
    </nav>
</header>
<section class="hero">
    <h1>Designing Quiet Digital Spaces & Tactile Brand Systems.</h1>
    <p>An independent multidisciplinary studio bridging Scandinavian architectural minimalism with real-time WebGL and interactive soundscapes.</p>
</section>
<section class="showcase" id="works">
    <div class="work">
        <span>01 / Spatial Exhibition</span>
        <h3>Nordic Pavilion Acoustic Installation</h3>
        <p>Generative audio-reactive timber louvers responding to ambient crowd movement and Nordic weather telemetry.</p>
    </div>
    <div class="work">
        <span>02 / Design System</span>
        <h3>Polestar Autonomous HMI Concept</h3>
        <p>High-contrast typographic cockpit interface engineered for zero glance-distraction during twilight highway cruising.</p>
    </div>
    <div class="work">
        <span>03 / Digital Monograph</span>
        <h3>Arkitektur Archive 1950–2025</h3>
        <p>Interactive photogrammetry repository preserving 400+ brutalist and modernist concrete structures across Northern Europe.</p>
    </div>
</section>
<footer>
    <div>&copy; 2026 Kinetix Nord ApS. All rights reserved.</div>
    <div>Bredgade 45, 1260 København K, Denmark</div>
</footer>
</body>
</html>
EOF
            ;;

        "green_energy")
            SITE_NAME="HeliosGrid Renewables — 智慧储能与清洁能源微电网科技"
            cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HeliosGrid | Autonomous Microgrids & Utility Storage</title>
<style>
    :root { --bg: #061814; --card: #0d2922; --emerald: #10b981; --lime: #34d399; --text: #ecfdf5; --muted: #a7f3d0; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); line-height: 1.65; }
    header { max-width: 1180px; margin: 0 auto; padding: 26px 24px; display: flex; justify-content: space-between; align-items: center; }
    .logo { font-size: 1.35rem; font-weight: 700; color: var(--lime); }
    nav a { color: var(--muted); text-decoration: none; margin-left: 26px; font-size: 0.92rem; }
    .hero { max-width: 920px; margin: 80px auto; text-align: center; padding: 0 24px; }
    h1 { font-size: 3rem; line-height: 1.2; margin-bottom: 20px; }
    .hero p { color: var(--muted); font-size: 1.15rem; max-width: 680px; margin: 0 auto 32px; opacity: 0.9; }
    .btn { background: var(--emerald); color: #04120e; padding: 14px 30px; border-radius: 8px; font-weight: 700; text-decoration: none; display: inline-block; }
    .features { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 24px; max-width: 1140px; margin: 40px auto 90px; padding: 0 24px; }
    .feature { background: var(--card); padding: 30px; border-radius: 12px; border: 1px solid rgba(52,211,153,0.15); }
    .feature h3 { color: var(--lime); margin-bottom: 10px; }
    .feature p { color: var(--text); opacity: 0.82; font-size: 0.95rem; }
    footer { text-align: center; padding: 34px; border-top: 1px solid rgba(52,211,153,0.12); color: var(--muted); font-size: 0.86rem; opacity: 0.75; }
</style>
</head>
<body>
<header>
    <div class="logo">HeliosGrid Energy</div>
    <nav>
        <a href="#storage">Grid Storage</a>
        <a href="#dispatch">AI Dispatch</a>
        <a href="#sustainability">Impact</a>
    </nav>
</header>
<section class="hero">
    <h1>24/7 Dispatchable Baseload Power from Renewables</h1>
    <p>HeliosGrid pairs utility-scale iron-air and lithium-iron-phosphate (LFP) battery arrays with predictive weather-market bidding software.</p>
    <a href="#storage" class="btn">View Live Grid Telemetry</a>
</section>
<section class="features" id="storage">
    <div class="feature">
        <h3>Sub-Second Frequency Regulation</h3>
        <p>Grid-forming inverters stabilize regional transmission voltage and synthetic inertia within 15 milliseconds of load fluctuations.</p>
    </div>
    <div class="feature">
        <h3>100-Hour Multi-Day Storage</h3>
        <p>Modular thermal and electrochemical enclosures bridge multi-day wind and solar lulls at a fraction of legacy peaker plant cost.</p>
    </div>
    <div class="feature">
        <h3>SCADA & Telemetry Security</h3>
        <p>End-to-end TLS 1.3 hardware-authenticated telemetry channels protect substation assets in full compliance with NERC CIP standards.</p>
    </div>
</section>
<footer>
    &copy; 2026 HeliosGrid Renewables Corp. Clean Energy Infrastructure &middot; ISO 14001 Certified
</footer>
</body>
</html>
EOF
            ;;
    esac

    log_ok "已部署静态伪装网站模板: ${SITE_NAME} -> ${WEB_ROOT}/index.html"
}

# ==============================================================================
# 重启并校验 Sing-box 与 Caddy 服务
# ==============================================================================
restart_services() {
    log_info "正在校验并重启 Sing-box 与 Caddy 服务..."

    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c /etc/sing-box/config.json -C "$SINGBOX_CONF_DIR" >/dev/null 2>&1; then
            log_ok "Sing-box 配置语法校验通过"
        else
            log_warn "sing-box check 返回警告，请留意服务状态"
        fi
    fi

    if systemctl is-active --quiet sing-box || systemctl list-unit-files | grep -q "^sing-box\.service"; then
        systemctl restart sing-box
        log_ok "sing-box 服务已重启"
    else
        log_warn "未检测到 systemd 中的 sing-box 服务，请手动重启 sing-box"
    fi

    if systemctl is-active --quiet caddy || systemctl list-unit-files | grep -q "^caddy\.service"; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        log_ok "caddy 服务已重载/重启"
    else
        log_warn "未检测到 systemd 中的 caddy 服务，请手动重启 caddy"
    fi
}

# ==============================================================================
# 功能 1：优化 VMess-WS-TLS 协议 + Caddy 配置 + 随机静态网站
# ==============================================================================
optimize_vmess_ws_tls() {
    if [[ ! -d "$SINGBOX_CONF_DIR" ]]; then
        log_err "未找到 Sing-box 配置目录: $SINGBOX_CONF_DIR"
        return 1
    fi

    ensure_parser
    mkdir -p "$BACKUP_DIR/sing-box" "$BACKUP_DIR/caddy"
    ensure_caddy "vmess"

    echo ""
    read -r -p "请输入 WebSocket 伪装路径 [直接回车默认 ${DEFAULT_WS_PATH}]: " input_ws_path
    local target_ws_path="${input_ws_path:-$DEFAULT_WS_PATH}"
    # 确保以 / 开头
    [[ "$target_ws_path" != /* ]] && target_ws_path="/$target_ws_path"

    shopt -s nullglob
    local conf_files=("$SINGBOX_CONF_DIR"/VMess-WS-TLS-*.json "$SINGBOX_CONF_DIR"/*vmess*.json)
    shopt -u nullglob

    declare -A seen_files
    local unique_files=()
    for f in "${conf_files[@]}"; do
        if [[ -f "$f" && -z "${seen_files[$f]:-}" ]]; then
            seen_files["$f"]=1
            unique_files+=("$f")
        fi
    done

    if [[ ${#unique_files[@]} -eq 0 ]]; then
        log_err "在 $SINGBOX_CONF_DIR 中未找到任何 VMess-WS-TLS 配置文件！"
        return 1
    fi

    local optimized_count=0
    local summary_list=()

    for conf_file in "${unique_files[@]}"; do
        local filename
        filename=$(basename "$conf_file")
        log_info "正在检查配置文件: $conf_file"

        local inbound_type="" trans_type="" listen_port="" domain="" uuid=""
        if [[ "$PARSER" == "jq" ]]; then
            inbound_type=$(jq -r '.inbounds[0].type // empty' "$conf_file")
            trans_type=$(jq -r '.inbounds[0].transport.type // empty' "$conf_file")
            listen_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file")
            domain=$(jq -r '.inbounds[0].transport.headers.host // .inbounds[0].transport.headers.Host // empty' "$conf_file")
            uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$conf_file")
        else
            read -r inbound_type trans_type listen_port domain uuid < <(python3 - "$conf_file" << 'PYEOF'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    d = json.load(f)
ib = (d.get('inbounds') or [{}])[0]
tr = ib.get('transport') or {}
hdr = tr.get('headers') or {}
usr = (ib.get('users') or [{}])[0]
print(
    ib.get('type', ''),
    tr.get('type', ''),
    ib.get('listen_port', ''),
    hdr.get('host') or hdr.get('Host') or '',
    usr.get('uuid', '')
)
PYEOF
)
        fi

        if [[ "$inbound_type" != "vmess" || "$trans_type" != "ws" ]]; then
            log_warn "跳过非 VMess-WS 配置文件: $filename (type=$inbound_type, transport=$trans_type)"
            continue
        fi

        # 若 headers.host 已被移除，尝试从文件名提取域名
        if [[ -z "$domain" ]]; then
            if [[ "$filename" =~ ^VMess-WS-TLS-(.+)\.json$ ]]; then
                domain="${BASH_REMATCH[1]}"
            else
                domain="${filename%.json}"
            fi
        fi

        # 若域名依旧不像有效域名，提示用户输入
        if [[ -z "$domain" || "$domain" != *.* ]]; then
            read -r -p "未能从 $filename 自动识别域名，请手动输入该节点的域名: " domain
        fi

        if [[ -z "$listen_port" || -z "$domain" ]]; then
            log_err "无法从 $filename 中提取完整的端口或域名 (domain=$domain, port=$listen_port)，跳过。"
            continue
        fi

        # 备份原配置
        cp -a "$conf_file" "$BACKUP_DIR/sing-box/$filename"

        # 修改 Sing-box 配置文件
        if [[ "$PARSER" == "jq" ]]; then
            local tmp_json
            tmp_json=$(mktemp)
            jq --arg path "$target_ws_path" --argjson ed "$EARLY_DATA_SIZE" '
                .inbounds[0].transport = {
                    "type": "ws",
                    "path": $path,
                    "max_early_data": $ed,
                    "early_data_header_name": "Sec-WebSocket-Protocol"
                }
            ' "$conf_file" > "$tmp_json" && mv "$tmp_json" "$conf_file"
        else
            python3 - "$conf_file" "$target_ws_path" "$EARLY_DATA_SIZE" << 'PYEOF'
import json, sys
path, ws_path, ed = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
if data.get('inbounds'):
    data['inbounds'][0]['transport'] = {
        "type": "ws",
        "path": ws_path,
        "max_early_data": ed,
        "early_data_header_name": "Sec-WebSocket-Protocol"
    }
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
        fi
        log_ok "已优化 Sing-box 配置: $conf_file (端口: $listen_port, 路径: $target_ws_path)"

        # 生成对应 Caddy 配置
        local caddy_file="$CADDY_CONF_DIR/${domain}.conf"
        if [[ -f "$caddy_file" ]]; then
            cp -a "$caddy_file" "$BACKUP_DIR/caddy/${domain}.conf"
        fi

        cat << EOF > "$caddy_file"
${domain} {
    # 1. 严格匹配 WebSocket 升级握手
    @v2ws {
        path ${target_ws_path}
        header Connection *Upgrade*
        header Upgrade websocket
    }

    # 2. 命中 WS 时反代给本地 Sing-box
    handle @v2ws {
        reverse_proxy 127.0.0.1:${listen_port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }

    # 3. 探针若发普通请求摸代理路径，返回带明确提示的 404
    handle ${target_ws_path}* {
        respond "404 Not Found" 404
    }

    # 4. 其他所有正常网页访问，展示静态网站
    handle {
        root * ${WEB_ROOT}
        file_server
    }
}
EOF
        log_ok "已写入 Caddy 配置: $caddy_file"

        optimized_count=$((optimized_count + 1))
        summary_list+=("域名: ${domain} | 本地端口: ${listen_port} | UUID: ${uuid} | WS路径: ${target_ws_path}?ed=${EARLY_DATA_SIZE}")
    done

    if [[ $optimized_count -eq 0 ]]; then
        log_err "未能成功优化任何 VMess-WS-TLS 配置文件。"
        return 1
    fi

    deploy_random_website
    restart_services

    echo ""
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN} 🎉 VMess-WS-TLS + Caddy + 静态伪装网站 一键优化完成！${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "📦 原配置备份目录 : ${YELLOW}${BACKUP_DIR}${NC}"
    echo -e "🌐 伪装网站目录   : ${YELLOW}${WEB_ROOT}/index.html${NC} (${SITE_NAME})"
    echo -e "🔗 优化节点列表   :"
    for item in "${summary_list[@]}"; do
        echo -e "   - ${CYAN}${item}${NC}"
    done
    echo ""
    echo -e "${YELLOW}💡 客户端连接参数更新提示：${NC}"
    echo -e "   1. WebSocket Path (路径) 改为: ${GREEN}${target_ws_path}${NC} (或 ${GREEN}${target_ws_path}?ed=${EARLY_DATA_SIZE}${NC})"
    echo -e "   2. Early Data 长度: ${GREEN}${EARLY_DATA_SIZE}${NC}，Header 名称: ${GREEN}Sec-WebSocket-Protocol${NC}"
    echo -e "${GREEN}======================================================================${NC}"
}

# ==============================================================================
# 功能 2：修改 VLESS-REALITY 协议 (偷自己域名 Self-Steal) + Caddy 静态网站
# ==============================================================================
optimize_vless_reality() {
    if [[ ! -d "$SINGBOX_CONF_DIR" ]]; then
        log_err "未找到 Sing-box 配置目录: $SINGBOX_CONF_DIR"
        return 1
    fi

    ensure_parser
    mkdir -p "$BACKUP_DIR/sing-box" "$BACKUP_DIR/caddy"

    # 扫描所有 VLESS-REALITY 配置文件
    shopt -s nullglob
    local candidate_files=("$SINGBOX_CONF_DIR"/VLESS-REALITY-*.json "$SINGBOX_CONF_DIR"/*reality*.json "$SINGBOX_CONF_DIR"/*.json)
    shopt -u nullglob

    declare -A seen_files
    local reality_files=()
    for f in "${candidate_files[@]}"; do
        if [[ -f "$f" && -z "${seen_files[$f]:-}" ]]; then
            seen_files["$f"]=1
            local is_reality=""
            if [[ "$PARSER" == "jq" ]]; then
                is_reality=$(jq -r 'if (.inbounds[0].type == "vless" and .inbounds[0].tls.reality.enabled == true) then "yes" else "no" end' "$f" 2>/dev/null || echo "no")
            else
                is_reality=$(python3 - "$f" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fp:
        d = json.load(fp)
    ib = (d.get('inbounds') or [{}])[0]
    if ib.get('type') == 'vless' and ((ib.get('tls') or {}).get('reality') or {}).get('enabled') is True:
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
PYEOF
)
            fi
            if [[ "$is_reality" == "yes" ]]; then
                reality_files+=("$f")
            fi
        fi
    done

    if [[ ${#reality_files[@]} -eq 0 ]]; then
        log_err "在 $SINGBOX_CONF_DIR 中未找到任何启用了 REALITY 的 VLESS 配置文件！"
        return 1
    fi

    # 若存在多个 REALITY 配置文件，允许用户选择
    local target_files=()
    if [[ ${#reality_files[@]} -eq 1 ]]; then
        target_files=("${reality_files[0]}")
        log_info "自动识别到 VLESS-REALITY 配置文件: ${target_files[0]}"
    else
        echo ""
        echo -e "${CYAN}检测到多个 VLESS-REALITY 配置文件：${NC}"
        local idx=1
        for rf in "${reality_files[@]}"; do
            echo -e "  [${GREEN}${idx}${NC}] $(basename "$rf")"
            idx=$((idx + 1))
        done
        echo -e "  [${GREEN}0${NC}] 全部修改"
        read -r -p "请选择要修改的配置文件序号 [默认 1]: " file_choice
        file_choice="${file_choice:-1}"
        if [[ "$file_choice" == "0" ]]; then
            target_files=("${reality_files[@]}")
        elif [[ "$file_choice" =~ ^[0-9]+$ ]] && (( file_choice >= 1 && file_choice <= ${#reality_files[@]} )); then
            target_files=("${reality_files[$((file_choice - 1))]}")
        else
            log_err "无效的序号选择"
            return 1
        fi
    fi

    # 交互式输入自建域名 (必填)
    echo ""
    local self_domain=""
    while [[ -z "$self_domain" ]]; do
        read -r -p "请输入已解析到本机的域名 (用于搭建静态网站与 REALITY SNI，如 node1.example.com): " self_domain
        self_domain=$(echo "$self_domain" | tr -d '[:space:]')
        # 去除可能误输入的 http:// 或 https:// 及尾部斜杠
        self_domain="${self_domain#http://}"
        self_domain="${self_domain#https://}"
        self_domain="${self_domain%%/*}"
        if [[ -z "$self_domain" || "$self_domain" != *.* ]]; then
            log_warn "请输入合法的域名（需提前在 DNS 服务商处将 A/AAAA 记录解析至本机 IP，且不要开启 Cloudflare 小黄云代理）！"
            self_domain=""
        fi
    done

    # 交互式输入 Caddy 本地回源 HTTPS 端口 (默认 8443)
    read -r -p "请输入 Caddy 本地 HTTPS 监听端口 (供 Sing-box REALITY 握手偷取证书) [默认 ${DEFAULT_REALITY_CADDY_PORT}]: " caddy_https_port
    caddy_https_port="${caddy_https_port:-$DEFAULT_REALITY_CADDY_PORT}"

    # 确保 Caddy 已安装且配置目录就绪
    ensure_caddy "reality" "$caddy_https_port"

    local summary_list=()

    for conf_file in "${target_files[@]}"; do
        local filename
        filename=$(basename "$conf_file")
        cp -a "$conf_file" "$BACKUP_DIR/sing-box/$filename"

        local listen_port="" uuid="" old_sni="" pub_key="" short_id=""
        if [[ "$PARSER" == "jq" ]]; then
            listen_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file")
            uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$conf_file")
            old_sni=$(jq -r '.inbounds[0].tls.server_name // empty' "$conf_file")
            short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "$conf_file")
            pub_key=$(jq -r '.outbounds[]? | select(.tag != null and (.tag | startswith("public_key_"))) | .tag | sub("^public_key_"; "")' "$conf_file" | head -n1)
        else
            read -r listen_port uuid old_sni short_id pub_key < <(python3 - "$conf_file" << 'PYEOF'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    d = json.load(f)
ib = (d.get('inbounds') or [{}])[0]
tls = ib.get('tls') or {}
rl = tls.get('reality') or {}
sids = rl.get('short_id') or ['']
usr = (ib.get('users') or [{}])[0]
pub = ''
for ob in (d.get('outbounds') or []):
    t = ob.get('tag', '')
    if t.startswith('public_key_'):
        pub = t[len('public_key_'):]
        break
print(
    ib.get('listen_port', ''),
    usr.get('uuid', ''),
    tls.get('server_name', ''),
    sids[0] if sids else '',
    pub
)
PYEOF
)
        fi

        # 修改 Sing-box VLESS-REALITY 配置：
        # 1. tls.server_name -> $self_domain
        # 2. tls.reality.handshake.server -> "127.0.0.1"
        # 3. tls.reality.handshake.server_port -> $caddy_https_port (整数)
        if [[ "$PARSER" == "jq" ]]; then
            local tmp_json
            tmp_json=$(mktemp)
            jq --arg domain "$self_domain" --argjson hport "$caddy_https_port" '
                .inbounds[0].tls.server_name = $domain |
                .inbounds[0].tls.reality.handshake.server = "127.0.0.1" |
                .inbounds[0].tls.reality.handshake.server_port = $hport
            ' "$conf_file" > "$tmp_json" && mv "$tmp_json" "$conf_file"
        else
            python3 - "$conf_file" "$self_domain" "$caddy_https_port" << 'PYEOF'
import json, sys
path, domain, hport = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
if data.get('inbounds'):
    tls = data['inbounds'][0].setdefault('tls', {})
    tls['server_name'] = domain
    reality = tls.setdefault('reality', {})
    handshake = reality.setdefault('handshake', {})
    handshake['server'] = "127.0.0.1"
    handshake['server_port'] = hport
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
        fi

        log_ok "已更新 Sing-box REALITY 配置: $conf_file (原 SNI: ${old_sni} -> 新 SNI: ${self_domain}, 握手目标: 127.0.0.1:${caddy_https_port})"
        summary_list+=("配置文件: ${filename} | 监听端口: ${listen_port} | 新 SNI (server_name): ${self_domain} | UUID: ${uuid} | PublicKey: ${pub_key:-未记录} | ShortID: ${short_id:-空}")
    done

    # 写入 /etc/caddy/233boy/<域名>.conf
    # 说明：
    # - 块 1: https://${self_domain}:${caddy_https_port} 仅绑定 127.0.0.1，供本地 Sing-box REALITY 握手回源并提供静态网页，不占用外部 443 端口
    # - 块 2: http://${self_domain}:80 监听 80 端口，让 Caddy 自动通过 HTTP-01 验证申请/续期 Let's Encrypt 证书，并将普通 HTTP 访问 301 跳转至 https://${self_domain} (即 443 端口的 Sing-box REALITY，再由 Sing-box 透明回源到 Caddy 展示静态网站)
    local caddy_file="$CADDY_CONF_DIR/${self_domain}.conf"
    if [[ -f "$caddy_file" ]]; then
        cp -a "$caddy_file" "$BACKUP_DIR/caddy/${self_domain}.conf"
    fi

    cat << EOF > "$caddy_file"
https://${self_domain}:${caddy_https_port} {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    root * ${WEB_ROOT}
    file_server
}

http://${self_domain}:80 {
    redir https://${self_domain}{uri} permanent
}
EOF
    log_ok "已写入 Caddy REALITY 自偷站点配置: $caddy_file"

    deploy_random_website
    restart_services

    echo ""
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN} 🎉 VLESS-REALITY (自建域名伪装站 Self-Steal) 一键配置完成！${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "📦 原配置备份目录 : ${YELLOW}${BACKUP_DIR}${NC}"
    echo -e "🌐 伪装网站目录   : ${YELLOW}${WEB_ROOT}/index.html${NC} (${SITE_NAME})"
    echo -e "📄 Caddy 配置文件 : ${YELLOW}${caddy_file}${NC} (本地回源端口: 127.0.0.1:${caddy_https_port})"
    echo -e "🔗 优化节点详情   :"
    for item in "${summary_list[@]}"; do
        echo -e "   - ${CYAN}${item}${NC}"
    done
    echo ""
    echo -e "${YELLOW}💡 客户端连接参数更新提示：${NC}"
    echo -e "   1. 请将客户端中的 ${GREEN}SNI (Server Name / 伪装域名)${NC} 修改为: ${GREEN}${self_domain}${NC}"
    echo -e "   2. 客户端连接地址 (Address) 可继续填服务器 IP 或直接填写 ${GREEN}${self_domain}${NC}"
    echo -e "   3. UUID、PublicKey (公钥)、ShortID、端口 均保持不变！"
    echo -e "   4. 现在直接在浏览器访问 ${GREEN}https://${self_domain}${NC} 即可看到真实 HTTPS 证书的静态伪装网站。"
    echo -e "${GREEN}======================================================================${NC}"
}

# ==============================================================================
# 功能 3：单独更换静态网站模板菜单
# ==============================================================================
change_website_menu() {
    echo ""
    echo -e "${CYAN}请选择要部署的静态伪装网站模板：${NC}"
    echo -e "  [${GREEN}1${NC}] NebulaCloud Enterprise  (云原生可观测性与边缘计算 SaaS 平台)"
    echo -e "  [${GREEN}2${NC}] Synapse Dynamics        (具身智能与工业自动化机器人研究院)"
    echo -e "  [${GREEN}3${NC}] Aethelgard Quantitative (量化算法与全球流动性研究机构)"
    echo -e "  [${GREEN}4${NC}] Kinetix Nord            (北欧数字建筑与品牌交互设计工作室)"
    echo -e "  [${GREEN}5${NC}] HeliosGrid Renewables   (智慧储能与清洁能源微电网科技)"
    echo -e "  [${GREEN}0${NC}] 随机抽取一套 (默认)"
    read -r -p "请输入选项 [0-5, 默认 0]: " tpl_choice
    tpl_choice="${tpl_choice:-0}"

    case "$tpl_choice" in
        1) deploy_random_website "cloud_saas" ;;
        2) deploy_random_website "ai_robotics" ;;
        3) deploy_random_website "quant_fintech" ;;
        4) deploy_random_website "creative_studio" ;;
        5) deploy_random_website "green_energy" ;;
        *) deploy_random_website ;;
    esac
}

# ==============================================================================
# 交互式主菜单
# ==============================================================================
show_main_menu() {
    clear 2>/dev/null || true
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${GREEN}       Sing-box (233boy) & Caddy 协议伪装一键优化脚本 (支持自偷站)      ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "  [${GREEN}1${NC}] 一键优化 ${CYAN}VMess-WS-TLS${NC} 协议 (自动提取域名/端口 + Caddy 防探测 + 随机静态站)"
    echo -e "  [${GREEN}2${NC}] 一键修改 ${CYAN}VLESS-REALITY${NC} 协议 (改为偷本机域名 + Caddy 自动签发证书 + 随机静态站)"
    echo -e "  [${GREEN}3${NC}] 仅更换 ${CYAN}/var/www/html${NC} 静态伪装网站模板 (内置 5 套行业站点)"
    echo -e "  [${GREEN}0${NC}] 退出脚本"
    echo -e "${BLUE}======================================================================${NC}"
    read -r -p "请输入操作序号 [0-3]: " menu_choice

    case "$menu_choice" in
        1)
            optimize_vmess_ws_tls
            ;;
        2)
            optimize_vless_reality
            ;;
        3)
            change_website_menu
            ;;
        0)
            log_info "已退出脚本。"
            exit 0
            ;;
        *)
            log_err "输入无效，请输入 0-3 之间的数字！"
            exit 1
            ;;
    esac
}

# 支持命令行参数快速调用，或无参数进入交互菜单
if [[ $# -gt 0 ]]; then
    case "$1" in
        vmess|--vmess)
            optimize_vmess_ws_tls
            ;;
        reality|--reality)
            optimize_vless_reality
            ;;
        web|--web)
            change_website_menu
            ;;
        *)
            # 兼容旧版直接传自定义 WS 路径的用法
            DEFAULT_WS_PATH="$1"
            optimize_vmess_ws_tls
            ;;
    esac
else
    show_main_menu
fi
