#!/usr/bin/env bash
set -e

# ============================================
#  Argo Stack Ultimate One-Click
#  多节点 + 多用户 + Web 面板 + 订阅 + TLS/Argo
# ============================================

green(){ echo -e "\e[32m$1\e[0m"; }
yellow(){ echo -e "\e[33m$1\e[0m"; }
red(){ echo -e "\e[31m$1\e[0m"; }

BASE="/etc/argo-stack"
NODES="$BASE/nodes"
USERS="$BASE/users.json"
PANEL="/opt/argo-panel"

mkdir -p "$BASE" "$NODES" "$PANEL"

install_pkg() {
  if ! command -v "$1" >/dev/null 2>&1; then
    apt update -y
    apt install -y "$1"
  fi
}

rand_port() { shuf -i 20000-60000 -n 1; }
rand_uuid() { uuidgen; }
rand_token() { openssl rand -base64 16 | tr -d "=" | tr "/+" "ab"; }

init_system() {
  green "安装基础依赖..."
  apt update -y
  apt install -y curl wget unzip nginx socat jq python3 python3-pip uuid-runtime
  systemctl stop ufw || true
  systemctl disable ufw || true
  systemctl stop firewalld || true
  systemctl disable firewalld || true
}

install_xray() {
  green "安装 Xray..."
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
  systemctl enable xray
  systemctl restart xray
}

install_cloudreve() {
  green "安装 Cloudreve..."
  mkdir -p /var/lib/cloudreve
  cd /tmp
  URL=$(curl -s https://api.github.com/repos/cloudreve/Cloudreve/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
  wget -O cloudreve.tar.gz "$URL"
  tar -zxvf cloudreve.tar.gz
  mv cloudreve /usr/local/bin/cloudreve
  chmod +x /usr/local/bin/cloudreve
  /usr/local/bin/cloudreve > /var/lib/cloudreve/first_run.log 2>&1 &
  sleep 8
  pkill -f cloudreve

  cat > /etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve
After=network.target

[Service]
WorkingDirectory=/var/lib/cloudreve
ExecStart=/usr/local/bin/cloudreve
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudreve
  systemctl restart cloudreve
}

install_cloudflared() {
  green "安装 cloudflared..."
  wget -O /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i /tmp/cloudflared.deb || apt -f install -y
}

install_tls() {
  green "=== TLS 直连域名模式 ==="
  read -rp "请输入节点子域名（如 node.example.com）: " TLS_NODE
  read -rp "请输入网盘子域名（如 pan.example.com）: " TLS_PAN

  mkdir -p /etc/nginx/ssl/$TLS_NODE /etc/nginx/ssl/$TLS_PAN

  green "安装 acme.sh..."
  curl https://get.acme.sh | sh
  export PATH="$HOME/.acme.sh:$PATH"

  green "签发证书（请确保 DNS 为灰云）..."
  ~/.acme.sh/acme.sh --issue --standalone -d "$TLS_NODE" --keylength ec-256
  ~/.acme.sh/acme.sh --issue --standalone -d "$TLS_PAN" --keylength ec-256

  ~/.acme.sh/acme.sh --install-cert -d "$TLS_NODE" --ecc \
    --key-file /etc/nginx/ssl/$TLS_NODE/key.pem \
    --fullchain-file /etc/nginx/ssl/$TLS_NODE/fullchain.pem

  ~/.acme.sh/acme.sh --install-cert -d "$TLS_PAN" --ecc \
    --key-file /etc/nginx/ssl/$TLS_PAN/key.pem \
    --fullchain-file /etc/nginx/ssl/$TLS_PAN/fullchain.pem

  cat > /etc/nginx/conf.d/argo_tls_main.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $TLS_PAN;

    ssl_certificate /etc/nginx/ssl/$TLS_PAN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$TLS_PAN/key.pem;

    location / {
        proxy_pass http://127.0.0.1:5212;
    }
}

server {
    listen 443 ssl http2;
    server_name $TLS_NODE;

    ssl_certificate /etc/nginx/ssl/$TLS_NODE/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$TLS_NODE/key.pem;

    location / {
        return 403;
    }
}
EOF

  nginx -t && systemctl restart nginx

  echo "$TLS_NODE" > $BASE/tls_node.txt
  echo "$TLS_PAN" > $BASE/tls_pan.txt

  green "TLS 主域名配置完成"
}

install_argo_fixed() {
  green "=== Argo 固定隧道模式 ==="
  read -rp "请输入 Argo Tunnel Token: " ARGO_TOKEN
  read -rp "请输入绑定的域名（如 node.example.com）: " ARGO_HOST

  cat > /etc/systemd/system/cloudflared-argo.service <<EOF
[Unit]
Description=Argo Fixed Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token $ARGO_TOKEN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-argo
  systemctl restart cloudflared-argo

  echo "$ARGO_HOST" > $BASE/argo_fixed_domain.txt
  echo "$ARGO_TOKEN" > $BASE/argo_fixed_token.txt

  green "Argo 固定隧道已启动"
}

install_argo_temp() {
  green "=== Argo 临时隧道模式 ==="

  cat > /etc/systemd/system/cloudflared-argo.service <<EOF
[Unit]
Description=Argo Quick Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url http://127.0.0.1:80 --logfile /var/log/cloudflared.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-argo
  systemctl restart cloudflared-argo

  green "Argo 临时隧道已启动"
}

install_main_system() {
  init_system
  install_xray
  install_cloudreve
  install_cloudflared

  green "请选择主模式："
  echo "  1) TLS 直连域名"
  echo "  2) Argo 固定隧道"
  echo "  3) Argo 临时隧道"
  read -rp "请输入数字 [1-3]: " MODE

  case "$MODE" in
    1) install_tls ;;
    2) install_argo_fixed ;;
    3) install_argo_temp ;;
  esac

  green "主系统安装完成"
}

# ========== 多节点：Xray inbound 生成 ==========

xray_add_inbound_vmess_ws() {
  local UUID="$1"
  local PORT="$2"
  local PATH="$3"
  local ID="$4"

  local CONF="/usr/local/etc/xray/config.json"
  jq ".inbounds += [{
    \"tag\": \"$ID\",
    \"port\": $PORT,
    \"listen\": \"127.0.0.1\",
    \"protocol\": \"vmess\",
    \"settings\": {\"clients\": [{\"id\": \"$UUID\"}]},
    \"streamSettings\": {\"network\": \"ws\", \"wsSettings\": {\"path\": \"$PATH\"}}
  }]" "$CONF" > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
}

# 预留：Reality / TUIC / Hysteria2 等 inbound，可按需扩展
# 这里先给 Reality 一个简单模板（VLESS+Reality）
xray_add_inbound_vless_reality() {
  local UUID="$1"
  local PORT="$2"
  local ID="$3"
  local DEST="$4"   # 目标域名:端口，如 www.microsoft.com:443
  local SNI="$5"
  local PBK="$6"
  local SID="$7"

  local CONF="/usr/local/etc/xray/config.json"
  jq ".inbounds += [{
    \"tag\": \"$ID\",
    \"port\": $PORT,
    \"listen\": \"0.0.0.0\",
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [{\"id\": \"$UUID\",\"flow\":\"xtls-rprx-vision\"}],
      \"decryption\": \"none\"
    },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"security\": \"reality\",
      \"realitySettings\": {
        \"show\": false,
        \"dest\": \"$DEST\",
        \"xver\": 0,
        \"serverNames\": [\"$SNI\"],
        \"privateKey\": \"$PBK\",
        \"shortIds\": [\"$SID\"]
      }
    }
  }]" "$CONF" > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
}

systemctl_reload_xray() {
  systemctl restart xray
}

# ========== 多节点：Nginx 分流 ==========

nginx_add_node() {
  local DOMAIN="$1"
  local PATH="$2"
  local PORT="$3"

  mkdir -p /etc/nginx/ssl/$DOMAIN

  cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    location $PATH {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  nginx -t && systemctl reload nginx
}

# ========== 多节点：Argo per-node（可选） ==========

argo_add_node() {
  local DOMAIN="$1"
  local TOKEN="$2"
  local MODE="$3"

  local SERVICE="/etc/systemd/system/argo_${DOMAIN}.service"

  if [ "$MODE" = "argo_fixed" ]; then
    cat > "$SERVICE" <<EOF
[Unit]
Description=Argo Tunnel for $DOMAIN
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token $TOKEN
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  elif [ "$MODE" = "argo_temp" ]; then
    cat > "$SERVICE" <<EOF
[Unit]
Description=Argo Quick Tunnel for $DOMAIN
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url https://$DOMAIN --logfile /var/log/cloudflared_${DOMAIN}.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  else
    return 0
  fi

  systemctl daemon-reload
  systemctl enable "argo_${DOMAIN}"
  systemctl restart "argo_${DOMAIN}"
}

# ========== 多节点：节点 JSON 管理 ==========

nodes_add() {
  mkdir -p "$NODES"
  local NODE_ID="node_$(date +%s)"

  green "创建新节点：$NODE_ID"
  echo "协议类型："
  echo "  1) VMess + WS"
  echo "  2) VLESS + Reality"
  echo "  3) 预留：TUIC"
  echo "  4) 预留：Hysteria2"
  read -rp "请选择协议 [1-4]: " P

  local PROTOCOL
  case "$P" in
    1) PROTOCOL="vmess" ;;
    2) PROTOCOL="reality" ;;
    3) PROTOCOL="tuic" ;;
    4) PROTOCOL="hysteria2" ;;
    *) PROTOCOL="vmess" ;;
  esac

  local UUID PATH PORT DOMAIN MODE_NAME ARGO_TOKEN

  UUID=$(rand_uuid)
  read -rp "WS/路径（默认 /$NODE_ID）: " PATH
  PATH=${PATH:-"/$NODE_ID"}
  PORT=$(rand_port)
  read -rp "节点域名（如 node1.example.com）: " DOMAIN

  echo "节点出站模式："
  echo "  1) TLS 主域名下分流（推荐）"
  echo "  2) 独立域名 + TLS（需自行签证书）"
  echo "  3) Argo 固定隧道"
  echo "  4) Argo 临时隧道"
  read -rp "请选择 [1-4]: " M

  case "$M" in
    1) MODE_NAME="tls_main" ;;
    2) MODE_NAME="tls_single" ;;
    3) MODE_NAME="argo_fixed" ;;
    4) MODE_NAME="argo_temp" ;;
    *) MODE_NAME="tls_main" ;;
  esac

  if [ "$MODE_NAME" = "argo_fixed" ]; then
    read -rp "请输入 Argo Tunnel Token: " ARGO_TOKEN
  fi

  local NODE_FILE="$NODES/${NODE_ID}.json"

  cat > "$NODE_FILE" <<EOF
{
  "id": "$NODE_ID",
  "protocol": "$PROTOCOL",
  "uuid": "$UUID",
  "path": "$PATH",
  "port": $PORT,
  "domain": "$DOMAIN",
  "mode": "$MODE_NAME",
  "argo_token": "${ARGO_TOKEN:-""}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

  green "节点配置已保存：$NODE_FILE"

  if [ "$PROTOCOL" = "vmess" ]; then
    xray_add_inbound_vmess_ws "$UUID" "$PORT" "$PATH" "$NODE_ID"
  elif [ "$PROTOCOL" = "reality" ]; then
    local DEST="www.microsoft.com:443"
    local SNI="www.microsoft.com"
    local PBK=$(xray x25519 | awk '/Private key/{print $3}')
    local SID="abcdef"
    xray_add_inbound_vless_reality "$UUID" "$PORT" "$NODE_ID" "$DEST" "$SNI" "$PBK" "$SID"
  fi

  systemctl_reload_xray

  if [ "$MODE_NAME" = "tls_single" ]; then
    nginx_add_node "$DOMAIN" "$PATH" "$PORT"
  fi

  if [ "$MODE_NAME" = "argo_fixed" ] || [ "$MODE_NAME" = "argo_temp" ]; then
    argo_add_node "$DOMAIN" "$ARGO_TOKEN" "$MODE_NAME"
  fi

  green "新节点创建完成！"
}

nodes_list() {
  green "===== 所有节点列表 ====="
  for f in "$NODES"/*.json; do
    [ -e "$f" ] || continue
    ID=$(jq -r '.id' "$f")
    DOMAIN=$(jq -r '.domain' "$f")
    PATH=$(jq -r '.path' "$f")
    PORT=$(jq -r '.port' "$f")
    MODE=$(jq -r '.mode' "$f")
    PROTO=$(jq -r '.protocol' "$f")
    echo "$ID | $PROTO | $DOMAIN | $PATH | $PORT | $MODE"
  done
}

nodes_remove() {
  read -rp "请输入要删除的节点 ID: " NODE_ID
  local NODE_FILE="$NODES/${NODE_ID}.json"
  [ -f "$NODE_FILE" ] || { red "节点不存在"; return; }

  local DOMAIN=$(jq -r '.domain' "$NODE_FILE")

  rm -f "/etc/nginx/conf.d/${DOMAIN}.conf"
  rm -f "/etc/systemd/system/argo_${DOMAIN}.service"
  rm -f "$NODE_FILE"

  systemctl daemon-reload
  nginx -t && systemctl reload nginx || true
  systemctl restart xray || true

  green "节点 $NODE_ID 已删除"
}

# ========== 多用户系统 + Web 面板 ==========

users_init() {
  [ -f "$USERS" ] || echo "[]" > "$USERS"
}

panel_install() {
  users_init
  green "安装 Web 面板依赖..."
  pip3 install fastapi uvicorn[standard] >/dev/null 2>&1 || pip3 install fastapi uvicorn >/dev/null 2>&1

  cat > "$PANEL/panel.py" <<'EOF'
#!/usr/bin/env python3
import json, os, time, base64
from fastapi import FastAPI, Request, HTTPException, Form
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
import uvicorn

BASE = Path("/etc/argo-stack")
NODES = BASE / "nodes"
USERS = BASE / "users.json"

app = FastAPI(title="Argo Stack Panel")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

def load_users():
    if not USERS.exists():
        return []
    return json.loads(USERS.read_text() or "[]")

def save_users(data):
    USERS.write_text(json.dumps(data, indent=2, ensure_ascii=False))

def load_nodes():
    if not NODES.exists():
        return []
    arr = []
    for f in NODES.glob("*.json"):
        try:
            arr.append(json.loads(f.read_text()))
        except:
            pass
    return arr

@app.get("/", response_class=HTMLResponse)
async def index():
    users = load_users()
    nodes = load_nodes()
    html = ["<html><head><meta charset='utf-8'><title>Argo Panel</title></head><body>"]
    html.append("<h1>Argo Stack Web Panel</h1>")

    html.append("<h2>用户列表</h2><ul>")
    for u in users:
        html.append(f"<li>{u['id']} | {u['name']} | token={u['token']} | enabled={u['enabled']}</li>")
    html.append("</ul>")

    html.append("""
    <h3>新增用户</h3>
    <form method="post" action="/admin/add_user">
      名称: <input name="name">
      <button type="submit">创建</button>
    </form>
    """)

    html.append("<h2>节点列表</h2><ul>")
    for n in nodes:
        html.append(f"<li>{n['id']} | {n['protocol']} | {n['domain']} | {n['path']} | {n['port']} | {n['mode']}</li>")
    html.append("</ul>")

    html.append("</body></html>")
    return "\n".join(html)

@app.post("/admin/add_user")
async def add_user(name: str = Form(...)):
    users = load_users()
    uid = f"u_{int(time.time())}"
    token = base64.urlsafe_b64encode(os.urandom(16)).decode().strip("=")
    users.append({
        "id": uid,
        "name": name,
        "token": token,
        "enabled": True,
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S")
    })
    save_users(users)
    return HTMLResponse(f"创建成功: {uid} token={token} <br><a href='/'>返回</a>")

def vmess(node, host):
  # vmess 订阅
    conf = {
        "v": "2",
        "ps": node["id"],
        "add": host or node["domain"],
        "port": "443",
        "id": node["uuid"],
        "aid": "0",
        "scy": "auto",
        "net": "ws",
        "type": "none",
        "host": host or node["domain"],
        "path": node["path"],
        "tls": "tls",
        "sni": host or node["domain"],
        "alpn": "http/1.1"
    }
    raw = json.dumps(conf, separators=(",", ":"))
    return "vmess://" + base64.b64encode(raw.encode()).decode()

@app.get("/sub/{token}", response_class=PlainTextResponse)
async def sub(token: str, request: Request):
    users = load_users()
    user = next((u for u in users if u["token"] == token and u["enabled"]), None)
    if not user:
        raise HTTPException(404, "invalid token")

    nodes = load_nodes()
    host = request.headers.get("host", "")

    links = []
    for n in nodes:
        if n["protocol"] == "vmess":
            links.append(vmess(n, host))

    return "\n".join(links)

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=18080)
EOF

  cat > /etc/systemd/system/argo-panel.service <<EOF
[Unit]
Description=Argo Stack Web Panel
After=network.target

[Service]
WorkingDirectory=$PANEL
ExecStart=/usr/bin/python3 $PANEL/panel.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable argo-panel
  systemctl restart argo-panel

  green "Web 面板已安装并启动（监听 127.0.0.1:18080）"
  green "你可以用 Nginx 反代一个域名到 127.0.0.1:18080"
}

users_menu() {
  users_init
  echo "1) 查看用户"
  echo "2) 新增用户"
  echo "3) 禁用/启用用户"
  read -rp "选择 [1-3]: " U

  if [ "$U" = "1" ]; then
    jq -r '.[] | "\(.id) | \(.name) | token=\(.token) | enabled=\(.enabled)"' "$USERS"
  elif [ "$U" = "2" ]; then
    read -rp "用户名称: " NAME
    local UID="u_$(date +%s)"
    local TOKEN=$(rand_token)
    local TMP=$(mktemp)
    jq ". + [{\"id\":\"$UID\",\"name\":\"$NAME\",\"token\":\"$TOKEN\",\"enabled\":true,\"created_at\":\"$(date '+%Y-%m-%d %H:%M:%S')\"}]" "$USERS" > "$TMP"
    mv "$TMP" "$USERS"
    green "创建成功: $UID token=$TOKEN"
  elif [ "$U" = "3" ]; then
    read -rp "用户 ID: " UID
    local TMP=$(mktemp)
    jq "map(if .id==\"$UID\" then .enabled = (if .enabled then false else true end) else . end)" "$USERS" > "$TMP"
    mv "$TMP" "$USERS"
    green "已切换用户状态"
  fi
}

show_info_script() {
  cat > /usr/local/bin/show-argo-info <<'EOF'
#!/usr/bin/env bash
green(){ echo -e "\e[32m$1\e[0m"; }

BASE="/etc/argo-stack"
NODES="$BASE/nodes"
USERS="$BASE/users.json"

green "===== Cloudreve 初始信息 ====="
cat /var/lib/cloudreve/first_run.log 2>/dev/null || echo "无"

green "===== 所有节点 ====="
for f in "$NODES"/*.json; do
  [ -e "$f" ] || continue
  ID=$(jq -r '.id' "$f")
  DOMAIN=$(jq -r '.domain' "$f")
  PATH=$(jq -r '.path' "$f")
  PORT=$(jq -r '.port' "$f")
  MODE=$(jq -r '.mode' "$f")
  PROTO=$(jq -r '.protocol' "$f")
  echo "$ID | $PROTO | $DOMAIN | $PATH | $PORT | $MODE"
done

green "===== 所有用户 ====="
if [ -f "$USERS" ]; then
  jq -r '.[] | "\(.id) | \(.name) | token=\(.token) | enabled=\(.enabled)"' "$USERS"
else
  echo "无用户"
fi
EOF
  chmod +x /usr/local/bin/show-argo-info
  green "已生成 show-argo-info 命令"
}

main_menu() {
  clear
  green "=============================================="
  green "        Argo Stack Ultimate One-Click"
  green "=============================================="
  echo
  green "请选择操作："
  echo "  1) 安装主系统（TLS / Argo / Cloudreve / Xray）"
  echo "  2) 添加新节点（多节点系统）"
  echo "  3) 查看所有节点"
  echo "  4) 删除节点"
  echo "  5) 管理用户（多用户系统）"
  echo "  6) 安装 Web 面板（订阅系统）"
  echo "  7) 生成 show-argo-info 命令"
  echo "  8) 退出"
  echo
  read -rp "请输入数字 [1-8]: " ACTION
}

# ========== 主流程 ==========

while true; do
  main_menu
  case "$ACTION" in
    1) install_main_system ;;
    2) nodes_add ;;
    3) nodes_list ;;
    4) nodes_remove ;;
    5) users_menu ;;
    6) panel_install ;;
    7) show_info_script ;;
    8) exit 0 ;;
    *) red "无效选择" ;;
  esac
  read -rp "按回车返回菜单..." _
done
