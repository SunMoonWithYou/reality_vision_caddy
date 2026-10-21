#!/usr/bin/env bash
# ============================================================================
# Xray Reality + Vision 一键管理脚本
# 支持两种安装模式：域名模式 / IP模式
# ----------------------------------------------------------------------------
# 功能说明：
#   1) 安装
#      - 域名模式：Xray(Reality+Vision) + Caddy(本地伪装站 + 自动申请证书)
#                 默认监听端口 443；证书验证支持 HTTP-01 或 DNS-01(Cloudflare)
#                 HTTP-01：占用 80 端口做 ACME 挑战 + 跳转
#                 DNS-01 ：不监听 80，不动 80 上的任何服务；证书走 Cloudflare API
#      - IP模式  ：仅安装 Xray(Reality+Vision)，不需要域名、不安装 Caddy
#                 默认监听端口 8443，需选择一个真实网站作为伪装目标
#   2) 卸载      ：停止并移除服务、配置，可选清理安装信息
#   3) 查看状态  ：展示服务运行状态、端口监听、版本信息
#   4) 客户端参数：输出指定用户的 VLESS 分享链接和详细参数
#   5) 用户管理  ：列出 / 添加 / 删除用户，并实时重建 Xray 配置
#   6) 诊断自检  ：连不上时使用，只读不改配置
#
# 端口说明：
#   - 域名模式(HTTP-01)：放行 80(申请证书) + Xray 端口
#   - 域名模式(DNS-01) ：仅放行 Xray 端口；80 端口完全留给其他服务
#   - IP模式           ：放行 Xray 监听端口(默认 8443)
#
# 适用系统：Debian 11/12/13、Ubuntu 20.04/22.04/24.04
# 必须以 root 用户运行
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# 终端颜色定义
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# 步骤标题：上下横线 + ▶ 标题
step() {
  echo
  echo -e "${BLUE}  ─────────────────────────────────────────────────${NC}"
  echo -e "${BLUE}  ▶ $*${NC}"
  echo -e "${BLUE}  ─────────────────────────────────────────────────${NC}"
}

# 菜单标题框（中文行不带右边框，避免中英文宽度不一致导致错位）
banner() {
  echo -e "${CYAN}"
  echo -e "  ╔═════════════════════════════════════════════════╗"
  printf  "      %s\n" "$*"
  echo -e "  ╚═════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# 菜单项：mi <编号> <名称> <说明>   （名称统一四字格式）
mi() {
  echo -e "  ${GREEN}[$1]${NC} $2   ${DIM}说明: $3${NC}"
}

# ----------------------------------------------------------------------------
# 权限检查
# ----------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行，或先执行: sudo -i"

# ----------------------------------------------------------------------------
# 发行版检测
# ----------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu)
      info "系统: ${PRETTY_NAME:-$ID}"
      ;;
    *)
      error "本脚本仅支持 Debian / Ubuntu，当前系统: ${PRETTY_NAME:-未知}"
      ;;
  esac
else
  error "无法识别系统（缺少 /etc/os-release）"
fi

# ----------------------------------------------------------------------------
# 全局变量
# ----------------------------------------------------------------------------
USERS_FILE=/etc/reality-caddy/users.txt
INFO_FILE=/etc/reality-caddy/info.txt
XRAY_CONF=/usr/local/etc/xray/config.json
LOG_RETENTION_DAYS=7
CADDY_BIN=""
ACME_CHALLENGE=""

BUILTIN_DESTS=(
  "www.amazon.com"
  "www.ebay.com"
  "www.paypal.com"
  "aws.amazon.com"
  "www.apple.com"
  "dl.google.com"
  "www.bing.com"
  "www.yahoo.com"
)

# ============================================================================
# 主菜单
# ============================================================================
show_menu() {
  clear
  banner "Xray Reality + Vision 一键管理脚本"
  echo -e "  ${GREEN}[1]${NC} 安装服务      ${GREEN}[2]${NC} 卸载服务"
  echo -e "  ${GREEN}[3]${NC} 查看状态      ${GREEN}[4]${NC} 查看参数"
  echo -e "  ${GREEN}[5]${NC} 管理用户      ${GREEN}[6]${NC} 诊断自检"
  echo -e "  ${GREEN}[0]${NC} 退出脚本"
  echo
  echo -e "  ${YELLOW}提示: 连接不上时，先执行 [6] 诊断自检${NC}"
  echo
  read -rp "  请选择 [0-6]: " CHOICE
}

# ============================================================================
# 判断是否已安装
# ============================================================================
is_installed() {
  [[ -f "$INFO_FILE" ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy-json.service"
}

# ============================================================================
# 安全读取 key=value 配置
# ============================================================================
load_kv() {
  local FILE=$1
  [[ ! -f "$FILE" ]] && return 1
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | xargs)
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    printf -v "$key" '%s' "$value"
  done < "$FILE"
  return 0
}

# ============================================================================
# 生成 clients JSON 数组
# ============================================================================
build_clients_json() {
  [[ ! -f "$USERS_FILE" ]] && { echo '[]'; return; }
  local first=1
  echo "["
  while IFS='|' read -r uuid email note; do
    [[ -z "$uuid" || "$uuid" =~ ^# ]] && continue
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '          {\n'
    printf '            "id": "%s",\n' "$uuid"
    printf '            "email": "%s",\n' "${email:-user@local}"
    printf '            "flow": "xtls-rprx-vision"\n'
    printf '          }'
  done < "$USERS_FILE"
  echo
  echo "        ]"
}

# ============================================================================
# 重建 Xray 主配置
# ============================================================================
rebuild_xray_config() {
  load_kv "$INFO_FILE" || error "未找到 $INFO_FILE，请先安装"
  mkdir -p "$(dirname "$XRAY_CONF")"

  local CLIENTS_JSON
  CLIENTS_JSON=$(build_clients_json)

  local REALITY_DEST REALITY_SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    local NORM
    NORM=$(normalize_dest "${DEST_DOMAIN:-}" 2>/dev/null) || {
      warn "伪装目标域名不合法: [${DEST_DOMAIN:-空}]"
      warn "要求：纯域名，不带 https:// 前缀、不带路径、不能是纯 IP"
      return 1
    }
    DEST_DOMAIN="$NORM"

    if ! probe_dest_tls "$DEST_DOMAIN" 443; then
      warn "伪装目标 ${DEST_DOMAIN} 的 TLS 握手探测失败"
      warn "该目标无法作为 REALITY 的 dest，生成的节点会『连上即断』"
      warn "请重新安装并换一个目标，或手动执行以下命令确认："
      warn "  openssl s_client -connect ${DEST_DOMAIN}:443 -servername ${DEST_DOMAIN} -tls1_3 -brief"
      return 1
    fi

    REALITY_DEST="${DEST_DOMAIN}:443"
    REALITY_SNI="${DEST_DOMAIN}"
  else
    REALITY_DEST="127.0.0.1:8003"
    REALITY_SNI="${DOMAIN}"
  fi

  cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "",
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

  if ! xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "Xray 配置校验失败，输出："
    xray -test -config "$XRAY_CONF" || true
    return 1
  fi
  return 0
}

# ============================================================================
# 放行防火墙端口
# ============================================================================
open_firewall_port() {
  local ports=("$@")
  local opened=0

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld: 已放行 TCP ${ports[*]}"
    opened=1
  fi

  if command -v ufw >/dev/null 2>&1; then
    local st
    st=$(ufw status 2>/dev/null | head -n1 || true)
    if [[ "$st" == *"active"* ]]; then
      for p in "${ports[@]}"; do
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
      done
      info "ufw: 已放行 TCP ${ports[*]}"
      opened=1
    fi
  fi

  if [[ $opened -eq 0 ]] && command -v iptables >/dev/null 2>&1; then
    local changed=0
    for p in "${ports[@]}"; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && continue
      iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && changed=1 || true
    done
    if [[ $changed -eq 1 ]]; then
      command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
      info "iptables: 已放行 TCP ${ports[*]}（重启后可能失效，建议改用 ufw/firewalld）"
      opened=1
    fi
  fi

  if [[ $opened -eq 0 ]]; then
    info "未检测到启用中的本机防火墙（firewalld/ufw/iptables 规则为空）"
  fi
}

# ============================================================================
# 端口放行提示
# ============================================================================
print_port_notice() {
  local mode=$1
  local port=$2

  echo
  echo -e "${YELLOW}───────────────────────── 端口放行提醒 ─────────────────────────${NC}"
  if [[ "$mode" == "ip" ]]; then
    echo -e "  必须放行：${CYAN}TCP ${port}${NC}（Xray 监听端口）"
  else
    if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
      echo -e "  必须放行：${CYAN}TCP 80${NC}（ACME HTTP-01 申请/续期证书）"
    else
      echo -e "  无需放行：TCP 80（当前使用 DNS-01 验证，Caddy 不监听 80）"
    fi
    echo -e "            ${CYAN}TCP ${port}${NC}（Xray 监听端口，默认 443）"
  fi
  echo -e "  操作位置：云厂商控制台 → 安全组 / 防火墙 入站规则"
  echo -e "            以及服务器本机防火墙（ufw / firewalld）"
  echo -e "  提示    ：端口未放行时，客户端会连接超时或 TLS 握手失败"
  echo -e "${YELLOW}───────────────────────────────────────────────────────────────${NC}"
}

# ============================================================================
# 处理常见 Web 服务占用
#   - HTTP-01 模式：需要 80 端口，会停止 nginx/apache 等
#   - DNS-01 模式：完全不动 80 端口上的服务，只检查 Xray 端口是否空闲
# ============================================================================
handle_common_occupiers() {
  step "检测并处理常见端口占用"

  if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
    # ========== HTTP-01：需要 80 端口 ==========
    systemctl is-active --quiet nginx 2>/dev/null && {
      warn "停止 Nginx"
      systemctl stop nginx
      systemctl disable nginx
    }

    systemctl is-active --quiet apache2 2>/dev/null && {
      warn "停止 Apache2"
      systemctl stop apache2
      systemctl disable apache2
    }

    systemctl stop apache2.socket 2>/dev/null || true
    systemctl disable apache2.socket 2>/dev/null || true

    systemctl stop caddy.service 2>/dev/null || true
    systemctl disable caddy.service 2>/dev/null || true

    if ss -tlnp 2>/dev/null | grep -qE ':(80|443)\b'; then
      warn "80/443 仍被占用："
      ss -tlnp | grep -E ':(80|443)' || true
    else
      info "80/443 端口空闲"
    fi
  else
    # ========== DNS-01：不监听 80，不动 80 上的任何服务 ==========
    info "DNS-01 模式：Caddy 不监听 80，80 端口上的服务（nginx/apache 等）保持原样"
    info "仅检查 Xray 端口 ${XRAY_PORT} 是否可用"
    if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
      warn "端口 ${XRAY_PORT} 已被占用（Xray 需要该端口）："
      ss -tlnp | grep -E ":${XRAY_PORT}\b" || true
      read -rp "是否继续？[y/N]: " C
      [[ "${C,,}" != "y" ]] && { info "已取消"; read -rp "  按回车返回..." _; exit 0; }
    else
      info "端口 ${XRAY_PORT} 空闲"
    fi
  fi
}

# ============================================================================
# 日志保留策略
# ============================================================================
configure_log_retention() {
  step "配置日志保留策略（${LOG_RETENTION_DAYS} 天）"

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-retention.conf <<EOF
[Journal]
Storage=persistent
MaxRetentionSec=${LOG_RETENTION_DAYS}day
SystemMaxUse=500M
RuntimeMaxUse=100M
SystemMaxFileSize=50M
RuntimeMaxFileSize=20M
SystemMaxFiles=20
RuntimeMaxFiles=10
MaxFileSec=1day
EOF

  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
  systemctl restart systemd-journald

  journalctl --vacuum-time=${LOG_RETENTION_DAYS}d >/dev/null 2>&1 || true

  mkdir -p /var/log/xray
  cat > /etc/tmpfiles.d/xray-log.conf <<EOF
d /var/log/xray 0755 root root -
e /var/log/xray - - - ${LOG_RETENTION_DAYS}d
EOF
  systemd-tmpfiles --create 2>/dev/null || true
  systemctl enable systemd-tmpfiles-clean.timer 2>/dev/null || true
  systemctl start  systemd-tmpfiles-clean.timer 2>/dev/null || true

  info "日志保留策略已生效"
}

# ============================================================================
# 规范化伪装目标域名
# ============================================================================
normalize_dest() {
  local raw=$1
  raw=$(echo "$raw" | tr -d ' \t\r\n')
  raw=${raw#http://}
  raw=${raw#https://}
  raw=${raw%%/*}
  raw=${raw%%:*}
  raw=${raw%.}

  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  if [[ ! "$raw" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    return 1
  fi
  echo "$raw"
  return 0
}

# ============================================================================
# 真实 TLS 握手探测
# ============================================================================
probe_dest_tls() {
  local host=$1
  local port=${2:-443}
  local out

  command -v openssl >/dev/null 2>&1 || return 0

  out=$(timeout 10 openssl s_client \
          -connect "${host}:${port}" \
          -servername "$host" \
          -tls1_3 -alpn h2,http/1.1 \
          -brief </dev/null 2>&1 || true)

  if echo "$out" | grep -qiE 'Protocol version: *TLSv1\.3|Protocol  *: *TLSv1\.3'; then
    if echo "$out" | grep -qiE 'Verification: *OK|Verify return code: *0'; then
      return 0
    fi
    return 0
  fi

  if echo "$out" | grep -qiE 'alert|handshake failure|no protocols|timeout|Connection refused|connect:errno'; then
    return 1
  fi
  [[ -z "$out" ]] && return 1
  return 1
}

# ============================================================================
# 批量实测候选目标
# ============================================================================
probe_dest_list() {
  local d
  for d in "$@"; do
    if probe_dest_tls "$d" 443; then
      printf '%s|OK\n' "$d"
    else
      printf '%s|FAIL\n' "$d"
    fi
  done
}

# ============================================================================
# IP 模式：选择伪装目标
# ============================================================================
choose_dest_domain() {
  echo
  step "实测候选伪装目标（TLS1.3 握手探测）"
  echo "说明：只有握手正常的目标才能作为 dest，否则客户端会连上即断。"
  echo

  local -a GOOD=()
  local d
  for d in "${BUILTIN_DESTS[@]}"; do
    if probe_dest_tls "$d" 443; then
      GOOD+=("$d")
      echo -e "  ${GREEN}[通过]${NC} $d"
    else
      echo -e "  ${RED}[失败]${NC} $d  （TLS 握手异常，已从候选剔除）"
    fi
  done

  echo
  if [[ ${#GOOD[@]} -eq 0 ]]; then
    warn "内置候选全部握手失败，请手动输入一个可用的伪装域名"
    warn "建议在客户端所在地测试：能正常用浏览器访问、支持 TLS1.3 的站点"
    while true; do
      read -rp "  请输入自定义伪装域名: " DEST_DOMAIN
      if DEST_DOMAIN=$(normalize_dest "${DEST_DOMAIN:-}"); then
        if probe_dest_tls "$DEST_DOMAIN" 443; then
          info "握手通过: $DEST_DOMAIN"
          return 0
        fi
        warn "$DEST_DOMAIN 握手仍失败，请换一个"
      else
        warn "域名格式不合法（不要带 https:// 或路径）"
      fi
    done
  fi

  echo -e "  ${BLUE}▶ 请选择伪装目标域名${NC} ${DIM}(仅显示实测通过的)${NC}"
  local i=1
  for d in "${GOOD[@]}"; do
    printf "  ${GREEN}[%d]${NC} %s\n" "$i" "$d"
    ((i++))
  done
  printf "  ${GREEN}[%d]${NC} 自定义输入\n" "$i"
  echo
  read -rp "  请选择 [1-${i}] (默认 1): " SEL
  SEL=${SEL:-1}

  if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#GOOD[@]} )); then
    DEST_DOMAIN="${GOOD[$((SEL-1))]}"
  elif [[ "$SEL" == "$i" ]]; then
    while true; do
      read -rp "  请输入自定义伪装域名 (例如 www.example.com): " INPUT_DEST
      if DEST_DOMAIN=$(normalize_dest "${INPUT_DEST:-}"); then
        if probe_dest_tls "$DEST_DOMAIN" 443; then
          info "握手通过: $DEST_DOMAIN"
          break
        fi
        warn "$DEST_DOMAIN 握手失败，作为 dest 会导致客户端连上即断"
        read -rp "仍要使用它？[y/N]: " KEEP
        [[ "${KEEP,,}" == "y" ]] && break
      else
        warn "域名格式不合法，请重新输入（不要带 https:// 或路径）"
      fi
    done
  else
    DEST_DOMAIN="${GOOD[0]}"
  fi

  info "已选择伪装域名: $DEST_DOMAIN"
}

# ============================================================================
# 出网自检
# ============================================================================
check_outbound() {
  local okn=0 total=0 url code
  for url in "https://www.cloudflare.com/cdn-cgi/trace" \
             "https://www.apple.com/library/test/success.html" \
             "https://www.google.com/generate_204"; do
    total=$((total + 1))
    code=$(timeout 8 curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|204|301|302)$ ]]; then
      okn=$((okn + 1))
      echo -e "  ${GREEN}[通]${NC} $url (HTTP $code)"
    else
      echo -e "  ${RED}[不通]${NC} $url (HTTP $code / 超时)"
    fi
  done
  [[ $okn -gt $((total / 2)) ]] && return 0 || return 1
}

# ============================================================================
# 检查 Caddy 是否已为域名成功签发证书
#   依据1: Caddy 默认存储中的证书文件 (root: /root/.local/share/caddy)
#   依据2: caddy-json 日志中出现 "certificate obtained successfully"
# ============================================================================
check_cert_obtained() {
  local dom=$1
  [[ -z "$dom" ]] && return 1

  local storages=( "/root/.local/share/caddy" "${HOME:-/root}/.local/share/caddy" )
  local s
  for s in "${storages[@]}"; do
    [[ -d "$s/certificates" ]] || continue
    if find "$s/certificates" -type f -name "${dom}.crt" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done

  journalctl -u caddy-json.service --no-pager -n 300 2>/dev/null \
    | grep -q "certificate obtained successfully" && return 0
  return 1
}

# ============================================================================
# 获取公网 IP
# ============================================================================
get_public_ip() {
  local ip=""
  for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://one.one.one.one/cdn-cgi/trace"; do
    if [[ "$url" == *"trace"* ]]; then
      ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | grep -oP 'ip=\K[^ ]+' || true)
    else
      ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
    fi
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  echo ""
}

# ============================================================================
# 生成 Reality 密钥
# ============================================================================
generate_reality_keys() {
  local out
  out=$(xray x25519 2>/dev/null)

  local tmp
  tmp=($(echo "$out" | sed 's/.*://'))
  PRIVATE_KEY=${tmp[0]:-}
  PUBLIC_KEY=${tmp[1]:-}

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(echo "$out" | grep -iE 'Private|私钥' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$out" | grep -iE 'Public|Password|公钥|密码' | awk '{print $NF}' | head -1)
  fi

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(echo "$out" | sed -n '1p' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$out" | sed -n '2p' | awk '{print $NF}')
  fi

  [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "生成 Reality 密钥失败，请检查 xray 版本"

  SHORT_ID=$(openssl rand -hex 8)
}

# ============================================================================
# 一、安装
# ============================================================================
do_install() {
  local KEEP_USERS=0

  if is_installed; then
    clear
    warn "检测到本机已安装过本方案："
    echo
    if [[ -f "$INFO_FILE" ]]; then
      load_kv "$INFO_FILE"
      echo "  模式      : ${MODE:-domain}"
      if [[ "${MODE:-domain}" == "ip" ]]; then
        echo "  服务器IP  : ${SERVER_IP:-未知}"
        echo "  伪装域名  : ${DEST_DOMAIN:-未知}"
      else
        echo "  域名      : ${DOMAIN:-未知}"
        echo "  验证方式  : ${ACME_CHALLENGE:-http}"
      fi
      echo "  端口      : ${XRAY_PORT:-未知}"
      echo "  安装时间  : ${INSTALL_TIME:-未知}"
      echo "  用户数量  : $(grep -vcE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null || echo 0)"
      echo
    fi
    mi 1 "覆盖重装" "保留 users.txt 用户列表"
    mi 2 "完全重装" "清空用户与全部配置"
    mi 0 "取消操作" "返回主菜单"
    echo
    read -rp "  请选择 [0-2]: " REINSTALL
    case "$REINSTALL" in
      1)
        KEEP_USERS=1
        info "将保留用户列表"
        ;;
      2)
        read -rp "确认清空？输入 yes 继续: " C
        [[ "$C" != "yes" ]] && { info "已取消"; read -rp "  按回车返回..." _; return; }
        KEEP_USERS=0
        ;;
      *)
        info "已取消"
        read -rp "  按回车返回..." _
        return
        ;;
    esac
  fi

  # ---------- 选择安装模式 ----------
  step "选择安装模式"
  mi 1 "域名模式" "需自有域名 + Caddy 伪装站 + 自动证书，默认端口 443"
  mi 2 "IP 模式 " "免域名免 Caddy，直接用公网 IP，默认端口 8443"
  echo
  read -rp "  请选择 [1-2] (默认 1): " MODE_SEL
  MODE_SEL=${MODE_SEL:-1}
  case "$MODE_SEL" in
    1) MODE="domain" ;;
    *) MODE="ip" ;;
  esac
  info "已选择: $([ "$MODE" = "ip" ] && echo "IP模式" || echo "域名模式")"

  # ---------- 参数配置 ----------
  step "参数配置"
  if [[ "$MODE" == "ip" ]]; then
    local DETECTED_IP
    DETECTED_IP=$(get_public_ip)
    if [[ -n "$DETECTED_IP" ]]; then
      read -rp "  检测到公网 IP: ${DETECTED_IP}，直接回车使用，或输入其他 IP: " SERVER_IP
      SERVER_IP=${SERVER_IP:-$DETECTED_IP}
    else
      read -rp "  请输入服务器公网 IP: " SERVER_IP
    fi
    [[ -z "$SERVER_IP" ]] && error "服务器 IP 不能为空"

    read -rp "  请输入 Xray 监听端口 (默认 8443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-8443}

    choose_dest_domain
    EMAIL=""
    SITE_TITLE=""
    DOMAIN=""
    ACME_CHALLENGE=""
    CF_API_TOKEN=""
  else
    read -rp "  请输入你的域名 (例如: example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空"
    read -rp "  请输入用于 ACME 的邮箱: " EMAIL
    [[ -z "$EMAIL" ]] && error "邮箱不能为空"
    read -rp "  请输入伪装站标题 (默认: Welcome): " SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-Welcome}
    read -rp "  请输入 Xray 监听端口 (默认 443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}
    SERVER_IP=""
    DEST_DOMAIN=""

    # ---- 选择证书验证方式 ----
    echo
    echo -e "  ${BLUE}▶ 证书验证方式${NC}"
    mi 1 "HTTP 验证" "HTTP-01，需占用 80 端口，配置最简单"
    mi 2 "DNS 验证 " "DNS-01，不占用 80 端口，走 Cloudflare API"
    echo
    read -rp "  请选择 [1-2] (默认 1): " ACME_CHALLENGE_SEL
    ACME_CHALLENGE_SEL=${ACME_CHALLENGE_SEL:-1}
    if [[ "$ACME_CHALLENGE_SEL" == "2" ]]; then
      ACME_CHALLENGE="dns"
    else
      ACME_CHALLENGE="http"
    fi

    CF_API_TOKEN=""
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      echo
      warn "DNS-01 需要 Cloudflare API Token"
      warn "权限要求：Zone.Zone:Read + Zone.DNS:Edit，作用域限定到 ${DOMAIN}"
      warn "请先在 Cloudflare 后台创建，然后粘贴到下面（输入不回显）"
      read -rsp "  CF_API_TOKEN: " CF_API_TOKEN
      echo
      [[ -z "$CF_API_TOKEN" ]] && error "API Token 不能为空"
      [[ "$CF_API_TOKEN" =~ [[:space:]] ]] && error "API Token 含空白字符，请检查"
      # 与 caddy-dns/cloudflare 插件同款格式预检：
      #   新式 cfut_/cfat_ 开头 Token，或 35-50 位字母数字-_ 的经典 Token
      if [[ ! "$CF_API_TOKEN" =~ ^cf(ut|at)_[A-Za-z0-9_-]{32,256}$ \
            && ! "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{35,50}$ ]]; then
        warn "Token 格式与 Cloudflare API Token 特征不符（长度 ${#CF_API_TOKEN}）"
        warn "请确认输入的是 API Token，而不是 Global API Key，且未带引号/多余字符"
        warn "格式不符时 caddy validate 会直接拒绝，可能导致安装失败"
      fi
      info "已接收 API Token（长度 ${#CF_API_TOKEN}）"
    fi
  fi
  info "参数已录入"

  if [[ "$MODE" == "domain" ]] && command -v dig >/dev/null 2>&1; then
    RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
    [[ -z "$RESOLVED_IP" ]] && warn "域名解析失败，证书申请可能不成功"
  fi

  UUID=$(cat /proc/sys/kernel/random/uuid)
  info "自动生成初始 UUID: $UUID"

  # ---------- 安装基础依赖 ----------
  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl gnupg lsb-release ca-certificates openssl dnsutils

  # ---------- 仅域名模式安装 Caddy ----------
  if [[ "$MODE" == "domain" ]]; then
    step "安装 Caddy"
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      # ===== DNS-01：使用 xcaddy 构建带 cloudflare 插件的 Caddy =====
      info "DNS-01 模式：将使用 xcaddy 构建带 Cloudflare 插件的 Caddy"

      if ! command -v go >/dev/null 2>&1 || ! go version 2>/dev/null | grep -qE 'go1\.(2[1-9]|[3-9][0-9])'; then
        info "安装 Go 1.22（官方二进制）"
        local ARCH
        case "$(dpkg --print-architecture)" in
          amd64) ARCH="amd64" ;;
          arm64) ARCH="arm64" ;;
          *) error "不支持的架构：$(dpkg --print-architecture)" ;;
        esac
        rm -rf /usr/local/go
        if ! curl -sSL "https://go.dev/dl/go1.22.5.linux-${ARCH}.tar.gz" | tar -xz -C /usr/local; then
          error "Go 下载失败，请检查网络"
        fi
        export PATH="/usr/local/go/bin:$PATH"
      fi

      export PATH="$PATH:/usr/local/go/bin:$(go env GOPATH)/bin"
      if ! command -v xcaddy >/dev/null 2>&1; then
        info "安装 xcaddy"
        if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest; then
          error "xcaddy 安装失败。若网络受限，可先执行 export GOPROXY=https://goproxy.cn,direct 后重试"
        fi
        export PATH="$PATH:$(go env GOPATH)/bin"
      fi
      command -v xcaddy >/dev/null 2>&1 || error "xcaddy 安装失败"

      info "正在编译 Caddy（首次约 2-5 分钟，请耐心等待）..."
      if ! xcaddy build --with github.com/caddy-dns/cloudflare --output /usr/local/bin/caddy; then
        error "Caddy 构建失败。若网络受限，可先执行 export GOPROXY=https://goproxy.cn,direct 后重试"
      fi
      CADDY_BIN=/usr/local/bin/caddy
      [[ ! -x "$CADDY_BIN" ]] && error "Caddy 构建产物缺失"
    else
      # ===== HTTP-01：官方 APT 安装 =====
      if ! command -v caddy >/dev/null 2>&1; then
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        fi
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt-get update -y
        apt-get install -y caddy || apt-get install --reinstall -y caddy
      fi
      CADDY_BIN=$(command -v caddy)
    fi
    [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]] && error "Caddy 安装失败"
    info "Caddy: $($CADDY_BIN version)"
  else
    info "IP 模式：跳过 Caddy 安装与伪装站部署"
  fi

  # ---------- 安装 Xray ----------
  step "安装 Xray"
  if [[ ! -x /usr/local/bin/xray ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi

  # ---------- 出网预检 ----------
  step "出网预检"
  if ! check_outbound; then
    warn "服务器出网受限："
    warn "  - 域名模式：Caddy 可能申请不到证书"
    warn "  - IP 模式 ：REALITY 认证后流量出不去，客户端表现为『连上没网』"
    read -rp "仍要继续安装？[y/N]: " C
    [[ "${C,,}" != "y" ]] && { info "已取消安装"; read -rp "  按回车返回..." _; return; }
  fi

  # ---------- 端口占用检查 ----------
  if [[ "$MODE" == "domain" ]]; then
    handle_common_occupiers
  else
    if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
      warn "端口 ${XRAY_PORT} 已被占用"
      ss -tlnp | grep -E ":${XRAY_PORT}\b" || true
      read -rp "是否继续？[y/N]: " C
      [[ "${C,,}" != "y" ]] && { info "已取消"; return; }
    fi
  fi
  configure_log_retention

  # ---------- 放行防火墙端口（按验证方式） ----------
  step "放行防火墙端口"
  if [[ "$MODE" == "domain" ]]; then
    if [[ "$ACME_CHALLENGE" == "http" ]]; then
      open_firewall_port 80 "$XRAY_PORT"
    else
      open_firewall_port "$XRAY_PORT"
      info "DNS-01 模式：无需放行 80 端口（不会改动 80 上的任何服务）"
    fi
  else
    open_firewall_port "$XRAY_PORT"
  fi

  # ---------- 生成 Reality 密钥 ----------
  step "生成 Reality 密钥"
  generate_reality_keys
  info "PrivateKey: $PRIVATE_KEY"
  info "PublicKey : $PUBLIC_KEY"
  info "ShortId   : $SHORT_ID"

  # ---------- 创建初始用户 ----------
  step "创建初始用户"
  mkdir -p /etc/reality-caddy
  if [[ "${KEEP_USERS:-0}" == "1" && -s "$USERS_FILE" ]]; then
    info "保留已有用户"
  else
    : > "$USERS_FILE"
    echo "${UUID}|default|初始用户" >> "$USERS_FILE"
    info "已创建默认用户 default"
  fi
  chmod 600 "$USERS_FILE"

  # ---------- 保存安装信息 ----------
  INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  cat > "$INFO_FILE" <<EOF
MODE="${MODE}"
ACME_CHALLENGE="${ACME_CHALLENGE:-}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SITE_TITLE="${SITE_TITLE:-}"
SERVER_IP="${SERVER_IP:-}"
DEST_DOMAIN="${DEST_DOMAIN:-}"
XRAY_PORT="${XRAY_PORT}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
INSTALL_TIME="${INSTALL_TIME}"
EOF
  chmod 600 "$INFO_FILE"

  # ---------- 域名模式：配置 Caddy 与伪装站 ----------
  if [[ "$MODE" == "domain" ]]; then
    step "配置 Caddy"
    mkdir -p /etc/caddy

    # 根据验证方式生成 issuers 片段
    local ISSUERS_JSON
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      ISSUERS_JSON='[{
        "module": "acme",
        "email": "'"${EMAIL}"'",
        "challenges": {
          "dns": {
            "provider": {
              "name": "cloudflare",
              "api_token": "{env.CF_API_TOKEN}"
            }
          }
        }
      }]'
    else
      ISSUERS_JSON='[{ "module": "acme", "email": "'"${EMAIL}"'" }]'
    fi

    # 根据验证方式决定是否生成 80 端口跳转 server
    #   HTTP-01：生成 srvh1（:80 跳转 https），用于 ACME 挑战 + 访客跳转
    #   DNS-01 ：不生成 srvh1，且关闭 Caddy 自动 HTTPS 重定向
    #            （否则 Caddy 会在 127.0.0.1:80 自动建跳转监听，
    #             导致 nginx 等服务绑定 0.0.0.0:80 时冲突失败）
    local SRVH1_BLOCK=""
    local AUTOHTTPS_LINE=""
    if [[ "$ACME_CHALLENGE" == "http" ]]; then
      SRVH1_BLOCK='        "srvh1": {
          "listen": [":80"],
          "routes": [{
            "handle": [{
              "handler": "static_response",
              "headers": {"Location": ["https://{http.request.host}{http.request.uri}"]},
              "status_code": 301
            }]
          }],
          "protocols": ["h1"]
        },
'
    else
      AUTOHTTPS_LINE='"automatic_https": { "disable_redirects": true },'
    fi

    cat > /etc/caddy/caddy.json <<EOF
{
  "apps": {
    "http": {
      "servers": {
${SRVH1_BLOCK}        "srvh2": {
          ${AUTOHTTPS_LINE}
          "listen": ["127.0.0.1:8003"],
          "listener_wrappers": [
            {"wrapper": "proxy_protocol", "allow": ["127.0.0.1/32"]},
            {"wrapper": "tls"}
          ],
          "routes": [{
            "handle": [
              {
                "handler": "headers",
                "response": {
                  "set": {
                    "Strict-Transport-Security": ["max-age=31536000; includeSubDomains; preload"]
                  }
                }
              },
              {"handler": "file_server", "root": "/var/www/html"}
            ]
          }],
          "tls_connection_policies": [{
            "match": {"sni": ["${DOMAIN}"]},
            "alpn": ["h2", "http/1.1"]
          }],
          "protocols": ["h1", "h2", "h3"]
        }
      }
    },
    "tls": {
      "certificates": {"automate": ["${DOMAIN}"]},
      "automation": {
        "policies": [{
          "issuers": ${ISSUERS_JSON}
        }]
      }
    }
  }
}
EOF
    # caddy validate 会在 Provision 阶段解析 {env.CF_API_TOKEN} 占位符并校验
    # Token 格式，必须让 validate 子进程拿到该变量，否则按空 Token 报错
    local VAL_ENV=()
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      VAL_ENV=("CF_API_TOKEN=${CF_API_TOKEN}")
    fi
    if ! env "${VAL_ENV[@]}" "$CADDY_BIN" validate --config /etc/caddy/caddy.json >/tmp/caddy_validate.log 2>&1; then
      warn "Caddy 配置校验失败，原始错误输出："
      sed 's/^/  | /' /tmp/caddy_validate.log >&2 || cat /tmp/caddy_validate.log >&2
      error "Caddy 配置校验失败"
    fi
    info "Caddy 配置校验通过"

    step "创建伪装站点"
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${SITE_TITLE}</title>
  <style>
    body { font-family: -apple-system, "Segoe UI", Arial, sans-serif; display:flex;
           align-items:center; justify-content:center; height:100vh; margin:0;
           background:linear-gradient(135deg,#667eea,#764ba2); color:#fff; }
    .box { text-align:center; }
    h1 { font-size:3rem; margin:0; }
  </style>
</head>
<body>
  <div class="box"><h1>${SITE_TITLE}</h1><p>It works!</p></div>
</body>
</html>
EOF
    info "伪装站点已创建"

    step "配置 Caddy systemd 服务"

    local ENVFILE_LINE=""
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > /etc/caddy/caddy.env
      chmod 600 /etc/caddy/caddy.env
      chown root:root /etc/caddy/caddy.env
      ENVFILE_LINE="EnvironmentFile=/etc/caddy/caddy.env"
      info "API Token 已写入 /etc/caddy/caddy.env（权限 600）"
      unset CF_API_TOKEN
    fi

    cat > /etc/systemd/system/caddy-json.service <<EOF
[Unit]
Description=Caddy JSON Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
${ENVFILE_LINE}
ExecStart=${CADDY_BIN} run --config /etc/caddy/caddy.json
Restart=always
RestartSec=3
User=root
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable caddy-json.service
    info "caddy-json.service 已启用"
  fi

  # ---------- 生成 Xray 配置并启动 ----------
  step "配置并启动 Xray"
  rebuild_xray_config || error "Xray 配置生成失败"
  systemctl enable xray
  systemctl restart xray

  if [[ "$MODE" == "domain" ]]; then
    step "启动 Caddy"
    systemctl restart caddy-json.service
    info "等待 Caddy 启动并申请证书（最多 30 秒）..."
    for i in $(seq 1 30); do
      systemctl is-active --quiet caddy-json.service && \
        ss -tln 2>/dev/null | grep -q '127.0.0.1:8003' && break
      sleep 1
    done
  fi

  # ---------- 安装后自检 ----------
  step "安装后自检"
  local SELFCHECK_FAIL=0

  systemctl is-active --quiet xray \
    && info "xray.service: 运行中" \
    || { warn "xray 未运行 → journalctl -u xray -n 50 --no-pager"; SELFCHECK_FAIL=1; }

  if [[ "$MODE" == "domain" ]]; then
    systemctl is-active --quiet caddy-json.service \
      && info "caddy-json: 运行中" \
      || { warn "caddy 未运行 → journalctl -u caddy-json -n 50 --no-pager"; SELFCHECK_FAIL=1; }

    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      if [[ -x /usr/local/bin/caddy ]] && /usr/local/bin/caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
        info "Caddy 已包含 cloudflare DNS 插件"
      else
        warn "Caddy 未包含 cloudflare 插件，DNS-01 会失败"; SELFCHECK_FAIL=1
      fi
      # 确认 Caddy 没有监听 80
      if ss -tln 2>/dev/null | grep -qE ':80\b' && ss -tlnp 2>/dev/null | grep ':80\b' | grep -q caddy; then
        warn "检测到 Caddy 正在监听 80 端口，与 DNS-01 模式预期不符"; SELFCHECK_FAIL=1
      else
        info "确认 Caddy 未监听 80 端口"
      fi

      # 确认证书真正签发成功（DNS-01 关键自检）
      info "等待 DNS-01 证书签发结果（最长 120 秒，请稍候）..."
      local CERT_OK=0 i
      for i in $(seq 1 60); do
        if check_cert_obtained "$DOMAIN"; then CERT_OK=1; break; fi
        sleep 2
      done
      if [[ $CERT_OK -eq 1 ]]; then
        info "证书已成功签发（DNS-01 验证通过）"
      else
        SELFCHECK_FAIL=1
        warn "证书尚未签发成功，请查看日志: journalctl -u caddy-json -n 100 --no-pager"
        warn "常见原因:"
        warn "  1) API Token 权限不足（需 Zone.Zone:Read + Zone.DNS:Edit，且作用域包含 ${DOMAIN}）"
        warn "  2) Token 输错或已失效（可在 Cloudflare 后台重新创建）"
        warn "  3) 域名 NS 未托管在 Cloudflare（DNS-01 要求域名解析在 Cloudflare）"
        warn "  4) caddy.env 中 CF_API_TOKEN 与 caddy.json 未关联（本版本已修复该问题）"
      fi
    fi
  fi

  if ss -tln 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
    info "端口 ${XRAY_PORT} 已监听"
    ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" | sed 's/^/       /'
  else
    warn "未发现端口 ${XRAY_PORT} 监听"
    SELFCHECK_FAIL=1
  fi

  echo
  echo "检查服务器出网情况（REALITY 认证后要靠本机直连出去）："
  if check_outbound; then
    info "出网正常"
  else
    SELFCHECK_FAIL=1
    warn "服务器出网受限 —— 服务会正常运行，但客户端会『连上却打不开网页』"
    warn "请检查：机房线路是否屏蔽了目标站点、是否有 DNS 污染、是否被限速"
  fi

  if [[ "$MODE" == "ip" && -n "${DEST_DOMAIN:-}" ]]; then
    echo
    echo "检查伪装目标 ${DEST_DOMAIN} 的 TLS1.3 握手："
    if probe_dest_tls "$DEST_DOMAIN" 443; then
      info "dest 握手正常"
    else
      SELFCHECK_FAIL=1
      warn "dest 握手异常 —— 客户端会『连上即断』，请重新安装并更换目标"
    fi
  fi

  echo
  if [[ $SELFCHECK_FAIL -eq 0 ]]; then
    info "自检全部通过"
  else
    warn "自检存在问题（见上方红/黄提示），节点可能不可用"
  fi

  echo
  show_client_info

  print_port_notice "$MODE" "$XRAY_PORT"

  info "安装完成！"
  read -rp "  按回车返回主菜单..." _
}

# ============================================================================
# 二、卸载
# ============================================================================
do_uninstall() {
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  echo
  local MODE=""
  load_kv "$INFO_FILE" 2>/dev/null || true
  [[ -z "$MODE" ]] && MODE="domain"
  warn "即将卸载（模式: ${MODE}${ACME_CHALLENGE:+, 验证: $ACME_CHALLENGE}）"
  read -rp "确认卸载？输入 yes 继续: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  if [[ "$MODE" == "domain" ]]; then
    systemctl stop caddy-json.service 2>/dev/null || true
    systemctl disable caddy-json.service 2>/dev/null || true
    rm -f /etc/systemd/system/caddy-json.service
  fi
  systemctl daemon-reload

  if [[ "$MODE" == "domain" ]] || [[ -d /etc/caddy ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy.service"; then
    if dpkg -l 2>/dev/null | grep -q "^ii  caddy "; then
      info "卸载 Caddy 软件包"
      apt-get purge -y caddy || true
    fi
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -rf /etc/caddy /var/lib/caddy

    rm -f /usr/local/bin/caddy
    if command -v go >/dev/null 2>&1; then
      rm -f "$(go env GOPATH)/bin/xcaddy" 2>/dev/null || true
    fi
    info "Caddy 相关文件已清理"
  fi

  [[ -f /usr/local/bin/xray ]] && \
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -rf /usr/local/etc/xray /var/log/xray

  read -rp "删除 /etc/reality-caddy ? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -rf /etc/reality-caddy && info "已删除"

  if [[ "$MODE" == "domain" && -d /var/www/html ]]; then
    read -rp "删除伪装站 /var/www/html ? [y/N]: " DEL
    [[ "${DEL,,}" == "y" ]] && rm -rf /var/www/html && info "已删除"
  fi

  echo
  if [[ "$MODE" == "ip" ]]; then
    info "IP 模式卸载完成（本机未安装 Caddy，也未部署伪装页面）"
    warn "如需彻底断服，请记得在云厂商安全组中删除 TCP ${XRAY_PORT:-8443} 的放行规则"
  else
    info "域名模式卸载完成"
    if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
      warn "如需彻底断服，请记得在云厂商安全组中删除 TCP 80/443 的放行规则"
    else
      warn "如需彻底断服，请记得在云厂商安全组中删除 Xray 端口对应的放行规则"
      info "80 端口未由本脚本占用，请勿删除您自己服务的放行规则"
    fi
  fi
  read -rp "  按回车返回..." _
}

# ============================================================================
# 三、查看状态
# ============================================================================
do_status() {
  clear
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  load_kv "$INFO_FILE" 2>/dev/null || true
  step "服务状态"
  echo "模式: ${MODE:-domain}"
  if [[ "${MODE:-domain}" == "ip" ]]; then
    echo "IP: ${SERVER_IP:-未知}  |  伪装: ${DEST_DOMAIN:-未知}  |  端口: ${XRAY_PORT}"
  else
    echo "域名: ${DOMAIN:-未知}  |  端口: ${XRAY_PORT}  |  验证: ${ACME_CHALLENGE:-http}"
  fi
  echo

  systemctl status xray --no-pager -l | head -n 12 || true
  echo

  if [[ "${MODE:-domain}" == "domain" ]]; then
    systemctl status caddy-json.service --no-pager -l | head -n 8 || true
    echo
  fi

  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" || echo "端口未监听"
  echo

  command -v xray >/dev/null && xray version | head -1

  print_port_notice "${MODE:-domain}" "${XRAY_PORT}"
  read -rp "  按回车返回..." _
}

# ============================================================================
# 四、显示客户端参数
# ============================================================================
show_client_info() {
  load_kv "$INFO_FILE" || { warn "未找到 $INFO_FILE"; return 1; }

  local uuid="" email=""
  if [[ -f "$USERS_FILE" ]]; then
    echo
    echo "可用用户："
    local i=1
    local -a UUIDS=() EMAILS=()
    while IFS='|' read -r u e n; do
      [[ -z "$u" || "$u" =~ ^# ]] && continue
      UUIDS+=("$u")
      EMAILS+=("$e")
      printf "  %d) %s (%s) %s\n" "$i" "$e" "$u" "${n:-}"
      ((i++))
    done < "$USERS_FILE"

    if [[ ${#UUIDS[@]} -gt 0 ]]; then
      read -rp "  选择用户编号 (默认 1): " SEL
      SEL=${SEL:-1}
      if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#UUIDS[@]} )); then
        uuid="${UUIDS[$((SEL-1))]}"
        email="${EMAILS[$((SEL-1))]}"
      else
        uuid="${UUIDS[0]}"
        email="${EMAILS[0]}"
      fi
    fi
  fi
  [[ -z "$uuid" ]] && uuid="${UUID:-}"

  local ADDR SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    ADDR="${SERVER_IP}"
    SNI="${DEST_DOMAIN}"
  else
    ADDR="${DOMAIN}"
    SNI="${DOMAIN}"
  fi

  echo
  step "客户端配置"
  cat <<EOF
模式        : ${MODE:-domain}
协议        : VLESS
地址        : ${ADDR}
端口        : ${XRAY_PORT}
UUID        : ${uuid}
流控        : xtls-rprx-vision
传输        : tcp
安全        : reality
SNI         : ${SNI}
Fingerprint : chrome
PublicKey   : ${PUBLIC_KEY}
ShortId     : ${SHORT_ID}
EOF
  echo -e "${CYAN}  ───────────────── 分享链接 ─────────────────${NC}"
  echo "vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email:-${ADDR}}"
  echo -e "${CYAN}  ─────────────────────────────────────────────${NC}"

  if [[ "${MODE:-domain}" == "domain" ]]; then
    echo "伪装站点    : https://${DOMAIN}"
  else
    echo "伪装目标    : ${DEST_DOMAIN}"
  fi
}

do_show_client() {
  clear
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi
  show_client_info || true
  echo
  read -rp "  按回车返回主菜单..." _
}

# ============================================================================
# 五、用户管理
# ============================================================================
users_menu() {
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi
  while true; do
    clear
    banner "用户管理"
    echo -e "  ${GREEN}[1]${NC} 列出用户      ${GREEN}[2]${NC} 添加用户"
    echo -e "  ${GREEN}[3]${NC} 删除用户      ${GREEN}[4]${NC} 查看链接"
    echo -e "  ${GREEN}[0]${NC} 返回菜单"
    echo
    read -rp "  请选择 [0-4]: " UC
    case "$UC" in
      1) users_list ;;
      2) users_add ;;
      3) users_del ;;
      4) users_show ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

users_list_noread() {
  printf "%-4s %-40s %-24s %s\n" "No." "UUID" "标识" "备注"
  printf "%-4s %-40s %-24s %s\n" "----" "----------------------------------------" "------------------------" "----"
  local i=1
  while IFS='|' read -r u e n; do
    [[ -z "$u" || "$u" =~ ^# ]] && continue
    printf "%-4s %-40s %-24s %s\n" "$i" "$u" "$e" "${n:-}"
    ((i++))
  done < "$USERS_FILE"
}

users_list() {
  clear
  step "用户列表"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
  else
    users_list_noread
  fi
  echo
  read -rp "  按回车返回..." _
}

users_add() {
  clear
  step "添加用户"
  read -rp "用户标识 email (可空): " EMAIL
  read -rp "备注 note (可空): " NOTE
  EMAIL=${EMAIL:-user$(date +%s)@local}

  local UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "${UUID}|${EMAIL}|${NOTE}" >> "$USERS_FILE"
  info "已添加: $EMAIL ($UUID)"

  if rebuild_xray_config; then
    systemctl restart xray
    info "Xray 已重启"
  else
    sed -i '$ d' "$USERS_FILE"
    warn "配置失败，已回滚"
  fi
  read -rp "  按回车返回..." _
}

users_del() {
  clear
  step "删除用户"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "  按回车返回..." _
    return
  fi

  users_list_noread
  read -rp "  输入要删除的用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; read -rp "  按回车返回..." _; return; }

  local total
  total=$(grep -vcE '^\s*(#|$)' "$USERS_FILE" || true)
  (( IDX < 1 || IDX > total )) && { warn "编号越界"; read -rp "  按回车返回..." _; return; }

  local target_email
  target_email=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p" | cut -d'|' -f2)
  read -rp "确认删除 $target_email ? [y/N]: " C
  [[ "${C,,}" != "y" ]] && { info "已取消"; return; }

  cp "$USERS_FILE" "${USERS_FILE}.bak"
  awk -v n="$IDX" '
    BEGIN { c=0 }
    /^\s*(#|$)/ { print; next }
    { c++; if (c==n) next; print }
  ' "${USERS_FILE}.bak" > "$USERS_FILE"

  info "已删除 $target_email"
  if rebuild_xray_config; then
    systemctl restart xray
  else
    cp "${USERS_FILE}.bak" "$USERS_FILE"
    warn "配置失败，已恢复"
  fi
  rm -f "${USERS_FILE}.bak"
  read -rp "  按回车返回..." _
}

users_show() {
  clear
  step "查看某用户分享链接"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "  按回车返回..." _
    return
  fi

  users_list_noread
  read -rp "  输入用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; return; }

  local line uuid email
  line=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p")
  [[ -z "$line" ]] && { warn "编号越界"; return; }

  uuid=$(echo "$line" | cut -d'|' -f1)
  email=$(echo "$line" | cut -d'|' -f2)
  load_kv "$INFO_FILE" || return

  local ADDR SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    ADDR="${SERVER_IP}"
    SNI="${DEST_DOMAIN}"
  else
    ADDR="${DOMAIN}"
    SNI="${DOMAIN}"
  fi

  echo
  step "用户信息（${email}）"
  cat <<EOF
地址        : ${ADDR}
端口        : ${XRAY_PORT}
UUID        : ${uuid}
SNI         : ${SNI}
PublicKey   : ${PUBLIC_KEY}
ShortId     : ${SHORT_ID}
EOF
  echo -e "${CYAN}  ───────────────── 分享链接 ─────────────────${NC}"
  echo "vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email}"
  echo -e "${CYAN}  ─────────────────────────────────────────────${NC}"
  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 六、诊断自检
# ============================================================================
do_diagnose() {
  clear
  step "诊断自检"
  if [[ ! -f "$INFO_FILE" ]]; then
    warn "未找到 $INFO_FILE，可能尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  local MODE="" XRAY_PORT="" DEST_DOMAIN="" DOMAIN="" PUBLIC_KEY="" SHORT_ID="" PRIVATE_KEY="" ACME_CHALLENGE=""
  load_kv "$INFO_FILE" 2>/dev/null || true
  echo "模式: ${MODE:-未知}   端口: ${XRAY_PORT:-未知}"
  [[ "$MODE" == "ip" ]] && echo "伪装目标: ${DEST_DOMAIN:-未知}"
  [[ "$MODE" == "domain" ]] && echo "验证方式: ${ACME_CHALLENGE:-http}"

  echo
  echo "[1] 服务状态"
  systemctl is-active --quiet xray && info "xray 运行中" || warn "xray 未运行"
  [[ "$MODE" == "domain" ]] && {
    systemctl is-active --quiet caddy-json.service && info "caddy-json 运行中" || warn "caddy-json 未运行"
  }

  echo
  echo "[2] 端口监听"
  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" | sed 's/^/  /' \
    || warn "端口 ${XRAY_PORT} 未监听"

  echo
  echo "[3] 服务器出网"
  check_outbound || warn "出网受限：客户端会『连上但没网』"

  if [[ "$MODE" == "ip" && -n "$DEST_DOMAIN" ]]; then
    echo
    echo "[4] 伪装目标 ${DEST_DOMAIN} 的 TLS1.3 握手"
    if probe_dest_tls "$DEST_DOMAIN" 443; then
      info "握手正常"
    else
      warn "握手异常！这是 IP 模式『连上即断』的典型原因，请换目标重新安装"
      echo "     手工确认：openssl s_client -connect ${DEST_DOMAIN}:443 -servername ${DEST_DOMAIN} -tls1_3 -brief"
    fi
  fi

  echo
  echo "[5] 密钥"
  echo "  PublicKey: ${PUBLIC_KEY:-空}  (长度 ${#PUBLIC_KEY})"
  echo "  ShortId  : ${SHORT_ID:-空}"
  [[ ${#PUBLIC_KEY} -lt 40 ]] && warn "PublicKey 长度异常，客户端会失败"
  if command -v xray >/dev/null 2>&1 && [[ -n "${PRIVATE_KEY:-}" ]]; then
    local calc
    calc=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -iE 'public|password' | awk '{print $NF}' | head -1)
    if [[ -n "$calc" ]]; then
      [[ "$calc" == "$PUBLIC_KEY" ]] && info "公私钥配对正确" || warn "公私钥不配对！请重建密钥"
    fi
  fi

  echo
  echo "[6] 证书验证方式"
  echo "  方式: ${ACME_CHALLENGE:-http}"
  if [[ "${ACME_CHALLENGE:-http}" == "dns" ]]; then
    if [[ -s /etc/caddy/caddy.env ]] && grep -q '^CF_API_TOKEN=' /etc/caddy/caddy.env; then
      info "CF_API_TOKEN 环境文件存在"
    else
      warn "/etc/caddy/caddy.env 缺失或为空，证书续期会失败"
    fi
    if [[ -x /usr/local/bin/caddy ]]; then
      if /usr/local/bin/caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
        info "Caddy 已包含 cloudflare DNS 插件"
      else
        warn "当前 Caddy 未包含 cloudflare 插件，DNS-01 会失败"
      fi
    else
      warn "/usr/local/bin/caddy 不存在（DNS-01 需要 xcaddy 构建版）"
    fi
    # 确认 Caddy 未监听 80
    if ss -tlnp 2>/dev/null | grep ':80\b' | grep -q caddy; then
      warn "Caddy 正在监听 80，与 DNS-01 预期不符"
    else
      info "Caddy 未监听 80"
    fi
    # 确认证书已实际签发
    if check_cert_obtained "${DOMAIN:-}"; then
      info "证书已签发（DNS-01 正常）"
    else
      warn "未找到已签发的证书，DNS-01 申请可能失败"
      warn "请检查: journalctl -u caddy-json -n 100 --no-pager"
      warn "并确认 caddy.json 中 cloudflare provider 含 \"api_token\": \"{env.CF_API_TOKEN}\""
    fi
  fi

  echo
  echo "[7] 客户端必须核对的三项"
  if [[ "$MODE" == "ip" ]]; then
    echo "  地址/SNI : 地址填 IP，SNI 必须填 ${DEST_DOMAIN}（不能填 IP）"
  else
    echo "  地址/SNI : 都填 ${DOMAIN}"
  fi
  echo "  PublicKey: 必须是本机 info.txt 里的值（换模式后旧值会失效）"
  echo "  ShortId  : 同上，不能沿用旧节点的"

  echo
  echo "[8] xray 近期错误日志"
  journalctl -u xray -n 100 --no-pager 2>/dev/null \
    | grep -iE "rejected|invalid|failed|refused|timeout|no route|address already" \
    | tail -8 | sed 's/^/  /' || echo "  无明显错误"

  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 主循环
# ============================================================================
while true; do
  show_menu
  case "$CHOICE" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_status ;;
    4) do_show_client ;;
    5) users_menu ;;
    6) do_diagnose ;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
done
