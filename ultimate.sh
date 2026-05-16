#!/bin/bash
clear

echo "=============================================="
echo "   Ultimate 精简版（Xray + Argo + Nginx）"
echo "=============================================="

apt update -y
apt install -y curl wget unzip nginx

# -----------------------------
# 输入参数
# -----------------------------
read -p "Nginx 端口（默认 8080）: " NGINX_PORT
NGINX_PORT=${NGINX_PORT:-8080}

read -p "VMess WS 端口（默认 10000）: " VMESS_PORT
VMESS_PORT=${VMESS_PORT:-10000}

read -p "VMess UUID（默认自动生成）: " VMESS_UUID
VMESS_UUID=${VMESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}

read -p "VMess WS 路径（默认 /ws）: " VMESS_PATH
VMESS_PATH=${VMESS_PATH:-/ws}

read -p "Argo 固定隧道 Token（可空）: " ARGO_TOKEN
read -p "Argo 固定域名（可空）: " ARGO_DOMAIN

# -----------------------------
# 安装 Xray（官方脚本，不走 GitHub Release）
# -----------------------------
echo "安装 Xray..."

bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

mkdir -p /etc/xray

cat >/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $VMESS_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$VMESS_UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$VMESS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

systemctl restart xray

# -----------------------------
# Nginx 分流
# -----------------------------
echo "配置 Nginx..."

cat >/etc/nginx/sites-enabled/default <<EOF
server {
    listen $NGINX_PORT;

    location / {
        return 200 "Argo Xray Server OK";
    }

    location $VMESS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$VMESS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

nginx -t && systemctl restart nginx

# -----------------------------
# 安装 Argo（官方脚本）
# -----------------------------
echo "安装 Cloudflared..."

wget -O cloudflared.deb https://pkg.cloudflare.com/cloudflared_latest_amd64.deb
dpkg -i cloudflared.deb || apt --fix-broken install -y

# -----------------------------
# Argo 临时隧道
# -----------------------------
echo "创建 Argo 临时隧道..."

cat >/etc/systemd/system/argo-temp.service <<EOF
[Unit]
Description=Argo Temporary Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url http://localhost:$NGINX_PORT --no-autoupdate
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-temp
systemctl restart argo-temp

echo "等待 Argo 域名..."
sleep 10

TEMP_URL=$(journalctl -u argo-temp -n 80 --no-pager | grep -o "https://[a-zA-Z0-9.-]*trycloudflare.com" | tail -n1)
TEMP_DOMAIN=${TEMP_URL#https://}

# -----------------------------
# 固定隧道（可选）
# -----------------------------
if [[ -n "$ARGO_TOKEN" && -n "$ARGO_DOMAIN" ]]; then
cat >/etc/systemd/system/argo-fixed.service <<EOF
[Unit]
Description=Argo Fixed Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --hostname $ARGO_DOMAIN --token $ARGO_TOKEN --no-autoupdate
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-fixed
systemctl restart argo-fixed
fi

# -----------------------------
# 生成节点信息
# -----------------------------
NODE_DOMAIN="$TEMP_DOMAIN"
[[ -n "$ARGO_DOMAIN" ]] && NODE_DOMAIN="$ARGO_DOMAIN"

VMESS_JSON=$(printf '{"v":"2","ps":"Argo-VMess","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls"}' "$NODE_DOMAIN" "$VMESS_UUID" "$NODE_DOMAIN" "$VMESS_PATH" | base64 -w0)
VMESS_LINK="vmess://$VMESS_JSON"

# -----------------------------
# 输出结果
# -----------------------------
clear
echo "=============================================="
echo "           部署完成！以下是信息"
echo "=============================================="

echo ""
echo "===== Argo 临时隧道 ====="
echo "域名：$TEMP_DOMAIN"

if [[ -n "$ARGO_DOMAIN" ]]; then
echo ""
echo "===== Argo 固定隧道 ====="
echo "固定域名：$ARGO_DOMAIN"
fi

echo ""
echo "===== VMess 节点 ====="
echo "域名：$NODE_DOMAIN"
echo "UUID：$VMESS_UUID"
echo "路径：$VMESS_PATH"
echo "端口：443"
echo "协议：VMess+WS+TLS"
echo "链接："
echo "$VMESS_LINK"

