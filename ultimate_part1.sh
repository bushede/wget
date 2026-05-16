#!/bin/bash
clear

echo "=============================================="
echo "   Ultimate 一键部署脚本（离线版 · Part 1）"
echo "   Cloudreve + Xray + Argo + Nginx（完整功能）"
echo "=============================================="

apt update -y
apt install -y wget curl unzip tar socat nginx

# -----------------------------
# 输入参数
# -----------------------------
read -p "Nginx 端口（默认 8080）: " NGINX_PORT
NGINX_PORT=${NGINX_PORT:-8080}

read -p "Cloudreve 端口（默认 5212）: " CLOUDREVE_PORT
CLOUDREVE_PORT=${CLOUDREVE_PORT:-5212}

read -p "VMess WS 端口（默认 10000）: " VMESS_PORT
VMESS_PORT=${VMESS_PORT:-10000}

read -p "VMess UUID（默认自动生成）: " VMESS_UUID
VMESS_UUID=${VMESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}

read -p "VMess WS 路径（默认 /ws）: " VMESS_PATH
VMESS_PATH=${VMESS_PATH:-/ws}

read -p "Argo 固定隧道 Token（可空）: " ARGO_TOKEN
read -p "Argo 固定域名（可空）: " ARGO_DOMAIN

# ============================================================
# Cloudreve 二进制（base64 内嵌）
# ============================================================

echo "正在写入 Cloudreve 二进制..."

mkdir -p /opt/cloudreve
cd /opt/cloudreve

cat > cloudreve.b64 << 'EOF_CLOUDREVE'
【此处将放 Cloudreve 的 base64 内容（非常大）】
EOF_CLOUDREVE

base64 -d cloudreve.b64 > cloudreve
chmod +x cloudreve
rm -f cloudreve.b64

# 创建 Cloudreve systemd 服务
cat >/etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve
After=network.target

[Service]
WorkingDirectory=/opt/cloudreve
ExecStart=/opt/cloudreve/cloudreve
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudreve
systemctl restart cloudreve

echo "等待 Cloudreve 启动..."
sleep 10

CLOUDREVE_LOG="/opt/cloudreve/cloudreve.log"
CLOUDREVE_ADMIN=$(grep -m1 "Username:" $CLOUDREVE_LOG | awk '{print $2}')
CLOUDREVE_PASS=$(grep -m1 "Password:" $CLOUDREVE_LOG | awk '{print $2}')
