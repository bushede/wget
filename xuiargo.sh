#!/bin/bash
clear

echo "=============================================="
echo "     Ultimate 一键脚本（Cloudreve + x-ui）"
echo "=============================================="

apt update -y
apt install -y curl wget unzip nginx

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

CLOUDREVE_LOG="/root/cloudreve.log"
CLOUDREVE_ADMIN=$(grep -m1 "admin" $CLOUDREVE_LOG | awk '{print $2}')
CLOUDREVE_PASS=$(grep -m1 "初始管理员密码" $CLOUDREVE_LOG | awk -F "：" '{print $2}')

# -----------------------------
# 2. 安装 x-ui
# -----------------------------
echo "安装 x-ui 面板..."

bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

# -----------------------------
# 3. 用户输入 x-ui 节点信息
# -----------------------------
read -p "请输入 x-ui 节点端口（例如 12345）: " XRAY_PORT
read -p "请输入 x-ui WS 路径（例如 /vmess）: " XRAY_PATH

# -----------------------------
# 4. 配置 Nginx 分流
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

    # x-ui 节点
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
# 5. 安装 Argo 临时隧道
# -----------------------------
echo "安装 Cloudflared..."

wget -O cloudflared.deb https://pkg.cloudflare.com/cloudflared_latest_amd64.deb
dpkg -i cloudflared.deb || apt --fix-broken install -y

cat >/etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url http://localhost:80 --no-autoupdate
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo
systemctl restart argo

echo "等待 Argo 域名..."
sleep 10

TEMP_URL=$(journalctl -u argo -n 80 --no-pager | grep -o "https://[a-zA-Z0-9.-]*trycloudflare.com" | tail -n1)
TEMP_DOMAIN=${TEMP_URL#https://}

# -----------------------------
# 6. 输出最终信息
# -----------------------------
clear
echo "=============================================="
echo "             部署完成！以下是信息"
echo "=============================================="

echo ""
echo "===== Cloudreve 网盘 ====="
echo "地址：http://$TEMP_DOMAIN/"
echo "账号：admin@cloudreve.org"
echo "密码：$CLOUDREVE_PASS"

echo ""
echo "===== x-ui 节点（请在面板查看 UUID） ====="
echo "节点路径：$XRAY_PATH"
echo "节点端口：443（Argo TLS）"
echo "域名：$TEMP_DOMAIN"

echo ""
echo "===== Argo 临时隧道 ====="
echo "域名：$TEMP_DOMAIN"

echo ""
echo "全部完成！"
