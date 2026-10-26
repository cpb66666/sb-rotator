#!/usr/bin/env bash
# ==============================================================================
# Sing-box (233boy) VMess-WS-TLS & Caddy 一键伪装优化脚本
# 功能：
#   1. 自动扫描 /etc/sing-box/conf 下所有 VMess-WS-TLS 配置文件
#   2. 提取域名 (host) 与本地监听端口 (listen_port)
#   3. 优化 Sing-box 配置：修改 path 为 /api/v3/telemetry/stream，开启 max_early_data (2048)，移除冗余 headers
#   4. 重写 /etc/caddy/233boy/<域名>.conf：严格校验 WebSocket 握手，防探测返回 404，其余流量展示静态站点
#   5. 内置 5 套不同行业的精美响应式 HTML 静态网站模板，随机抽取一套部署至 /var/www/html
#   6. 自动备份原配置并重启 sing-box 与 caddy 服务
# ==============================================================================

set -euo pipefail

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. 权限与环境检查
if [[ $EUID -ne 0 ]]; then
    log_err "请使用 root 用户运行此脚本 (sudo bash $0)"
    exit 1
fi

SINGBOX_CONF_DIR="/etc/sing-box/conf"
CADDY_CONF_DIR="/etc/caddy/233boy"
WEB_ROOT="/var/www/html"
TARGET_WS_PATH="${1:-/api/v3/telemetry/stream}"
EARLY_DATA_SIZE=2048
BACKUP_DIR="/root/singbox_caddy_backup_$(date +%Y%m%d_%H%M%S)"

if [[ ! -d "$SINGBOX_CONF_DIR" ]]; then
    log_err "未找到 Sing-box 配置目录: $SINGBOX_CONF_DIR"
    exit 1
fi

# 检查解析工具 (优先使用 jq，若无则检查 python3，若均无则自动安装 jq)
PARSER=""
if command -v jq >/dev/null 2>&1; then
    PARSER="jq"
elif command -v python3 >/dev/null 2>&1; then
    PARSER="python3"
else
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
        log_err "无法安装 jq 且未检测到 python3，请先手动安装 jq (apt install -y jq)"
        exit 1
    fi
fi

mkdir -p "$BACKUP_DIR/sing-box" "$BACKUP_DIR/caddy" "$CADDY_CONF_DIR" "$WEB_ROOT"

# ==============================================================================
# 2. 部署随机行业静态网站到 /var/www/html
# ==============================================================================
deploy_random_website() {
    local templates=("cloud_saas" "ai_robotics" "quant_fintech" "creative_studio" "green_energy")
    local idx=$(( RANDOM % ${#templates[@]} ))
    local chosen="${templates[$idx]}"

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

    log_ok "已随机选择并生成静态网站模板: ${SITE_NAME} -> ${WEB_ROOT}/index.html"
}

# ==============================================================================
# 3. 扫描并优化 /etc/sing-box/conf 下的 VMess-WS-TLS 配置与对应 Caddy 配置
# ==============================================================================
shopt -s nullglob
CONF_FILES=("$SINGBOX_CONF_DIR"/VMess-WS-TLS-*.json "$SINGBOX_CONF_DIR"/*vmess*.json)
shopt -u nullglob

# 去重文件列表
declare -A SEEN_FILES
UNIQUE_FILES=()
for f in "${CONF_FILES[@]}"; do
    if [[ -f "$f" && -z "${SEEN_FILES[$f]:-}" ]]; then
        SEEN_FILES["$f"]=1
        UNIQUE_FILES+=("$f")
    fi
done

if [[ ${#UNIQUE_FILES[@]} -eq 0 ]]; then
    log_err "在 $SINGBOX_CONF_DIR 中未找到任何 VMess-WS-TLS 配置文件！"
    exit 1
fi

OPTIMIZED_COUNT=0
SUMMARY_LIST=()

for conf_file in "${UNIQUE_FILES[@]}"; do
    filename=$(basename "$conf_file")
    log_info "正在检查配置文件: $conf_file"

    # 提取 type, transport.type, listen_port, host, uuid
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

    # 仅处理 vmess + ws 的配置
    if [[ "$inbound_type" != "vmess" || "$trans_type" != "ws" ]]; then
        log_warn "跳过非 VMess-WS 配置文件: $filename (type=$inbound_type, transport=$trans_type)"
        continue
    fi

    # 若 headers.host 已被移除（如之前已执行过优化），则从文件名 VMess-WS-TLS-<domain>.json 中提取域名
    if [[ -z "$domain" ]]; then
        if [[ "$filename" =~ ^VMess-WS-TLS-(.+)\.json$ ]]; then
            domain="${BASH_REMATCH[1]}"
        else
            domain="${filename%.json}"
        fi
    fi

    if [[ -z "$listen_port" || -z "$domain" ]]; then
        log_err "无法从 $filename 中提取完整的端口或域名 (domain=$domain, port=$listen_port)，跳过。"
        continue
    fi

    # 备份原始 Sing-box 配置
    cp -a "$conf_file" "$BACKUP_DIR/sing-box/$filename"

    # 修改 Sing-box 配置文件：
    # - 保留原有 tag, type, listen, listen_port, users
    # - 将 transport 替换为优化后的结构 (path="/api/v3/telemetry/stream", max_early_data=2048, early_data_header_name="Sec-WebSocket-Protocol")
    if [[ "$PARSER" == "jq" ]]; then
        tmp_json=$(mktemp)
        jq --arg path "$TARGET_WS_PATH" --argjson ed "$EARLY_DATA_SIZE" '
            .inbounds[0].transport = {
                "type": "ws",
                "path": $path,
                "max_early_data": $ed,
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        ' "$conf_file" > "$tmp_json" && mv "$tmp_json" "$conf_file"
    else
        python3 - "$conf_file" "$TARGET_WS_PATH" "$EARLY_DATA_SIZE" << 'PYEOF'
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
    log_ok "已优化 Sing-box 配置: $conf_file (端口: $listen_port, 路径: $TARGET_WS_PATH)"

    # 备份并生成对应的 Caddy 配置文件 /etc/caddy/233boy/<domain>.conf
    caddy_file="$CADDY_CONF_DIR/${domain}.conf"
    if [[ -f "$caddy_file" ]]; then
        cp -a "$caddy_file" "$BACKUP_DIR/caddy/${domain}.conf"
    fi

    cat << EOF > "$caddy_file"
${domain} {
    # 1. 严格匹配 WebSocket 升级握手
    @v2ws {
        path ${TARGET_WS_PATH}
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
    handle ${TARGET_WS_PATH}* {
        respond "404 Not Found" 404
    }

    # 4. 其他所有正常网页访问，展示静态网站
    handle {
        root * ${WEB_ROOT}
        file_server
    }
}
EOF
    log_ok "已更新 Caddy 配置: $caddy_file"

    OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
    SUMMARY_LIST+=("域名: ${domain} | 本地端口: ${listen_port} | UUID: ${uuid} | WS路径: ${TARGET_WS_PATH}?ed=${EARLY_DATA_SIZE}")
done

if [[ $OPTIMIZED_COUNT -eq 0 ]]; then
    log_err "未能成功优化任何 VMess-WS-TLS 配置文件，请检查 $SINGBOX_CONF_DIR 下的文件内容。"
    exit 1
fi

# 部署随机静态网站
deploy_random_website

# ==============================================================================
# 4. 校验并重启 Sing-box 与 Caddy 服务
# ==============================================================================
log_info "正在重启 Sing-box 与 Caddy 服务..."

if command -v sing-box >/dev/null 2>&1; then
    if sing-box check -c /etc/sing-box/config.json -C "$SINGBOX_CONF_DIR" >/dev/null 2>&1; then
        log_ok "Sing-box 配置语法校验通过"
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

# ==============================================================================
# 5. 输出优化结果汇总
# ==============================================================================
echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN} 🎉 VMess-WS-TLS + Caddy + 静态伪装网站 一键优化完成！${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "📦 原配置备份目录 : ${YELLOW}${BACKUP_DIR}${NC}"
echo -e "🌐 伪装网站目录   : ${YELLOW}${WEB_ROOT}/index.html${NC} (${SITE_NAME})"
echo -e "🔗 优化节点列表   :"
for item in "${SUMMARY_LIST[@]}"; do
    echo -e "   - ${CYAN}${item}${NC}"
done
echo ""
echo -e "${YELLOW}💡 客户端连接参数更新提示：${NC}"
echo -e "   请将客户端 (v2rayN / Clash Meta / Shadowrocket / Sing-box) 中的："
echo -e "   1. WebSocket Path (路径) 修改为: ${GREEN}${TARGET_WS_PATH}${NC} (或带 Early Data: ${GREEN}${TARGET_WS_PATH}?ed=${EARLY_DATA_SIZE}${NC})"
echo -e "   2. Early Data 长度 (Max Early Data): ${GREEN}${EARLY_DATA_SIZE}${NC}，Header 名称: ${GREEN}Sec-WebSocket-Protocol${NC}"
echo -e "${GREEN}======================================================================${NC}"
