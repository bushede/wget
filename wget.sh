#!/bin/bash
clear

echo "=============================================="
echo "   Ultimate 一键部署（Cloudreve + Xray + Argo）"
echo "   无 x-ui · 自动生成 VMess/Clash/sing-box"
echo "=============================================="

apt update -y
apt install -y curl wget unzip nginx jq

# -----------------------------
# 1. 安装 Cloudreve（阿里云 OSS 镜像）
# -----------------------------
echo "安装 Cloudreve..."

cd /root
wget -O cloudreve.tar.gz https://clouder-labfileapp.oss-cn-hangzhou.aliyuncs.com/OSS/cloudreve_3.3.1_linux_amd64.tar.gz

tar -zxvf cloudreve.tar.gz
chmod +x cloudreve

# 创建 systemd 服务
cat >/etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve Drive Service
After=network.target

[Service]
WorkingDirectory=/root
ExecStart=/root/cloudreve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudreve
systemctl restart cloudreve

echo "等待 Cloudreve 启动..."
sleep 8

CLOUDREVE_PASS=$(grep -m1 "初始管理员密码" /root/cloudreve.log | awk -F "：" '{print $2}')

# -----------------------------
# 2. 安装 Xray（官方脚本）
# -----------------------------
echo "安装 Xray..."

bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# -----------------------------
# 3. 输入 VMess 信息
# -----------------------------
read -p "请输入 VMess 端口（默认 10000）: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-10000}

read -p "请输入 WS 路径（默认 /ws）: " XRAY_PATH
XRAY_PATH=${XRAY_PATH:-/ws}

read -p "请输入 UUID（默认自动生成）: " VMESS_UUID
VMESS_UUID=${VMESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}

# -----------------------------
# 4. 写入 Xray 配置（正确路径）
# -----------------------------
cat >/usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $XRAY_PORT,
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
          "path": "$XRAY_PATH"
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
# 5. 配置 Nginx 分流
# -----------------------------
echo "配置 Nginx..."

cat >/etc/nginx/sites-enabled/default <<EOF
server {
    listen 80;
    server_name _;

    # Cloudreve 网盘
    location / {
        proxy_pass http://127.0.0.1:5212;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # Xray VMess+WS
    location $XRAY_PATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }

        proxy_redirect off;
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t && systemctl restart nginx

# -----------------------------
# 6. 安装 cloudflared（修复版）
# -----------------------------
echo "安装 cloudflared..."

wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/bin/cloudflared
chmod +x /usr/bin/cloudflared

# -----------------------------
# 7. Argo 隧道（临时 + 固定）
# -----------------------------
read -p "是否使用 Argo 固定隧道？(y/n): " USE_FIXED

if [[ "$USE_FIXED" == "y" ]]; then
    read -p "请输入 Argo 固定隧道 Token: " ARGO_TOKEN
    read -p "请输入 Argo 固定域名: " ARGO_DOMAIN

    cat >/etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel (Fixed)
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --hostname $ARGO_DOMAIN --token $ARGO_TOKEN --no-autoupdate --logfile /root/argo.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    NODE_DOMAIN=$ARGO_DOMAIN
else
    cat >/etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel (Temporary)
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url http://localhost:80 --no-autoupdate --logfile /root/argo.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable argo
systemctl restart argo

echo "等待 Argo 域名生成..."
sleep 10

if [[ "$USE_FIXED" != "y" ]]; then
    NODE_DOMAIN=$(grep -o "https://[a-zA-Z0-9.-]*trycloudflare.com" /root/argo.log | tail -n1 | sed 's/https:\/\///')
fi

# -----------------------------
# 8. 自动生成节点信息
# -----------------------------

# VMess 链接
VMESS_JSON=$(printf '{"v":"2","ps":"Argo-VMess","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls"}' "$NODE_DOMAIN" "$VMESS_UUID" "$NODE_DOMAIN" "$XRAY_PATH" | base64 -w0)
VMESS_LINK="vmess://$VMESS_JSON"

# Clash 节点
CLASH_NODE="  - name: Argo-VMess
    type: vmess
    server: $NODE_DOMAIN
    port: 443
    uuid: $VMESS_UUID
    alterId: 0
    cipher: auto
    tls: true
    network: ws
    ws-opts:
      path: $XRAY_PATH
      headers:
        Host: $NODE_DOMAIN"

# sing-box 节点
SINGBOX_NODE=$(cat <<EOF
{
  "type": "vmess",
  "tag": "Argo-VMess",
  "server": "$NODE_DOMAIN",
  "server_port": 443,
  "uuid": "$VMESS_UUID",
  "alter_id": 0,
  "security": "auto",
  "transport": {
    "type": "ws",
    "path": "$XRAY_PATH",
    "headers": {
      "Host": "$NODE_DOMAIN"
    }
  },
  "tls": {
    "enabled": true
  }
}
EOF
)

# -----------------------------
# 9. 输出最终信息
# -----------------------------
clear
echo "=============================================="
echo "             部署完成！以下是信息"
echo "=============================================="

echo ""
echo "===== Cloudreve 网盘 ====="
echo "地址：http://$NODE_DOMAIN/"
echo "账号：admin@cloudreve.org"
echo "密码：$CLOUDREVE_PASS"

echo ""
echo "===== VMess 链接 ====="
echo "$VMESS_LINK"

echo ""
echo "===== Clash 节点 ====="
echo "$CLASH_NODE"

echo ""
echo "===== sing-box 节点 ====="
echo "$SINGBOX_NODE"

echo ""
echo "===== Argo 隧道 ====="
echo "域名：https://$NODE_DOMAIN"

echo ""
echo "全部完成！"
