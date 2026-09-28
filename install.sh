#!/usr/bin/env bash
# ============================================================================
# Xray Reality + Vision 一键管理脚本
# 支持两种安装模式：域名模式 / IP模式
# ----------------------------------------------------------------------------
# 功能说明：
#   1) 安装
#      - 域名模式：Xray(Reality+Vision) + Caddy(本地伪装站 + 自动申请证书)
#                 默认监听端口 443
#      - IP模式  ：仅安装 Xray(Reality+Vision)，不需要域名、不安装 Caddy
#                 默认监听端口 8443，需选择一个真实网站作为伪装目标
#   2) 卸载      ：停止并移除服务、配置，可选清理伪装站和安装信息
#   3) 查看状态  ：展示服务运行状态、端口监听、版本信息
#   4) 客户端参数：输出指定用户的 VLESS 分享链接和详细参数
#   5) 用户管理  ：列出 / 添加 / 删除用户，并实时重建 Xray 配置
#
# 适用系统：Debian 11/12/13、Ubuntu 20.04/22.04/24.04
# 必须以 root 用户运行
# ============================================================================

# set -e  : 任意命令失败立即退出
# set -u  : 使用未定义变量时报错
# set -o pipefail : 管道中任一命令失败则整个管道失败
set -euo pipefail

# ----------------------------------------------------------------------------
# 终端颜色定义（用于美化输出）
# ----------------------------------------------------------------------------
RED='\033[0;31m'      # 红色 - 错误
GREEN='\033[0;32m'    # 绿色 - 正常信息
YELLOW='\033[1;33m'   # 黄色 - 警告
BLUE='\033[0;34m'     # 蓝色 - 步骤标题
CYAN='\033[0;36m'     # 青色 - 菜单/高亮
NC='\033[0m'          # 重置颜色

# ----------------------------------------------------------------------------
# 输出辅助函数
# ----------------------------------------------------------------------------
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }           # 普通提示
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }          # 警告提示
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }    # 错误并退出脚本
step()  { echo -e "\n${BLUE}===== $* =====${NC}"; }     # 步骤分隔标题

# ----------------------------------------------------------------------------
# 权限检查：必须使用 root 运行
# $EUID 为当前有效用户 ID，0 表示 root
# ----------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行，或先执行: sudo -i"

# ----------------------------------------------------------------------------
# 发行版检测：仅允许 Debian / Ubuntu
# 读取 /etc/os-release 中的 ID 字段进行判断
# ----------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release   # 导入系统信息变量（ID、PRETTY_NAME 等）
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
# 全局变量定义
# ----------------------------------------------------------------------------
USERS_FILE=/etc/reality-caddy/users.txt          # 用户列表文件，格式：UUID|email|备注
INFO_FILE=/etc/reality-caddy/info.txt            # 安装信息文件（模式、密钥、端口等）
XRAY_CONF=/usr/local/etc/xray/config.json        # Xray 主配置文件路径
LOG_RETENTION_DAYS=7                             # 日志保留天数
CADDY_BIN=""                                     # Caddy 可执行文件路径，运行时动态探测

# IP 模式下可选的 Reality 伪装目标域名列表
# 选择标准：支持 TLS1.3、兼容性较好、尽量避开已知有问题的站点
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
# 主菜单显示函数
# ============================================================================
show_menu() {
  clear
  echo -e "${CYAN}"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════╗
  ║   Xray Reality + Vision 管理脚本                 ║
  ║   (支持 域名模式 / IP模式)                       ║
  ╠══════════════════════════════════════════════════╣
  ║   1) 安装                                        ║
  ║   2) 卸载                                        ║
  ║   3) 查看状态                                    ║
  ║   4) 查看客户端参数                              ║
  ║   5) 用户管理                                    ║
  ║   0) 退出                                        ║
  ╚══════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
  read -rp "请选择 [0-5]: " CHOICE
}

# ============================================================================
# 判断本机是否已安装本方案
# 判断依据：存在 info.txt 文件，或存在 caddy-json.service
# ============================================================================
is_installed() {
  [[ -f "$INFO_FILE" ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy-json.service"
}

# ============================================================================
# 安全读取 key=value 格式的配置文件
# 功能：
#   - 跳过空行和以 # 开头的注释行
#   - 去除 key 两端空白
#   - 去除 value 两端的单引号或双引号
#   - 使用 printf -v 动态赋值，避免使用 eval 带来的注入风险
# 用法：load_kv /path/to/file
# ============================================================================
load_kv() {
  local FILE=$1
  [[ ! -f "$FILE" ]] && return 1
  while IFS='=' read -r key value; do
    # 跳过空行和注释
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | xargs)           # 去除 key 两端空白
    value=${value%\"}; value=${value#\"} # 去除双引号
    value=${value%\'}; value=${value#\'} # 去除单引号
    printf -v "$key" '%s' "$value"       # 将值赋给同名变量
  done < "$FILE"
  return 0
}

# ============================================================================
# 根据 users.txt 生成 Xray 配置中的 clients JSON 数组
# 输出示例：
#   [
#     {
#       "id": "uuid-xxxx",
#       "email": "user@example.com",
#       "flow": "xtls-rprx-vision"
#     }
#   ]
# ============================================================================
build_clients_json() {
  # 文件不存在时返回空数组
  [[ ! -f "$USERS_FILE" ]] && { echo '[]'; return; }
  local first=1
  echo "["
  while IFS='|' read -r uuid email note; do
    # 跳过空行和注释行
    [[ -z "$uuid" || "$uuid" =~ ^# ]] && continue
    # 非第一个元素前输出逗号
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
# 使用 info.txt + users.txt 重建 Xray 主配置文件
# 成功后执行 xray -test 校验配置合法性
# 返回值：0 成功，1 失败
# ============================================================================
rebuild_xray_config() {
  load_kv "$INFO_FILE" || error "未找到 $INFO_FILE，请先安装"
  mkdir -p "$(dirname "$XRAY_CONF")"

  local CLIENTS_JSON
  CLIENTS_JSON=$(build_clients_json)

  # 根据安装模式决定 Reality 的回落目标和 SNI
  local REALITY_DEST REALITY_SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    # IP 模式：回落到真实外部网站
    REALITY_DEST="${DEST_DOMAIN}:443"
    REALITY_SNI="${DEST_DOMAIN}"
  else
    # 域名模式：回落到本机 Caddy 提供的伪装站
    REALITY_DEST="127.0.0.1:8003"
    REALITY_SNI="${DOMAIN}"
  fi

  # 写入完整 Xray 配置
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

  # 校验配置是否合法
  if ! xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "Xray 配置校验失败，输出："
    xray -test -config "$XRAY_CONF" || true
    return 1
  fi
  return 0
}

# ============================================================================
# 处理常见 Web 服务对 80/443 端口的占用
# 仅在域名模式下调用（需要 80 申请证书、443 给 Xray）
# ============================================================================
handle_common_occupiers() {
  step "检测并处理常见端口占用"

  # 停止并禁用 Nginx
  systemctl is-active --quiet nginx 2>/dev/null && {
    warn "停止 Nginx"
    systemctl stop nginx
    systemctl disable nginx
  }

  # 停止并禁用 Apache2
  systemctl is-active --quiet apache2 2>/dev/null && {
    warn "停止 Apache2"
    systemctl stop apache2
    systemctl disable apache2
  }

  # 停止 Apache2 的 socket 激活（Ubuntu 常见）
  systemctl stop apache2.socket 2>/dev/null || true
  systemctl disable apache2.socket 2>/dev/null || true

  # 停用系统自带的 caddy 服务，避免抢占端口
  systemctl stop caddy.service 2>/dev/null || true
  systemctl disable caddy.service 2>/dev/null || true

  # 检查端口是否仍被占用
  if ss -tlnp 2>/dev/null | grep -qE ':(80|443)\b'; then
    warn "80/443 仍被占用："
    ss -tlnp | grep -E ':(80|443)' || true
  else
    info "80/443 端口空闲"
  fi
}

# ============================================================================
# 配置日志保留策略
# 1. journald：限制保留时间和磁盘占用
# 2. Xray 文件日志：通过 tmpfiles 定期清理
# ============================================================================
configure_log_retention() {
  step "配置日志保留策略（${LOG_RETENTION_DAYS} 天）"

  # journald 配置
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

  # 确保持久化 journal 目录存在
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
  systemctl restart systemd-journald

  # 立即按时间清理一次
  journalctl --vacuum-time=${LOG_RETENTION_DAYS}d >/dev/null 2>&1 || true

  # Xray 日志目录清理规则（按修改时间删除超过 N 天的文件）
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
# IP 模式：让用户选择 Reality 伪装目标域名
# ============================================================================
choose_dest_domain() {
  echo
  echo "请选择 Reality 伪装目标域名（推荐使用默认）："
  local i=1
  for d in "${BUILTIN_DESTS[@]}"; do
    printf "  %d) %s\n" "$i" "$d"
    ((i++))
  done
  printf "  %d) 自定义输入\n" "$i"
  echo
  read -rp "请选择 [1-${i}] (默认 1): " SEL
  SEL=${SEL:-1}

  if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#BUILTIN_DESTS[@]} )); then
    DEST_DOMAIN="${BUILTIN_DESTS[$((SEL-1))]}"
  elif [[ "$SEL" == "$i" ]]; then
    read -rp "请输入自定义伪装域名 (例如 www.example.com): " DEST_DOMAIN
    [[ -z "$DEST_DOMAIN" ]] && error "伪装域名不能为空"
  else
    # 输入无效时使用列表第一个
    DEST_DOMAIN="${BUILTIN_DESTS[0]}"
  fi
  info "已选择伪装域名: $DEST_DOMAIN"
}

# ============================================================================
# 尝试获取本机公网 IPv4 地址
# 依次尝试多个公共接口，成功则返回 IP，失败返回空字符串
# ============================================================================
get_public_ip() {
  local ip=""
  for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://one.one.one.one/cdn-cgi/trace"; do
    if [[ "$url" == *"trace"* ]]; then
      # Cloudflare trace 接口返回格式为 ip=x.x.x.x
      ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | grep -oP 'ip=\K[^ ]+' || true)
    else
      ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
    fi
    # 简单校验是否为 IPv4 格式
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  echo ""
}

# ============================================================================
# 生成 Reality 所需的 X25519 密钥对和 ShortId
# 兼容不同版本 xray x25519 的输出格式
# ============================================================================
generate_reality_keys() {
  local out
  out=$(xray x25519 2>/dev/null)

  # 方式一：按冒号分割取后半部分（常见格式）
  local tmp
  tmp=($(echo "$out" | sed 's/.*://'))
  PRIVATE_KEY=${tmp[0]:-}
  PUBLIC_KEY=${tmp[1]:-}

  # 方式二：按关键字匹配
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(echo "$out" | grep -iE 'Private|私钥' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$out" | grep -iE 'Public|Password|公钥|密码' | awk '{print $NF}' | head -1)
  fi

  # 方式三：按行号兜底
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(echo "$out" | sed -n '1p' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$out" | sed -n '2p' | awk '{print $NF}')
  fi

  [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "生成 Reality 密钥失败，请检查 xray 版本"

  # 生成 8 字节（16 位十六进制）随机 ShortId
  SHORT_ID=$(openssl rand -hex 8)
}

# ============================================================================
# 一、安装主流程
# ============================================================================
do_install() {
  local KEEP_USERS=0   # 1=覆盖重装时保留用户文件；0=清空

  # ---------- 已安装检测与重装选项 ----------
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
      fi
      echo "  端口      : ${XRAY_PORT:-未知}"
      echo "  安装时间  : ${INSTALL_TIME:-未知}"
      echo "  用户数量  : $(grep -vcE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null || echo 0)"
      echo
    fi
    echo "  1) 覆盖重装（保留 users.txt）"
    echo "  2) 完全重装（清空用户与配置）"
    echo "  0) 返回主菜单"
    echo
    read -rp "请选择 [0-2]: " REINSTALL
    case "$REINSTALL" in
      1)
        KEEP_USERS=1
        info "将保留用户列表"
        ;;
      2)
        read -rp "确认清空？输入 yes 继续: " C
        [[ "$C" != "yes" ]] && { info "已取消"; read -rp "按回车返回..." _; return; }
        KEEP_USERS=0
        ;;
      *)
        info "已取消"
        read -rp "按回车返回..." _
        return
        ;;
    esac
  fi

  # ---------- 选择安装模式（默认域名模式） ----------
  step "选择安装模式"
  echo "  1) 域名模式（推荐）- 自己的域名 + Caddy 伪装站 + 自动证书  默认端口 443"
  echo "  2) IP模式         - 直接用公网 IP，无需域名/Caddy           默认端口 8443"
  echo
  read -rp "请选择模式 [1-2] (默认 1): " MODE_SEL
  MODE_SEL=${MODE_SEL:-1}
  case "$MODE_SEL" in
    1) MODE="domain" ;;
    *) MODE="ip" ;;
  esac
  info "已选择: $([ "$MODE" = "ip" ] && echo "IP模式" || echo "域名模式")"

  # ---------- 交互输入参数 ----------
  step "参数配置"
  if [[ "$MODE" == "ip" ]]; then
    # ---- IP 模式参数 ----
    local DETECTED_IP
    DETECTED_IP=$(get_public_ip)
    if [[ -n "$DETECTED_IP" ]]; then
      read -rp "检测到公网 IP: ${DETECTED_IP}，直接回车使用，或输入其他 IP: " SERVER_IP
      SERVER_IP=${SERVER_IP:-$DETECTED_IP}
    else
      read -rp "请输入服务器公网 IP: " SERVER_IP
    fi
    [[ -z "$SERVER_IP" ]] && error "服务器 IP 不能为空"

    read -rp "请输入 Xray 监听端口 (默认 8443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-8443}

    choose_dest_domain   # 选择伪装目标域名
    EMAIL=""
    SITE_TITLE=""
    DOMAIN=""
  else
    # ---- 域名模式参数 ----
    read -rp "请输入你的域名 (例如: example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空"
    read -rp "请输入用于 ACME 的邮箱: " EMAIL
    [[ -z "$EMAIL" ]] && error "邮箱不能为空"
    read -rp "请输入伪装站标题 (默认: Welcome): " SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-Welcome}
    read -rp "请输入 Xray 监听端口 (默认 443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}
    SERVER_IP=""
    DEST_DOMAIN=""
  fi
  info "参数已录入"

  # 域名模式：静默检查域名是否已解析（不打印真实 IP）
  if [[ "$MODE" == "domain" ]] && command -v dig >/dev/null 2>&1; then
    RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
    [[ -z "$RESOLVED_IP" ]] && warn "域名解析失败，证书申请可能不成功"
  fi

  # 生成初始用户 UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)
  info "自动生成初始 UUID: $UUID"

  # ---------- 安装基础依赖 ----------
  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive   # 避免 apt 弹出交互界面
  apt-get update -y
  apt-get install -y curl gnupg lsb-release ca-certificates openssl dnsutils

  # ---------- 仅域名模式安装 Caddy ----------
  if [[ "$MODE" == "domain" ]]; then
    step "安装 Caddy"
    if ! command -v caddy >/dev/null 2>&1; then
      # 添加 Caddy 官方 GPG 密钥
      if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
          | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      fi
      # 添加 Caddy APT 源
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      apt-get update -y
      apt-get install -y caddy || apt-get install --reinstall -y caddy
    fi
    CADDY_BIN=$(command -v caddy)
    [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]] && error "Caddy 安装失败"
    info "Caddy: $($CADDY_BIN version)"
  fi

  # ---------- 安装 Xray ----------
  step "安装 Xray"
  if [[ ! -x /usr/local/bin/xray ]]; then
    # 使用官方一键安装脚本
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi

  # ---------- 端口占用检查 + 日志策略 ----------
  if [[ "$MODE" == "domain" ]]; then
    handle_common_occupiers
  else
    # IP 模式只检查目标端口是否被占用
    if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
      warn "端口 ${XRAY_PORT} 已被占用"
      ss -tlnp | grep -E ":${XRAY_PORT}\b" || true
      read -rp "是否继续？[y/N]: " C
      [[ "${C,,}" != "y" ]] && { info "已取消"; return; }
    fi
  fi
  configure_log_retention

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
    : > "$USERS_FILE"   # 清空或创建文件
    echo "${UUID}|default|初始用户" >> "$USERS_FILE"
    info "已创建默认用户 default"
  fi
  chmod 600 "$USERS_FILE"   # 仅 root 可读写

  # ---------- 保存安装信息到 info.txt ----------
  INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  cat > "$INFO_FILE" <<EOF
MODE="${MODE}"
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
    # Caddy 配置说明：
    #   srvh1 : 监听 80，将所有请求 301 跳转到 HTTPS
    #   srvh2 : 监听 127.0.0.1:8003，提供 TLS 伪装站，供 Xray Reality 回落
    cat > /etc/caddy/caddy.json <<EOF
{
  "apps": {
    "http": {
      "servers": {
        "srvh1": {
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
        "srvh2": {
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
          "issuers": [{"module": "acme", "email": "${EMAIL}"}]
        }]
      }
    }
  }
}
EOF
    # 校验 Caddy 配置
    "$CADDY_BIN" validate --config /etc/caddy/caddy.json >/dev/null 2>&1 \
      || error "Caddy 配置校验失败"
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
    cat > /etc/systemd/system/caddy-json.service <<EOF
[Unit]
Description=Caddy JSON Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
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

  # ---------- 域名模式启动 Caddy ----------
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
  systemctl is-active --quiet xray \
    && info "xray.service: 运行中" \
    || warn "xray 未运行"

  if [[ "$MODE" == "domain" ]]; then
    systemctl is-active --quiet caddy-json.service \
      && info "caddy-json: 运行中" \
      || warn "caddy 未运行 → journalctl -u caddy-json -n 50 --no-pager"
  fi

  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" \
    || warn "未发现端口 ${XRAY_PORT} 监听"

  echo
  show_client_info
  info "安装完成！"
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 二、卸载
# ============================================================================
do_uninstall() {
  if ! is_installed; then
    warn "尚未安装"
    read -rp "按回车返回..." _
    return
  fi

  echo
  load_kv "$INFO_FILE" 2>/dev/null || true
  warn "即将卸载（模式: ${MODE:-domain}）"
  read -rp "确认卸载？输入 yes 继续: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }

  # 停止并删除 Caddy 服务
  systemctl stop caddy-json.service 2>/dev/null || true
  systemctl disable caddy-json.service 2>/dev/null || true
  rm -f /etc/systemd/system/caddy-json.service

  # 停止并删除 Xray 服务
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  systemctl daemon-reload

  # 卸载 Caddy 软件包及残留
  dpkg -l 2>/dev/null | grep -q "^ii  caddy " && apt-get purge -y caddy || true
  rm -f /etc/apt/sources.list.d/caddy-stable.list
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  rm -rf /etc/caddy /var/lib/caddy

  # 使用官方脚本卸载 Xray
  [[ -f /usr/local/bin/xray ]] && \
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -rf /usr/local/etc/xray /var/log/xray

  # 可选：删除安装信息目录
  read -rp "删除 /etc/reality-caddy ? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -rf /etc/reality-caddy && info "已删除"

  # 可选：删除伪装站目录
  read -rp "删除伪装站 /var/www/html ? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -rf /var/www/html && info "已删除"

  info "卸载完成"
  read -rp "按回车返回..." _
}

# ============================================================================
# 三、查看状态
# ============================================================================
do_status() {
  clear
  if ! is_installed; then
    warn "尚未安装"
    read -rp "按回车返回..." _
    return
  fi

  load_kv "$INFO_FILE" 2>/dev/null || true
  step "服务状态"
  echo "模式: ${MODE:-domain}"
  if [[ "${MODE:-domain}" == "ip" ]]; then
    echo "IP: ${SERVER_IP:-未知}  |  伪装: ${DEST_DOMAIN:-未知}  |  端口: ${XRAY_PORT}"
  else
    echo "域名: ${DOMAIN:-未知}  |  端口: ${XRAY_PORT}"
  fi
  echo

  # Xray 状态
  systemctl status xray --no-pager -l | head -n 12 || true
  echo

  # 域名模式下显示 Caddy 状态
  if [[ "${MODE:-domain}" == "domain" ]]; then
    systemctl status caddy-json.service --no-pager -l | head -n 8 || true
    echo
  fi

  # 端口监听情况
  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" || echo "端口未监听"
  echo

  # 版本信息
  command -v xray >/dev/null && xray version | head -1
  read -rp "按回车返回..." _
}

# ============================================================================
# 四、显示客户端配置参数与分享链接
# ============================================================================
show_client_info() {
  load_kv "$INFO_FILE" || { warn "未找到 $INFO_FILE"; return 1; }

  local uuid="" email=""
  # 从用户列表中选择要查看的用户
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
      read -rp "选择用户编号 (默认 1): " SEL
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

  # 根据模式决定客户端连接地址和 SNI
  local ADDR SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    ADDR="${SERVER_IP}"
    SNI="${DEST_DOMAIN}"
  else
    ADDR="${DOMAIN}"
    SNI="${DOMAIN}"
  fi

  echo
  echo -e "${CYAN}==================== 客户端配置 ====================${NC}"
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
${CYAN}==================== 分享链接 ====================${NC}
vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email:-${ADDR}}
${CYAN}=================================================${NC}
EOF

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
    read -rp "按回车返回..." _
    return
  fi
  show_client_info || true
  echo
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 五、用户管理子菜单
# ============================================================================
users_menu() {
  if ! is_installed; then
    warn "尚未安装"
    read -rp "按回车返回..." _
    return
  fi
  while true; do
    clear
    echo -e "${CYAN}"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════╗
  ║   用户管理                                       ║
  ╠══════════════════════════════════════════════════╣
  ║   1) 列出用户                                    ║
  ║   2) 添加用户                                    ║
  ║   3) 删除用户                                    ║
  ║   4) 查看某用户分享链接                          ║
  ║   0) 返回主菜单                                  ║
  ╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    read -rp "请选择 [0-4]: " UC
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

# 打印用户列表（不暂停，供其他函数调用）
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

# 列出用户（带暂停）
users_list() {
  clear
  step "用户列表"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
  else
    users_list_noread
  fi
  echo
  read -rp "按回车返回..." _
}

# 添加用户
users_add() {
  clear
  step "添加用户"
  read -rp "用户标识 email (可空): " EMAIL
  read -rp "备注 note (可空): " NOTE
  # 未填写 email 时自动生成一个
  EMAIL=${EMAIL:-user$(date +%s)@local}

  local UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "${UUID}|${EMAIL}|${NOTE}" >> "$USERS_FILE"
  info "已添加: $EMAIL ($UUID)"

  # 重建配置并重启 Xray，使新用户生效
  if rebuild_xray_config; then
    systemctl restart xray
    info "Xray 已重启"
  else
    # 配置生成失败则回滚刚添加的行
    sed -i '$ d' "$USERS_FILE"
    warn "配置失败，已回滚"
  fi
  read -rp "按回车返回..." _
}

# 删除用户
users_del() {
  clear
  step "删除用户"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "按回车返回..." _
    return
  fi

  users_list_noread
  read -rp "输入要删除的用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; read -rp "按回车返回..." _; return; }

  local total
  total=$(grep -vcE '^\s*(#|$)' "$USERS_FILE" || true)
  (( IDX < 1 || IDX > total )) && { warn "编号越界"; read -rp "按回车返回..." _; return; }

  local target_email
  target_email=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p" | cut -d'|' -f2)
  read -rp "确认删除 $target_email ? [y/N]: " C
  [[ "${C,,}" != "y" ]] && { info "已取消"; return; }

  # 备份后按编号删除对应行
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
    # 失败则恢复备份
    cp "${USERS_FILE}.bak" "$USERS_FILE"
    warn "配置失败，已恢复"
  fi
  rm -f "${USERS_FILE}.bak"
  read -rp "按回车返回..." _
}

# 查看指定用户的分享链接
users_show() {
  clear
  step "查看某用户分享链接"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "按回车返回..." _
    return
  fi

  users_list_noread
  read -rp "输入用户编号: " IDX
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
  echo -e "${CYAN}==================== 用户 $email ====================${NC}"
  cat <<EOF
地址        : ${ADDR}
端口        : ${XRAY_PORT}
UUID        : ${uuid}
SNI         : ${SNI}
PublicKey   : ${PUBLIC_KEY}
ShortId     : ${SHORT_ID}
${CYAN}==================== 分享链接 ====================${NC}
vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email}
EOF
  echo
  read -rp "按回车返回..." _
}

# ============================================================================
# 主循环：显示菜单并根据用户选择调用对应功能
# ============================================================================
while true; do
  show_menu
  case "$CHOICE" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_status ;;
    4) do_show_client ;;
    5) users_menu ;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
done
