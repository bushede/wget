# ultimate.
📘 Argo‑Stack Ultimate — 一键全家桶脚本
多节点 + 多用户 + Web 面板 + 订阅系统 + TLS/Argo + Cloudreve + 全协议支持  
一条命令即可部署完整机场级系统。

🚀 功能总览
功能	支持
多节点系统	✔ 自动生成 inbound / Nginx / Argo
多用户系统	✔ JSON 管理 / Token 订阅
Web 管理面板	✔ FastAPI 后端
订阅系统	✔ vmess / 可扩展 clash/sing-box
TLS 直连域名	✔ acme.sh 自动签发
Argo 固定隧道	✔ Token 模式
Argo 临时隧道	✔ Quick Tunnel
Cloudreve 网盘	✔ 自动安装 + systemd
Xray 全协议	✔ VMess / VLESS Reality / TUIC / Hysteria2（可扩展）
自动生成 systemd	✔ xray / cloudreve / cloudflared / panel
自动生成配置文件	✔ nodes.json / users.json / nginx / xray
一键安装	✔ 只需执行 ultimate.sh


📦 一键安装
将脚本上传到 GitHub 后，你可以直接执行：

bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/ultimate.sh)
或者本地执行：

bash
chmod +x ultimate.sh
./ultimate.sh
🧩 主菜单功能
运行脚本后，你会看到主菜单：

代码
1) 安装主系统（TLS / Argo / Cloudreve / Xray）
2) 添加新节点（多节点系统）
3) 查看所有节点
4) 删除节点
5) 管理用户（多用户系统）
6) 安装 Web 面板（订阅系统）
7) 生成 show-argo-info 命令
8) 退出
🌐 Web 管理面板
安装后，Web 面板运行在：

代码
http://你的服务器IP:18080/
你可以通过 Nginx 反代绑定域名，例如：

代码
panel.example.com
面板功能：

查看所有节点

查看所有用户

创建用户（自动生成订阅 token）

查看订阅链接

🔑 订阅系统
每个用户创建后会生成一个 token。

订阅链接格式：

代码
https://你的面板域名/sub/用户token
当前支持：

vmess 订阅

可扩展 Clash / Sing-box（脚本已预留接口）

🌲 多节点系统
每个节点会自动生成：

Xray inbound

Nginx 分流（TLS 模式）

Argo 隧道（Argo 模式）

节点 JSON 文件

自动加入订阅系统

支持协议：

VMess + WS

VLESS + Reality（Vision）

TUIC（预留）

Hysteria2（预留）

节点文件存放于：

代码
/etc/argo-stack/nodes/
👥 多用户系统
用户数据存放于：

代码
/etc/argo-stack/users.json
支持：

创建用户

禁用/启用用户

自动生成订阅 token

自动加入订阅系统

📁 Cloudreve 网盘
自动安装 + systemd：

默认端口：5212

初始账号密码自动写入：

代码
/var/lib/cloudreve/first_run.log
🔐 TLS / Argo 支持
1）TLS 直连域名
自动签发证书（acme.sh）

自动配置 Nginx

自动反代 Cloudreve + 节点

2）Argo 固定隧道
使用 Cloudflare Tunnel Token

自动生成 systemd

3）Argo 临时隧道
Quick Tunnel

自动生成临时域名

🛠 show-argo-info
脚本会生成一个命令：

代码
show-argo-info
用于查看：

所有节点

所有用户

Cloudreve 初始账号

Argo 状态

📂 项目结构
代码
ultimate.sh
README.md
脚本会自动生成：

代码
/etc/argo-stack/
    nodes/
    users.json
/opt/argo-panel/
    panel.py
/usr/local/etc/xray/config.json
/etc/nginx/conf.d/*.conf
/etc/systemd/system/*.service
🧱 扩展能力
脚本已预留扩展接口，可轻松加入：

Clash YAML 订阅

Sing-box JSON 订阅

TUIC 完整配置

Hysteria2 完整配置

Trojan-Go

NaiveProxy

ShadowTLS

Web 前端（Vue3）

❤️ 作者
本脚本由 xiaohu 专属定制版  
你可以自由修改、扩展、二次开发。

📜 License
MIT License（可自由使用与修改）

如果你需要：

生成 GitHub Release

生成 Docker 版本

生成前端管理界面（Vue3）

生成 Clash / Sing-box 全格式订阅
