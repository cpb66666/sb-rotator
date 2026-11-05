#!/bin/bash
set -e

# ================= 颜色定义 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${BLUE}====================================================${PLAIN}"
echo -e "${BLUE}       REALITY 404 回落 & iptables 一键部署脚本      ${PLAIN}"
echo -e "${BLUE}====================================================${PLAIN}"

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[错误] 必须使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 2. 获取本机公网 IPv4
echo -e "${YELLOW}[1/6] 正在获取本机公网 IP...${PLAIN}"
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me || curl -s4 --max-time 5 https://icanhazip.com)

if [[ -z "$SERVER_IP" ]]; then
    echo -e "${RED}[错误] 无法获取本机公网 IP，请手动输入：${PLAIN}"
    read -p "请输入公网 IP: " SERVER_IP
fi
echo -e "${GREEN}检测到本机公网 IP: ${SERVER_IP}${PLAIN}"

# 3. 提示输入域名并校验解析
echo ""
read -p "请输入你已经解析到该 IP 的域名 (例如: node.yourdomain.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}[错误] 域名不能为空！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}[2/6] 正在校验域名 DNS 解析...${PLAIN}"
RESOLVED_IP=$(ping -4 -c 1 "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
if [[ -z "$RESOLVED_IP" ]]; then
    RESOLVED_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n1)
fi

echo -e "域名解析结果: ${RESOLVED_IP:-未知}"
if [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    echo -e "${YELLOW}[警告] 域名解析 IP ($RESOLVED_IP) 与本机 IP ($SERVER_IP) 不一致！${PLAIN}"
    read -p "如果刚改了解析或使用了 CDN，是否强制继续申请证书? [y/N]: " FORCE_RUN
    if [[ "$FORCE_RUN" != "y" && "$FORCE_RUN" != "Y" ]]; then
        echo -e "${RED}已取消操作，请等待 DNS 生效后再试。${PLAIN}"
        exit 1
    fi
fi

# 4. 安装基础软件包
echo -e "${YELLOW}[3/6] 正在安装必要软件包 (Nginx, Certbot, iptables)...${PLAIN}"
if grep -qi -E "ubuntu|debian" /etc/issue /etc/os-release; then
    apt-get update -y
    # 免交互安装 iptables-persistent
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot iptables iptables-persistent netfilter-persistent
elif grep -qi -E "centos|almalinux|rocky|rhel" /etc/issue /etc/os-release; then
    dnf install -y epel-release || yum install -y epel-release
    dnf install -y nginx certbot iptables iptables-services || yum install -y nginx certbot iptables iptables-services
    systemctl enable iptables
    systemctl start iptables
else
    echo -e "${RED}[错误] 未受支持的系统类型，请使用 Debian/Ubuntu 或 CentOS 系列。${PLAIN}"
    exit 1
fi

# 5. 停止可能占用 80 端口的临时服务并申请证书
echo -e "${YELLOW}[4/6] 申请 SSL 证书中...${PLAIN}"
systemctl stop nginx || true

certbot certonly --standalone -d "$DOMAIN" --agree-tos --register-unsafely-without-email --force-renewal

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    echo -e "${RED}[错误] SSL 证书申请失败！请检查 80 端口是否被其他程序占用，或域名解析是否正确。${PLAIN}"
    exit 1
fi
echo -e "${GREEN}SSL 证书申请成功！${PLAIN}"

# 6. 配置 Nginx 404 伪装站
echo -e "${YELLOW}[5/6] 正在配置 Nginx 404 站点...${PLAIN}"

# 清理默认 default 配置以防端口冲突
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

cat << NGINX_CONF > /etc/nginx/conf.d/reality_404.conf
# 80 端口访问一律返回 404
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 404;
}

# 回落本地端口 8443，开启 SSL，所有路由一律 404
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 404 伪装响应
    location / {
        return 404;
    }

    # 自定义 404 页面
    error_page 404 = @custom_404;
    location @custom_404 {
        default_type text/html;
        return 404 '<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>';
    }
}
NGINX_CONF

# 启动并使能 Nginx
systemctl enable nginx
systemctl restart nginx

# 设置证书续期自动 reload nginx
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat << 'RENEW_CONF' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/sh
systemctl reload nginx
RENEW_CONF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# 7. 配置 iptables 规则并持久化
echo -e "${YELLOW}[6/6] 正在配置 iptables 回落重定向规则并持久化...${PLAIN}"

# 检查规则是否已经存在，不存在则添加
iptables -t nat -C OUTPUT -p tcp -d "${SERVER_IP}" --dport 443 -j REDIRECT --to-ports 8443 2>/dev/null || \
iptables -t nat -A OUTPUT -p tcp -d "${SERVER_IP}" --dport 443 -j REDIRECT --to-ports 8443

# 保存持久化规则
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
elif command -v service &>/dev/null && service iptables status &>/dev/null; then
    service iptables save
else
    iptables-save > /etc/iptables.rules
fi

echo -e "${GREEN}====================================================${PLAIN}"
echo -e "${GREEN}             部署完成！配置已生效                  ${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"
echo -e "1. 本机 404 站点已监听在: ${YELLOW}127.0.0.1:8443 (SSL)${PLAIN}"
echo -e "2. iptables 劫持规则: ${YELLOW}${SERVER_IP}:443 -> 127.0.0.1:8443${PLAIN}"
echo ""
echo -e "${BLUE}[Xboard 面板后台配置步骤]${PLAIN}"
echo -e "1. 进入节点设置，将该 REALITY 节点的【端口】设为: ${GREEN}443${PLAIN}"
echo -e "2. 将【伪装域名 / server_name】填入: ${GREEN}${DOMAIN}${PLAIN}"
echo -e "3. 保存节点配置，并重启 Xboard-Node 节点服务即可。"
echo -e "===================================================="
