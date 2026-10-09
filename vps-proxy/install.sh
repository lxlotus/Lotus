#!/usr/bin/env bash
# 一键部署：sing-box VLESS + Reality 代理 + 服务器安全加固
# 适用于 Debian 12 / Ubuntu 22.04+，需 root 运行。
#
#   bash install.sh           安装或修复（已有密钥会保留，客户端配置不变）
#   bash install.sh --show    重新显示客户端链接和二维码
#   bash install.sh --reset   重新生成全部密钥（旧的客户端配置会失效）
#
# 可选环境变量：
#   REALITY_SNI=www.example.com   指定 Reality 伪装站点（默认自动挑选）
#   ENABLE_HY2=1                  额外开启 Hysteria2（UDP，备用协议）
#   HY2_PORT=8443                 Hysteria2 端口
#   NODE_NAME=Vultr-LA            客户端里显示的节点名

set -euo pipefail

CONF_DIR=/etc/sing-box
STATE=$CONF_DIR/params.env
LINKS=/root/proxy-links.txt
VLESS_PORT=443
SNI_CANDIDATES=(www.microsoft.com www.apple.com www.amazon.com)

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y "$@"
}

show_links() {
  [[ -f $LINKS ]] || die "还没有部署过，找不到 $LINKS"
  cat "$LINKS"
  if command -v qrencode >/dev/null; then
    echo
    echo "主力节点二维码（客户端扫码导入）："
    grep -m1 '^vless://' "$LINKS" | qrencode -t ANSIUTF8
  fi
}

[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ ${1:-} == --show ]] && { show_links; exit 0; }
[[ ${1:-} == --reset ]] && rm -f "$STATE"
. /etc/os-release
[[ $ID == debian || $ID == ubuntu || ${ID_LIKE:-} == *debian* ]] || die "只支持 Debian / Ubuntu"

# ---------- 1. 基础软件与自动安全更新 ----------
log "更新系统并安装基础软件"
apt_get update
apt_get upgrade
apt_get install curl ca-certificates openssl ufw fail2ban unattended-upgrades qrencode

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ---------- 2. BBR ----------
log "开启 BBR"
cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null

# ---------- 3. 安装 sing-box（官方 apt 源） ----------
if ! command -v sing-box >/dev/null; then
  log "安装 sing-box"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt_get update
  apt_get install sing-box
fi
log "sing-box 版本：$(sing-box version | head -1)"

# ---------- 4. 密钥与参数（已存在则沿用） ----------
pick_sni() {
  local s
  for s in "${SNI_CANDIDATES[@]}"; do
    if echo | timeout 8 openssl s_client -connect "$s:443" -servername "$s" \
         -tls1_3 -alpn h2 2>/dev/null | grep -q 'ALPN protocol: h2'; then
      echo "$s"; return
    fi
  done
  echo "${SNI_CANDIDATES[0]}"
}

mkdir -p "$CONF_DIR"
if [[ -f $STATE ]]; then
  log "沿用已有密钥（客户端配置不变）"
  . "$STATE"
else
  log "生成新密钥"
  UUID=$(sing-box generate uuid)
  KEYPAIR=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey/{print $2}' <<<"$KEYPAIR")
  PUBLIC_KEY=$(awk '/PublicKey/{print $2}' <<<"$KEYPAIR")
  SHORT_ID=$(sing-box generate rand 8 --hex)
  SNI=${REALITY_SNI:-$(pick_sni)}
  HY2_PASSWORD=$(sing-box generate rand 16 --hex)
  umask 077
  cat > "$STATE" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
HY2_PASSWORD=$HY2_PASSWORD
EOF
  umask 022
fi
ENABLE_HY2=${ENABLE_HY2:-0}
HY2_PORT=${HY2_PORT:-8443}
log "Reality 伪装站点：$SNI"

# ---------- 5. 写配置并启动 ----------
HY2_INBOUND=""
if [[ $ENABLE_HY2 == 1 ]]; then
  if [[ ! -f $CONF_DIR/hy2.crt ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=www.bing.com" -keyout "$CONF_DIR/hy2.key" -out "$CONF_DIR/hy2.crt" 2>/dev/null
  fi
  HY2_INBOUND=$(cat <<EOF
,
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASSWORD" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CONF_DIR/hy2.crt",
        "key_path": "$CONF_DIR/hy2.key"
      }
    }
EOF
)
fi

log "写入 sing-box 配置"
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }$HY2_INBOUND
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

sing-box check -c "$CONF_DIR/config.json" || die "配置校验失败"

# 配置文件里有私钥：只让 root 和 sing-box 服务用户能读
SB_USER=$(systemctl show -p User --value sing-box 2>/dev/null || true)
chmod 600 "$CONF_DIR/config.json" "$STATE"
[[ -f $CONF_DIR/hy2.key ]] && chmod 600 "$CONF_DIR/hy2.key"
if [[ -n $SB_USER && $SB_USER != root ]]; then
  chgrp "$SB_USER" "$CONF_DIR/config.json" "$CONF_DIR"/hy2.* 2>/dev/null || true
  chmod 640 "$CONF_DIR/config.json"
  [[ -f $CONF_DIR/hy2.key ]] && chmod 640 "$CONF_DIR/hy2.key"
fi

systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 启动失败"; }
log "sing-box 已运行"

# ---------- 6. 防火墙 ----------
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}
log "配置防火墙（放行 SSH $SSH_PORT/tcp、代理 $VLESS_PORT/tcp）"
ufw allow "$SSH_PORT/tcp" >/dev/null
ufw allow "$VLESS_PORT/tcp" >/dev/null
[[ $ENABLE_HY2 == 1 ]] && ufw allow "$HY2_PORT/udp" >/dev/null
ufw --force enable >/dev/null

# ---------- 7. SSH 加固（必须已有密钥，避免把自己锁在外面） ----------
if [[ -s /root/.ssh/authorized_keys ]]; then
  log "关闭 SSH 密码登录，只允许密钥"
  # 00- 前缀：sshd 取第一个匹配值，保证优先于 50-cloud-init.conf
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    warn "SSH 配置校验失败，已撤销加固"
  fi
else
  warn "root 没有配置 SSH 密钥，暂不关闭密码登录。建议在 Vultr 添加 SSH Key 后重跑本脚本。"
fi

log "启用 fail2ban（防 SSH 暴力破解）"
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban 启动失败"

# ---------- 8. 生成客户端配置 ----------
SERVER_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
  || ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
NODE_NAME=${NODE_NAME:-Vultr-$(hostname -s)}

VLESS_LINK="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$NODE_NAME-Reality"

umask 077
{
  echo "# 服务器 $SERVER_IP 的客户端配置（$(date '+%F %T')）"
  echo "# 这些链接等同于密码，不要发给别人。"
  echo
  echo "## 主力：VLESS + Reality（复制整行导入 v2rayNG / NekoBox / Shadowrocket 等）"
  echo "$VLESS_LINK"
  if [[ $ENABLE_HY2 == 1 ]]; then
    PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$CONF_DIR/hy2.crt" | cut -d= -f2)
    echo
    echo "## 备用：Hysteria2（UDP；自签证书，已附证书指纹）"
    echo "hysteria2://$HY2_PASSWORD@$SERVER_IP:$HY2_PORT?sni=www.bing.com&insecure=1&pinSHA256=$PIN#$NODE_NAME-Hy2"
  fi
  echo
  echo "## Clash Meta / mihomo（FlClash、Clash Verge 等）proxies 条目"
  cat <<EOF
- name: $NODE_NAME-Reality
  type: vless
  server: $SERVER_IP
  port: $VLESS_PORT
  uuid: $UUID
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: $SNI
  reality-opts:
    public-key: $PUBLIC_KEY
    short-id: $SHORT_ID
  client-fingerprint: chrome
EOF
} > "$LINKS"
umask 022

echo
log "部署完成！"
echo
show_links
echo
echo "以后随时运行 'bash install.sh --show' 可再次查看。"
