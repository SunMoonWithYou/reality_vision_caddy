#!/usr/bin/env bash
# ============================================================================
# Xray Reality + Vision / XHTTP 一键管理脚本
# ----------------------------------------------------------------------------
# 项目名称 : Xray Reality + Vision / XHTTP 一键管理脚本
# Xray 版本 : 固定 v26.6.27
# 支持系统 : Debian 11/12/13、Ubuntu 20.04/22.04/24.04
# 运行权限 : 必须以 root 用户执行
# ----------------------------------------------------------------------------
# 功能概览:
#   1. 安装服务
#      - 域名模式 : Xray (Reality + Vision 或 XHTTP) + Caddy 本地伪装站 + 自动申请证书
#                  默认监听 443；支持 HTTP-01 或 DNS-01 (Cloudflare)
#                  HTTP-01 会占用 80 端口；DNS-01 不占用 80，完全不影响现有 Web 服务
#      - IP 模式  : 仅安装 Xray (Reality + Vision 或 XHTTP)，无需域名、无需 Caddy
#                  默认监听 8443，需选择一个支持 TLS1.3 的真实网站作为伪装目标
#   2. 卸载服务   : 停止服务、删除配置，可选清理安装信息与伪装站
#   3. 查看状态   : 服务运行状态、端口监听、版本信息
#   4. 客户端参数 : 输出指定用户的 VLESS 分享链接与详细参数
#   5. 用户管理   : 列出 / 添加 / 删除用户，实时重建 Xray 配置并重启
#   6. 诊断自检   : 连不上时优先使用，只读检查，不修改任何配置
#   7. 流量统计   : 按月查看每个用户的长期累计流量（详细历史保留 1 年）
#                  支持每小时自动累计（systemd timer）
#   8. TG 日报    : 配置 Telegram Bot，每天 01:00 自动推送昨日流量日报
# ----------------------------------------------------------------------------
# 非交互模式:
#   ./脚本 --accumulate   供流量累计定时任务调用
#   ./脚本 --tg-report    供 Telegram 日报定时任务调用
# ============================================================================

set -euo pipefail   # 开启严格模式：遇错退出、未定义变量报错、管道失败即失败

# ----------------------------------------------------------------------------
# 终端颜色定义（ANSI 转义序列）
# ----------------------------------------------------------------------------
RED='\033[0;31m'      # 红色 - 错误
GREEN='\033[0;32m'    # 绿色 - 成功/信息
YELLOW='\033[1;33m'   # 黄色 - 警告
BLUE='\033[0;34m'     # 蓝色 - 步骤标题
CYAN='\033[0;36m'     # 青色 - 大标题框
DIM='\033[2m'         # 暗色 - 说明文字
BOLD='\033[1m'        # 粗体 - 小标题
NC='\033[0m'          # 重置颜色

# 标记 Go 是否由本脚本安装（决定编译完成后是否自动删除，避免误删用户自装的 Go）
GO_INSTALLED_BY_SCRIPT=0

# 信息输出函数
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# 步骤标题：圆角边框 + 箭头
step() {
  echo
  echo -e "${BLUE}  ╭─────────────────────────────────────────────────╮${NC}"
  echo -e "${BLUE}  │  ▶ $*${NC}"
  echo -e "${BLUE}  ╰─────────────────────────────────────────────────╯${NC}"
}

# 大标题横幅：双线框，内容居中对齐
banner() {
  echo -e "${CYAN}"
  echo -e "  ╔═════════════════════════════════════════════════╗"
  echo -e "  ║                                                 ║"
  printf  "  ║   %-45s ║\n" "$*"
  echo -e "  ║                                                 ║"
  echo -e "  ╚═════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# 菜单项输出：编号高亮 + 名称左对齐 + 说明暗色
# 用法: mi <编号> <名称> <说明>
mi() {
  printf "  ${GREEN}[%s]${NC}  %-14s  ${DIM}%s${NC}\n" "$1" "$2" "$3"
}

# 统一分隔线
line() {
  echo -e "  ─────────────────────────────────────────────────"
}

# ----------------------------------------------------------------------------
# 权限检查：必须 root 运行
# ----------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行，或先执行: sudo -i"

# ----------------------------------------------------------------------------
# 发行版检测：仅支持 Debian / Ubuntu 系列
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
# 全局变量与路径定义
# ----------------------------------------------------------------------------
USERS_FILE=/etc/reality-caddy/users.txt          # 用户列表文件 (uuid|email|note)
INFO_FILE=/etc/reality-caddy/info.txt            # 安装信息持久化文件
TRAFFIC_FILE=/etc/reality-caddy/traffic.json     # 长期流量累计文件
TG_CONF=/etc/reality-caddy/telegram.conf         # Telegram 配置文件
XRAY_CONF=/usr/local/etc/xray/config.json        # Xray 主配置文件路径
LOG_RETENTION_DAYS=7                             # 日志保留天数
CADDY_BIN=""                                     # Caddy 可执行文件路径（安装后赋值）
ACME_CHALLENGE=""                                # 证书验证方式：http 或 dns

# ----------------------------------------------------------------------------
# 支持非交互模式
#   ./脚本 --accumulate     供流量累计 timer 调用
#   ./脚本 --tg-report      供 Telegram 日报 timer 调用
# ----------------------------------------------------------------------------
if [[ "${1:-}" == "--accumulate" ]]; then
  ACCUMULATE_MODE=1
  TG_REPORT_MODE=0
elif [[ "${1:-}" == "--tg-report" ]]; then
  ACCUMULATE_MODE=0
  TG_REPORT_MODE=1
else
  ACCUMULATE_MODE=0
  TG_REPORT_MODE=0
fi

# IP 模式下内置候选伪装目标（真实大型网站，支持 TLS1.3）
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
  banner "Xray Reality + Vision / XHTTP  一键管理脚本"
  echo
  echo -e "  ${BOLD}功能菜单${NC}"
  line
  mi 1 "安装服务" "域名模式 / IP模式 一键部署"
  mi 2 "卸载服务" "停止并清理全部组件"
  mi 3 "查看状态" "服务运行状态与端口监听"
  mi 4 "查看参数" "输出客户端分享链接与详细配置"
  mi 5 "管理用户" "添加 / 删除 / 查看用户"
  mi 6 "诊断自检" "连不上时优先使用（只读）"
  mi 7 "流量统计" "按月查看用户累计流量"
  mi 8 "TG 日报" "配置 / 测试 Telegram 每日流量推送"
  line
  mi 0 "退出脚本" "安全退出"
  echo
  echo -e "  ${YELLOW}提示：连接异常时请先执行 [6] 诊断自检${NC}"
  echo
  read -rp "  请选择 [0-8]: " CHOICE
}

# ============================================================================
# 判断是否已安装过本方案
# 通过检查 info.txt 或 caddy-json.service 是否存在
# ============================================================================
is_installed() {
  [[ -f "$INFO_FILE" ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy-json.service"
}

# ============================================================================
# 安全读取 key=value 格式的配置文件
# 将文件中的 KEY=VALUE 自动赋值给同名变量
# 支持去除首尾引号，跳过空行和注释行
# ============================================================================
load_kv() {
  local FILE=$1
  [[ ! -f "$FILE" ]] && return 1
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | xargs)                    # 去除空白
    value=${value%\"}; value=${value#\"}          # 去除双引号
    value=${value%\'}; value=${value#\'}          # 去除单引号
    printf -v "$key" '%s' "$value"                # 动态赋值给变量
  done < "$FILE"
  return 0
}

# ============================================================================
# 根据 users.txt 生成 Xray clients JSON 数组
# 每行格式: uuid|email|note
# 输出带正确逗号分隔的 JSON 数组字符串
# ============================================================================
build_clients_json() {
  [[ ! -f "$USERS_FILE" ]] && { echo '[]'; return; }
  local first=1
  local use_flow=0
  [[ "${TRANSPORT:-tcp}" == "tcp" ]] && use_flow=1
  echo "["
  while IFS='|' read -r uuid email note; do
    [[ -z "$uuid" || "$uuid" =~ ^# ]] && continue
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '          {\n'
    printf '            "id": "%s",\n' "$uuid"
    printf '            "email": "%s",\n' "${email:-user@local}"
    printf '            "level": 0'
    if [[ $use_flow -eq 1 ]]; then
      printf ',\n            "flow": "xtls-rprx-vision"\n'
    else
      printf '\n'
    fi
    printf '          }'
  done < "$USERS_FILE"
  echo
  echo "        ]"
}

# ============================================================================
# 重建 Xray 主配置文件
# 根据当前 MODE（domain/ip）决定 REALITY 的 dest 和 serverNames
# 域名模式: dest 指向本地 Caddy (127.0.0.1:8003)
# IP 模式  : dest 指向用户选择的真实网站
# ============================================================================
rebuild_xray_config() {
  load_kv "$INFO_FILE" || error "未找到 $INFO_FILE，请先安装"
  mkdir -p "$(dirname "$XRAY_CONF")"

  local CLIENTS_JSON
  CLIENTS_JSON=$(build_clients_json)

  local REALITY_DEST REALITY_SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    # IP 模式：校验并探测伪装目标
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
    # 域名模式：流量最终落到本地 Caddy 伪装站
    REALITY_DEST="127.0.0.1:8003"
    REALITY_SNI="${DOMAIN}"
  fi

  # 写入完整 Xray 配置（已启用用户流量统计）
  local STREAM_SETTINGS
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    STREAM_SETTINGS=$(cat <<EOS
        "network": "xhttp",
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
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH:-/xhttp}",
          "mode": "auto"
        }
EOS
)
  else
    STREAM_SETTINGS=$(cat <<EOS
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
EOS
)
  fi

  cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:10085",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": ${CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
${STREAM_SETTINGS}
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

  # 配置语法校验
  if ! xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "Xray 配置校验失败，输出："
    xray -test -config "$XRAY_CONF" || true
    return 1
  fi
  return 0
}

# ============================================================================
# 自动放行本机防火墙端口
# 按优先级检测 firewalld → ufw → iptables
# 只放行 TCP 协议
# ============================================================================
open_firewall_port() {
  local ports=("$@")
  local opened=0

  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld: 已放行 TCP ${ports[*]}"
    opened=1
  fi

  # ufw
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

  # 裸 iptables（最后手段，重启可能丢失）
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
# 打印端口放行提醒（云厂商安全组 + 本机防火墙）
# ============================================================================
print_port_notice() {
  local mode=$1
  local port=$2

  echo
  echo -e "${YELLOW}  ╭──────────────────── 端口放行提醒 ────────────────────╮${NC}"
  if [[ "$mode" == "ip" ]]; then
    echo -e "  │  必须放行：${CYAN}TCP ${port}${NC}（Xray 监听端口）"
  else
    if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
      echo -e "  │  必须放行：${CYAN}TCP 80${NC}（ACME HTTP-01 申请/续期证书）"
    else
      echo -e "  │  无需放行：TCP 80（当前使用 DNS-01 验证，Caddy 不监听 80）"
    fi
    echo -e "  │            ${CYAN}TCP ${port}${NC}（Xray 监听端口，默认 443）"
  fi
  echo -e "  │  操作位置：云厂商控制台 → 安全组 / 防火墙 入站规则"
  echo -e "  │            以及服务器本机防火墙（ufw / firewalld）"
  echo -e "  │  提示    ：端口未放行时，客户端会连接超时或 TLS 握手失败"
  echo -e "${YELLOW}  ╰──────────────────────────────────────────────────────╯${NC}"
}

# ============================================================================
# 处理常见 Web 服务端口占用
# HTTP-01 模式：需要 80 端口，会主动停止 nginx/apache/caddy
# DNS-01 模式：完全不动 80 端口上的任何服务，只检查 Xray 端口
# ============================================================================
handle_common_occupiers() {
  step "检测并处理常见端口占用"

  if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
    # HTTP-01：清理 80/443 上的常见服务
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
    # DNS-01：不动 80，只检查 Xray 端口
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
# 配置 systemd 日志与 Xray 日志的保留策略
# 防止日志无限增长占满磁盘
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

  # Xray 日志目录 + tmpfiles 清理规则
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
# 去除协议前缀、路径、端口、末尾点号
# 拒绝纯 IP 地址和不合法域名格式
# ============================================================================
normalize_dest() {
  local raw=$1
  raw=$(echo "$raw" | tr -d ' \t\r\n')
  raw=${raw#http://}
  raw=${raw#https://}
  raw=${raw%%/*}
  raw=${raw%%:*}
  raw=${raw%.}

  # 拒绝纯 IP
  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  # 简单域名合法性校验
  if [[ ! "$raw" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    return 1
  fi
  echo "$raw"
  return 0
}

# ============================================================================
# 真实 TLS 1.3 握手探测
# 使用 openssl s_client 检测目标是否支持 TLS1.3
# 返回 0 = 可用，1 = 不可用
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

  # 成功检测到 TLS1.3
  if echo "$out" | grep -qiE 'Protocol version: *TLSv1\.3|Protocol  *: *TLSv1\.3'; then
    if echo "$out" | grep -qiE 'Verification: *OK|Verify return code: *0'; then
      return 0
    fi
    return 0   # 即使证书验证失败也认为握手成功（很多站点证书链问题不影响 REALITY）
  fi

  # 明确失败信号
  if echo "$out" | grep -qiE 'alert|handshake failure|no protocols|timeout|Connection refused|connect:errno'; then
    return 1
  fi
  [[ -z "$out" ]] && return 1
  return 1
}

# ============================================================================
# 批量探测候选目标（预留函数，当前未直接调用）
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
# IP 模式：交互式选择伪装目标域名
# 1. 先实测内置候选列表
# 2. 只展示握手成功的目标
# 3. 支持自定义输入
# ============================================================================
choose_dest_domain() {
  echo
  step "实测候选伪装目标（TLS1.3 握手探测）"
  echo -e "  说明：只有握手正常的目标才能作为 dest，否则客户端会连上即断。"
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

  echo -e "  ${BLUE}▶ 请选择伪装目标域名${NC}  ${DIM}(仅显示实测通过的)${NC}"
  line
  local i=1
  for d in "${GOOD[@]}"; do
    printf "  ${GREEN}[%d]${NC}  %s\n" "$i" "$d"
    ((i++))
  done
  printf "  ${GREEN}[%d]${NC}  自定义输入\n" "$i"
  line
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
# 服务器出网连通性自检
# 测试几个知名站点，成功数超过一半即判定出网正常
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
# 检查 Caddy 是否已成功为指定域名签发证书
# 优先检查证书文件，其次检查 journal 日志关键词
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
# 获取服务器公网 IPv4 地址
# 依次尝试多个公共服务，返回第一个合法结果
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
# 使用 xray x25519 生成 Reality 密钥对
# 兼容不同版本 xray 的输出格式
# 同时生成 8 字节随机 ShortId
# ============================================================================
generate_reality_keys() {
  local out
  out=$(xray x25519 2>/dev/null)

  local tmp
  tmp=($(echo "$out" | sed 's/.*://'))
  PRIVATE_KEY=${tmp[0]:-}
  PUBLIC_KEY=${tmp[1]:-}

  # 兼容旧版输出格式
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
# 一、安装主流程
# ============================================================================
do_install() {
  local KEEP_USERS=0

  # ---------- 已安装检测与重装选项 ----------
  if is_installed; then
    clear
    banner "检测到已安装"
    echo
    if [[ -f "$INFO_FILE" ]]; then
      load_kv "$INFO_FILE"
      echo -e "  ${BOLD}当前配置${NC}"
      line
      echo -e "  模式      : ${MODE:-domain}"
      echo -e "  传输      : ${TRANSPORT:-tcp}"
      if [[ "${MODE:-domain}" == "ip" ]]; then
        echo -e "  服务器IP  : ${SERVER_IP:-未知}"
        echo -e "  伪装域名  : ${DEST_DOMAIN:-未知}"
      else
        echo -e "  域名      : ${DOMAIN:-未知}"
        echo -e "  验证方式  : ${ACME_CHALLENGE:-http}"
      fi
      echo -e "  端口      : ${XRAY_PORT:-未知}"
      echo -e "  安装时间  : ${INSTALL_TIME:-未知}"
      echo -e "  用户数量  : $(grep -vcE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null || echo 0)"
      line
      echo
    fi
    mi 1 "覆盖重装" "保留现有用户列表"
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
  echo
  mi 1 "域名模式" "自有域名 + Caddy 伪装站 + 自动证书（推荐 443）"
  mi 2 "IP 模式"  "免域名免 Caddy，直接使用公网 IP（推荐 8443）"
  echo
  read -rp "  请选择 [1-2] (默认 1): " MODE_SEL
  MODE_SEL=${MODE_SEL:-1}
  case "$MODE_SEL" in
    1) MODE="domain" ;;
    *) MODE="ip" ;;
  esac
  info "已选择: $([ "$MODE" = "ip" ] && echo "IP模式" || echo "域名模式")"

  # ---------- 选择传输方式 ----------
  step "选择传输方式"
  echo
  mi 1 "TCP + Vision" "经典 Reality + Vision 流控（推荐，性能最好）"
  mi 2 "XHTTP"        "XHTTP 传输（更现代，抗检测更好，可过部分中间盒）"
  echo
  read -rp "  请选择 [1-2] (默认 1): " TRANS_SEL
  TRANS_SEL=${TRANS_SEL:-1}
  if [[ "$TRANS_SEL" == "2" ]]; then
    TRANSPORT="xhttp"
    # 生成随机路径（XHTTP 必须）
    XHTTP_PATH="/$(openssl rand -hex 12)"
    info "已选择: XHTTP 传输，路径: ${XHTTP_PATH}"
  else
    TRANSPORT="tcp"
    XHTTP_PATH=""
    info "已选择: TCP + Vision"
  fi

  # ---------- 参数收集 ----------
  step "参数配置"
  if [[ "$MODE" == "ip" ]]; then
    # IP 模式参数
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
    # 域名模式参数
    read -rp "  请输入你的域名 (例如: example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空"

    # 先选择证书验证方式
    echo
    echo -e "  ${BLUE}▶ 证书验证方式${NC}"
    line
    mi 1 "HTTP 验证" "HTTP-01，需占用 80 端口，配置最简单"
    mi 2 "DNS 验证"  "DNS-01，不占用 80，走 Cloudflare API"
    line
    echo
    read -rp "  请选择 [1-2] (默认 1): " ACME_CHALLENGE_SEL
    ACME_CHALLENGE_SEL=${ACME_CHALLENGE_SEL:-1}
    if [[ "$ACME_CHALLENGE_SEL" == "2" ]]; then
      ACME_CHALLENGE="dns"
    else
      ACME_CHALLENGE="http"
    fi

    # 根据验证方式处理邮箱
    # 注意：Let's Encrypt 禁止使用 example.com 等保留域名的邮箱注册 ACME 账号
    # (HTTP 400 invalidContact: forbidden domain)，会导致证书签发失败。
    # 两种模式均需用户手动输入邮箱，并校验格式与保留域名。
    read -rp "  请输入用于 ACME 的邮箱 (如 admin@${DOMAIN}): " EMAIL
    [[ -z "$EMAIL" ]] && error "邮箱不能为空"
    if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
      error "邮箱格式不合法: $EMAIL"
    fi
    if [[ "$EMAIL" =~ @(example\.com|example\.org|example\.net)$ ]]; then
      error "Let's Encrypt 禁止使用 example.com/org/net 域名的邮箱（invalidContact），请换一个"
    fi
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      info "DNS-01 模式：使用邮箱 ${EMAIL} 注册 ACME 账号"
    fi

    read -rp "  请输入伪装站标题 (默认: Welcome): " SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-Welcome}
    read -rp "  请输入 Xray 监听端口 (默认 443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}
    SERVER_IP=""
    DEST_DOMAIN=""

    # DNS-01 需要 Cloudflare API Token
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
      # 简单格式预检
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

  # 域名解析预检（仅域名模式）
  if [[ "$MODE" == "domain" ]] && command -v dig >/dev/null 2>&1; then
    RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
    [[ -z "$RESOLVED_IP" ]] && warn "域名解析失败，证书申请可能不成功"
  fi

  # 生成初始用户 UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)
  info "自动生成初始 UUID: $UUID"

  # ---------- 安装基础依赖 ----------
  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl gnupg lsb-release ca-certificates openssl dnsutils

  # ---------- 域名模式安装 Caddy ----------
  if [[ "$MODE" == "domain" ]]; then
    step "安装 Caddy"
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      # DNS-01 需要带 cloudflare 插件的自定义 Caddy
      info "DNS-01 模式：将使用 xcaddy 构建带 Cloudflare 插件的 Caddy"

      # 安装足够新的 Go
      if ! command -v go >/dev/null 2>&1 || ! go version 2>/dev/null | grep -qE 'go1\.(2[1-9]|[3-9][0-9])'; then
        info "安装 Go 1.22（官方二进制）"
        GO_INSTALLED_BY_SCRIPT=1
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
      XCADDY_INSTALLED_BY_SCRIPT=0
      if ! command -v xcaddy >/dev/null 2>&1; then
        info "安装 xcaddy"
        XCADDY_INSTALLED_BY_SCRIPT=1
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

      # ---------- 清理编译工具链 ----------
      # Caddy 二进制为静态编译，运行不依赖 Go；Go/xcaddy/缓存仅编译时需要，用完即删。
      # 仅删除本脚本安装的部分，避免误删用户原有环境。
      step "清理编译工具（Go / xcaddy / 构建缓存）"
      local _GOPATH _GOCACHE
      _GOPATH="$(go env GOPATH 2>/dev/null || echo '')"
      _GOCACHE="$(go env GOCACHE 2>/dev/null || echo '')"
      if [[ "$XCADDY_INSTALLED_BY_SCRIPT" == "1" ]]; then
        rm -f "${_GOPATH}/bin/xcaddy" 2>/dev/null || true
      fi
      if [[ "$GO_INSTALLED_BY_SCRIPT" == "1" ]]; then
        rm -rf /usr/local/go
        [[ -n "${_GOPATH}" && "${_GOPATH}" != "$HOME" ]] && rm -rf "${_GOPATH}"
        [[ -n "${_GOCACHE}" ]] && rm -rf "${_GOCACHE}"
        hash -r 2>/dev/null || true
        info "已删除 Go 工具链、xcaddy 及构建缓存"
      else
        info "检测到 Go 为系统原有环境，保留不动"
      fi
      info "清理完成，仅保留编译好的 Caddy 二进制（$CADDY_BIN）"
    else
      # HTTP-01 使用官方 apt 包即可
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
  step "安装 Xray v26.6.27"
  info "正在安装指定版本 Xray v26.6.27 ..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version v26.6.27

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

  # ---------- 放行防火墙端口 ----------
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

  # ---------- 持久化安装信息 ----------
  INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  cat > "$INFO_FILE" <<EOF
MODE="${MODE}"
TRANSPORT="${TRANSPORT:-tcp}"
XHTTP_PATH="${XHTTP_PATH:-}"
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

  # ---------- 域名模式：配置 Caddy + 伪装站 ----------
  if [[ "$MODE" == "domain" ]]; then
    step "配置 Caddy"
    mkdir -p /etc/caddy

    # 根据验证方式生成 issuers 配置
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

    # HTTP-01 需要 :80 跳转；DNS-01 关闭自动跳转避免抢占 80
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

    # 校验配置（DNS 模式需注入环境变量）
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

    # 创建简单伪装站点
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

    # 配置 systemd 服务
    step "配置 Caddy systemd 服务"

    local ENVFILE_LINE=""
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > /etc/caddy/caddy.env
      chmod 600 /etc/caddy/caddy.env
      chown root:root /etc/caddy/caddy.env
      ENVFILE_LINE="EnvironmentFile=/etc/caddy/caddy.env"
      info "API Token 已写入 /etc/caddy/caddy.env（权限 600）"
      unset CF_API_TOKEN   # 尽快从内存清除
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

  # ---------- 生成并启动 Xray ----------
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
      if ss -tln 2>/dev/null | grep -qE ':80\b' && ss -tlnp 2>/dev/null | grep ':80\b' | grep -q caddy; then
        warn "检测到 Caddy 正在监听 80 端口，与 DNS-01 模式预期不符"; SELFCHECK_FAIL=1
      else
        info "确认 Caddy 未监听 80 端口"
      fi

      # 等待证书真正签发（最长 120 秒）
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

  # 启用自动流量累计定时任务
  setup_traffic_timer

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

  # 停止并禁用服务
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  if [[ "$MODE" == "domain" ]]; then
    systemctl stop caddy-json.service 2>/dev/null || true
    systemctl disable caddy-json.service 2>/dev/null || true
    rm -f /etc/systemd/system/caddy-json.service
  fi
  systemctl daemon-reload

  # 清理 Caddy 相关
  if [[ "$MODE" == "domain" ]] || [[ -d /etc/caddy ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy.service"; then
    if dpkg -l 2>/dev/null | grep -q "^ii  caddy "; then
      info "卸载 Caddy 软件包"
      apt-get purge -y caddy || true
    fi
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -rf /etc/caddy /var/lib/caddy

    rm -f /usr/local/bin/caddy
    # 清理 Go/xcaddy 编译残留（新版脚本装完即删，此处兜底清理旧版残留）
    rm -rf /root/.cache/go-build 2>/dev/null || true
    if command -v go >/dev/null 2>&1; then
      rm -f "$(go env GOPATH)/bin/xcaddy" 2>/dev/null || true
    else
      rm -rf /root/go 2>/dev/null || true
      rm -rf /usr/local/go 2>/dev/null || true
    fi
    info "Caddy 相关文件已清理"
  fi

  # 清理 Xray
  [[ -f /usr/local/bin/xray ]] && \
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -rf /usr/local/etc/xray /var/log/xray

  # 可选清理安装信息与伪装站
  read -rp "删除 /etc/reality-caddy ? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -rf /etc/reality-caddy && info "已删除"

  if [[ "$MODE" == "domain" && -d /var/www/html ]]; then
    read -rp "删除伪装站 /var/www/html ? [y/N]: " DEL
    [[ "${DEL,,}" == "y" ]] && rm -rf /var/www/html && info "已删除"
  fi

  # 清理流量定时任务
  systemctl disable --now xray-traffic-accumulate.timer 2>/dev/null || true
  systemctl disable --now xray-traffic-accumulate.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray-traffic-accumulate.service \
        /etc/systemd/system/xray-traffic-accumulate.timer

  # 清理 Telegram 日报定时任务
  systemctl disable --now xray-tg-report.timer 2>/dev/null || true
  systemctl disable --now xray-tg-report.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray-tg-report.service \
        /etc/systemd/system/xray-tg-report.timer

  systemctl daemon-reload 2>/dev/null || true

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
  banner "服务状态"
  echo
  echo -e "  ${BOLD}基本信息${NC}"
  line
  echo -e "  模式      : ${MODE:-domain}"
  echo -e "  传输      : ${TRANSPORT:-tcp}"
  if [[ "${MODE:-domain}" == "ip" ]]; then
    echo -e "  服务器IP  : ${SERVER_IP:-未知}"
    echo -e "  伪装域名  : ${DEST_DOMAIN:-未知}"
  else
    echo -e "  域名      : ${DOMAIN:-未知}"
    echo -e "  验证方式  : ${ACME_CHALLENGE:-http}"
  fi
  echo -e "  端口      : ${XRAY_PORT}"
  line
  echo

  step "Xray 服务"
  systemctl status xray --no-pager -l | head -n 12 || true
  echo

  if [[ "${MODE:-domain}" == "domain" ]]; then
    step "Caddy 服务"
    systemctl status caddy-json.service --no-pager -l | head -n 8 || true
    echo
  fi

  step "端口监听"
  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" || echo "  端口未监听"
  echo

  command -v xray >/dev/null && xray version | head -1

  print_port_notice "${MODE:-domain}" "${XRAY_PORT}"
  read -rp "  按回车返回..." _
}

# ============================================================================
# 四、显示客户端参数（内部可复用）
# ============================================================================
show_client_info() {
  load_kv "$INFO_FILE" || { warn "未找到 $INFO_FILE"; return 1; }

  local uuid="" email=""
  if [[ -f "$USERS_FILE" ]]; then
    echo
    echo -e "  ${BOLD}可用用户${NC}"
    line
    local i=1
    local -a UUIDS=() EMAILS=()
    while IFS='|' read -r u e n; do
      [[ -z "$u" || "$u" =~ ^# ]] && continue
      UUIDS+=("$u")
      EMAILS+=("$e")
      printf "  %d) %-24s  %s  %s\n" "$i" "$e" "$u" "${n:-}"
      ((i++))
    done < "$USERS_FILE"
    line

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
  echo -e "  模式        : ${MODE:-domain}"
  echo -e "  协议        : VLESS"
  echo -e "  地址        : ${ADDR}"
  echo -e "  端口        : ${XRAY_PORT}"
  echo -e "  UUID        : ${uuid}"
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    echo -e "  传输        : xhttp"
    echo -e "  路径        : ${XHTTP_PATH:-/xhttp}"
    echo -e "  模式        : auto"
  else
    echo -e "  流控        : xtls-rprx-vision"
    echo -e "  传输        : tcp"
  fi
  echo -e "  安全        : reality"
  echo -e "  SNI         : ${SNI}"
  echo -e "  Fingerprint : chrome"
  echo -e "  PublicKey   : ${PUBLIC_KEY}"
  echo -e "  ShortId     : ${SHORT_ID}"
  echo
  echo -e "${CYAN}  ╭───────────────── 分享链接 ─────────────────╮${NC}"
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    local path_enc
    path_enc=$(printf '%s' "${XHTTP_PATH:-/xhttp}" | sed 's|/|%2F|g')
    echo "  vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${path_enc}&mode=auto#Reality-XHTTP-${email:-${ADDR}}"
  else
    echo "  vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email:-${ADDR}}"
  fi
  echo -e "${CYAN}  ╰────────────────────────────────────────────╯${NC}"

  if [[ "${MODE:-domain}" == "domain" ]]; then
    echo -e "  伪装站点    : https://${DOMAIN}"
  else
    echo -e "  伪装目标    : ${DEST_DOMAIN}"
  fi
}

# 对外入口：查看参数
do_show_client() {
  clear
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi
  banner "客户端参数"
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
    echo
    echo -e "  ${BOLD}用户操作${NC}"
    line
    mi 1 "列出用户" "显示所有已添加用户"
    mi 2 "添加用户" "生成新 UUID 并写入配置"
    mi 3 "删除用户" "按编号删除指定用户"
    mi 4 "查看链接" "输出指定用户的分享链接"
    line
    mi 0 "返回菜单" "返回主菜单"
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

# 仅输出用户列表（无等待）
users_list_noread() {
  printf "  %-4s %-40s %-24s %s\n" "No." "UUID" "标识" "备注"
  line
  local i=1
  while IFS='|' read -r u e n; do
    [[ -z "$u" || "$u" =~ ^# ]] && continue
    printf "  %-4s %-40s %-24s %s\n" "$i" "$u" "$e" "${n:-}"
    ((i++))
  done < "$USERS_FILE"
}

users_list() {
  clear
  banner "用户列表"
  echo
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
  banner "添加用户"
  echo
  read -rp "  用户标识 email (可空): " EMAIL
  read -rp "  备注 note (可空): " NOTE
  EMAIL=${EMAIL:-user$(date +%s)@local}

  local UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "${UUID}|${EMAIL}|${NOTE}" >> "$USERS_FILE"
  info "已添加: $EMAIL ($UUID)"

  if rebuild_xray_config; then
    systemctl restart xray
    info "Xray 已重启"
  else
    sed -i '$ d' "$USERS_FILE"   # 回滚最后一行
    warn "配置失败，已回滚"
  fi
  read -rp "  按回车返回..." _
}

users_del() {
  clear
  banner "删除用户"
  echo
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "  按回车返回..." _
    return
  fi

  users_list_noread
  echo
  read -rp "  输入要删除的用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; read -rp "  按回车返回..." _; return; }

  local total
  total=$(grep -vcE '^\s*(#|$)' "$USERS_FILE" || true)
  (( IDX < 1 || IDX > total )) && { warn "编号越界"; read -rp "  按回车返回..." _; return; }

  local target_email
  target_email=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p" | cut -d'|' -f2)
  read -rp "确认删除 $target_email ? [y/N]: " C
  [[ "${C,,}" != "y" ]] && { info "已取消"; return; }

  # 备份后按行号删除
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
  banner "查看用户链接"
  echo
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
    read -rp "  按回车返回..." _
    return
  fi

  users_list_noread
  echo
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
  echo -e "  地址        : ${ADDR}"
  echo -e "  端口        : ${XRAY_PORT}"
  echo -e "  UUID        : ${uuid}"
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    echo -e "  传输        : xhttp"
    echo -e "  路径        : ${XHTTP_PATH:-/xhttp}"
  else
    echo -e "  流控        : xtls-rprx-vision"
    echo -e "  传输        : tcp"
  fi
  echo -e "  SNI         : ${SNI}"
  echo -e "  PublicKey   : ${PUBLIC_KEY}"
  echo -e "  ShortId     : ${SHORT_ID}"
  echo
  echo -e "${CYAN}  ╭───────────────── 分享链接 ─────────────────╮${NC}"
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    local path_enc
    path_enc=$(printf '%s' "${XHTTP_PATH:-/xhttp}" | sed 's|/|%2F|g')
    echo "  vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${path_enc}&mode=auto#Reality-XHTTP-${email}"
  else
    echo "  vless://${uuid}@${ADDR}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email}"
  fi
  echo -e "${CYAN}  ╰────────────────────────────────────────────╯${NC}"
  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 六、诊断自检（只读，不修改任何配置）
# ============================================================================
do_diagnose() {
  clear
  banner "诊断自检"
  if [[ ! -f "$INFO_FILE" ]]; then
    warn "未找到 $INFO_FILE，可能尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  local MODE="" XRAY_PORT="" DEST_DOMAIN="" DOMAIN="" PUBLIC_KEY="" SHORT_ID="" PRIVATE_KEY="" ACME_CHALLENGE=""
  load_kv "$INFO_FILE" 2>/dev/null || true

  echo
  echo -e "  ${BOLD}基本信息${NC}"
  line
  echo -e "  模式      : ${MODE:-未知}"
  echo -e "  传输      : ${TRANSPORT:-tcp}"
  echo -e "  端口      : ${XRAY_PORT:-未知}"
  [[ "$MODE" == "ip" ]] && echo -e "  伪装目标  : ${DEST_DOMAIN:-未知}"
  [[ "$MODE" == "domain" ]] && echo -e "  验证方式  : ${ACME_CHALLENGE:-http}"
  line

  echo
  echo -e "  ${BOLD}[1] 服务状态${NC}"
  systemctl is-active --quiet xray && info "xray 运行中" || warn "xray 未运行"
  [[ "$MODE" == "domain" ]] && {
    systemctl is-active --quiet caddy-json.service && info "caddy-json 运行中" || warn "caddy-json 未运行"
  }

  echo
  echo -e "  ${BOLD}[2] 端口监听${NC}"
  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" | sed 's/^/  /' \
    || warn "端口 ${XRAY_PORT} 未监听"

  echo
  echo -e "  ${BOLD}[3] 服务器出网${NC}"
  check_outbound || warn "出网受限：客户端会『连上但没网』"

  if [[ "$MODE" == "ip" && -n "$DEST_DOMAIN" ]]; then
    echo
    echo -e "  ${BOLD}[4] 伪装目标 ${DEST_DOMAIN} 的 TLS1.3 握手${NC}"
    if probe_dest_tls "$DEST_DOMAIN" 443; then
      info "握手正常"
    else
      warn "握手异常！这是 IP 模式『连上即断』的典型原因，请换目标重新安装"
      echo "     手工确认：openssl s_client -connect ${DEST_DOMAIN}:443 -servername ${DEST_DOMAIN} -tls1_3 -brief"
    fi
  fi

  echo
  echo -e "  ${BOLD}[5] 密钥${NC}"
  echo -e "  PublicKey: ${PUBLIC_KEY:-空}  (长度 ${#PUBLIC_KEY})"
  echo -e "  ShortId  : ${SHORT_ID:-空}"
  [[ ${#PUBLIC_KEY} -lt 40 ]] && warn "PublicKey 长度异常，客户端会失败"
  if command -v xray >/dev/null 2>&1 && [[ -n "${PRIVATE_KEY:-}" ]]; then
    local calc
    calc=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -iE 'public|password' | awk '{print $NF}' | head -1)
    if [[ -n "$calc" ]]; then
      [[ "$calc" == "$PUBLIC_KEY" ]] && info "公私钥配对正确" || warn "公私钥不配对！请重建密钥"
    fi
  fi

  echo
  echo -e "  ${BOLD}[6] 证书验证方式${NC}"
  echo -e "  方式: ${ACME_CHALLENGE:-http}"
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
    if ss -tlnp 2>/dev/null | grep ':80\b' | grep -q caddy; then
      warn "Caddy 正在监听 80，与 DNS-01 预期不符"
    else
      info "Caddy 未监听 80"
    fi
    if check_cert_obtained "${DOMAIN:-}"; then
      info "证书已签发（DNS-01 正常）"
    else
      warn "未找到已签发的证书，DNS-01 申请可能失败"
      warn "请检查: journalctl -u caddy-json -n 100 --no-pager"
      warn "并确认 caddy.json 中 cloudflare provider 含 \"api_token\": \"{env.CF_API_TOKEN}\""
    fi
  fi

  echo
  echo -e "  ${BOLD}[7] 客户端必须核对的三项${NC}"
  if [[ "$MODE" == "ip" ]]; then
    echo -e "  地址/SNI : 地址填 IP，SNI 必须填 ${DEST_DOMAIN}（不能填 IP）"
  else
    echo -e "  地址/SNI : 都填 ${DOMAIN}"
  fi
  echo -e "  PublicKey: 必须是本机 info.txt 里的值（换模式后旧值会失效）"
  echo -e "  ShortId  : 同上，不能沿用旧节点的"

  echo
  echo -e "  ${BOLD}[8] xray 近期错误日志${NC}"
  journalctl -u xray -n 100 --no-pager 2>/dev/null \
    | grep -iE "rejected|invalid|failed|refused|timeout|no route|address already" \
    | tail -8 | sed 's/^/  /' || echo "  无明显错误"

  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 七、用户流量统计（长期累计）
# ============================================================================
# ============================================================================
# 流量统计菜单
# 先调用累计函数把内存中的增量写入文件，再按月聚合显示，并显示总累计
# 显示时优先使用 users.txt 中的备注字段
# ============================================================================
do_traffic() {
  clear
  banner "用户流量统计（按月）"
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  load_kv "$INFO_FILE" 2>/dev/null || true

  # 检查是否已启用统计
  if ! grep -q '"stats"' "$XRAY_CONF" 2>/dev/null; then
    warn "当前 Xray 配置未启用流量统计"
    echo
    read -rp "  是否现在重建配置并重启 Xray 以启用？[y/N]: " C
    if [[ "${C,,}" == "y" ]]; then
      if rebuild_xray_config; then
        systemctl restart xray
        info "配置已重建，Xray 已重启。请等待几秒后重新查看流量。"
      else
        warn "配置重建失败"
      fi
    fi
    read -rp "  按回车返回..." _
    return
  fi

  if ! systemctl is-active --quiet xray; then
    warn "xray 服务未运行"
    read -rp "  按回车返回..." _
    return
  fi

  local API_ADDR="127.0.0.1:10085"
  info "正在查询并累计流量数据..."

  # 先执行一次累计（带 reset）
  accumulate_traffic_silent || warn "本次累计可能失败，将显示上次保存的数据"

  echo
  echo -e "  ${BOLD}用户流量统计（按月汇总，详细历史保留 1 年）${NC}"
  line

  if command -v python3 >/dev/null 2>&1 && [[ -f "$TRAFFIC_FILE" ]]; then
    python3 - "$TRAFFIC_FILE" "$USERS_FILE" <<'PY'
import json, sys, os
from collections import defaultdict

traffic_file = sys.argv[1]
users_file = sys.argv[2]

try:
    with open(traffic_file) as f:
        store = json.load(f)
except Exception:
    print("  读取数据文件失败")
    sys.exit(0)

cumulative = store.get("cumulative", {})
daily = store.get("daily", [])
meta = store.get("_meta", {})

known = []
email_to_note = {}
if os.path.isfile(users_file):
    with open(users_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) >= 2:
                email = parts[1]
                note = parts[2] if len(parts) >= 3 else ""
                known.append(email)
                email_to_note[email] = note.strip() if note.strip() else email

def display_name(email):
    return email_to_note.get(email, email)

def fmt(b):
    b = int(b or 0)
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KB"
    elif b < 1024**3:
        return f"{b/1024**2:.1f} MB"
    else:
        return f"{b/1024**3:.2f} GB"

# ---------- 按月聚合 ----------
# month -> email -> {up, down}
monthly = defaultdict(lambda: defaultdict(lambda: {"uplink": 0, "downlink": 0}))
for rec in daily:
    date = rec.get("date", "")
    if len(date) < 7:
        continue
    month = date[:7]  # YYYY-MM
    for email, d in rec.get("users", {}).items():
        monthly[month][email]["uplink"] += d.get("uplink", 0)
        monthly[month][email]["downlink"] += d.get("downlink", 0)

months = sorted(monthly.keys(), reverse=True)

def display_width(s):
    """计算字符串在终端的显示宽度（中文算 2）"""
    w = 0
    for c in str(s):
        w += 2 if ord(c) > 127 else 1
    return w

def pad(s, width, align="left"):
    s = str(s)
    dw = display_width(s)
    pad_len = max(0, width - dw)
    if align == "right":
        return " " * pad_len + s
    return s + " " * pad_len

# 固定列宽
COL_NAME = 20
COL_NUM = 12

print("  【按月统计】")
print()
if not months:
    print("  暂无月度数据")
else:
    for month in months:
        print(f"  ── {month} ──")
        header = f"    {pad('备注', COL_NAME)} {pad('上行', COL_NUM, 'right')} {pad('下行', COL_NUM, 'right')} {pad('总计', COL_NUM, 'right')}"
        print(header)
        m_up = m_down = 0
        # 只显示有流量的用户，按总流量从高到低排序
        users_in_month = [e for e in monthly[month].keys()
                          if monthly[month][e]["uplink"] + monthly[month][e]["downlink"] > 0]
        users_in_month.sort(key=lambda e: -(monthly[month][e]["uplink"] + monthly[month][e]["downlink"]))
        for e in users_in_month:
            up = monthly[month][e]["uplink"]
            down = monthly[month][e]["downlink"]
            total = up + down
            m_up += up
            m_down += down
            name = display_name(e)
            print(f"    {pad(name, COL_NAME)} {pad(fmt(up), COL_NUM, 'right')} {pad(fmt(down), COL_NUM, 'right')} {pad(fmt(total), COL_NUM, 'right')}")
        if users_in_month:
            print("    " + "─" * (COL_NAME + COL_NUM * 3 + 3))
            print(f"    {pad('本月合计', COL_NAME)} {pad(fmt(m_up), COL_NUM, 'right')} {pad(fmt(m_down), COL_NUM, 'right')} {pad(fmt(m_up + m_down), COL_NUM, 'right')}")
        else:
            print("    本月无流量")
        print()

# ---------- 总累计 ----------
print("  【总累计（自安装以来）】")
print()
active_emails = [e for e in set(list(cumulative.keys()) + known)
                 if cumulative.get(e, {}).get("uplink", 0) + cumulative.get(e, {}).get("downlink", 0) > 0]
active_emails.sort(key=lambda e: -(cumulative.get(e, {}).get("uplink", 0) + cumulative.get(e, {}).get("downlink", 0)))
print(f"  {pad('备注', COL_NAME)} {pad('上行', COL_NUM, 'right')} {pad('下行', COL_NUM, 'right')} {pad('总计', COL_NUM, 'right')}")
print("  " + "─" * (COL_NAME + COL_NUM * 3 + 3))
total_up = total_down = 0
for e in active_emails:
    up = cumulative.get(e, {}).get("uplink", 0)
    down = cumulative.get(e, {}).get("downlink", 0)
    total = up + down
    total_up += up
    total_down += down
    name = display_name(e)
    print(f"  {pad(name, COL_NAME)} {pad(fmt(up), COL_NUM, 'right')} {pad(fmt(down), COL_NUM, 'right')} {pad(fmt(total), COL_NUM, 'right')}")
if not active_emails:
    print("  暂无流量数据")
print("  " + "─" * (COL_NAME + COL_NUM * 3 + 3))
print(f"  {pad('总计', COL_NAME)} {pad(fmt(total_up), COL_NUM, 'right')} {pad(fmt(total_down), COL_NUM, 'right')} {pad(fmt(total_up+total_down), COL_NUM, 'right')}")

print()
print(f"  详细日数据保留: {len(daily)} 天")
if meta.get("last_update_str"):
    print(f"  最后更新: {meta['last_update_str']}")
print("  历史详细记录保留 1 年，过期自动清理")
PY
  else
    warn "未找到 python3 或数据文件"
  fi

  echo
  echo -e "  ${DIM}数据文件: ${TRAFFIC_FILE}${NC}"
  echo -e "  ${DIM}已启用每小时自动累计（systemd timer）${NC}"
  echo
  read -rp "  按回车返回主菜单..." _
}

# ============================================================================
# 静默累计流量（供定时任务和菜单调用）
# ----------------------------------------------------------------------------
# 工作流程:
#   1. 调用 xray api statsquery（不带 reset）获取当前内存中的流量
#   2. 解析 JSON，提取 user>>>email>>>traffic>>>uplink/downlink
#      注意：名称用 >>> 分割后只有 4 段，email 在 parts[1]，方向在 parts[3]
#   3. 累加到 /etc/reality-caddy/traffic.json 的 cumulative 和 daily
#   4. 成功后再执行一次带 -reset=true 的查询，清空 Xray 内存计数器
#   5. daily 数组只保留最近 365 天的记录
# ============================================================================
accumulate_traffic_silent() {
  [[ ! -f "$INFO_FILE" ]] && return 1
  [[ ! -x /usr/local/bin/xray ]] && return 1
  systemctl is-active --quiet xray || return 1

  local API_ADDR="127.0.0.1:10085"
  local TMPRAW TMPOUT
  TMPRAW=$(mktemp)
  TMPOUT=$(mktemp)

  # 不带 reset 查询
  timeout 15 xray api statsquery --server="$API_ADDR" >"$TMPRAW" 2>/dev/null || true
  if [[ ! -s "$TMPRAW" ]]; then
    rm -f "$TMPRAW" "$TMPOUT"
    return 1
  fi

  # 用 Python 处理
  python3 - "$TMPRAW" "$TRAFFIC_FILE" >"$TMPOUT" 2>&1 <<'PY'
import json, sys, os, time
from datetime import datetime, timedelta

raw_file = sys.argv[1]
traffic_file = sys.argv[2]

try:
    with open(raw_file, encoding="utf-8") as f:
        content = f.read().strip()
    if not content.startswith("{"):
        idx = content.find("{")
        if idx >= 0:
            content = content[idx:]
    data = json.loads(content)
except Exception as e:
    print(f"PARSE_ERROR:{e}", file=sys.stderr)
    sys.exit(1)

delta = {}
for item in data.get("stat", []):
    name = item.get("name", "")
    try:
        value = int(item.get("value", 0))
    except Exception:
        value = 0
    if name.startswith("user>>>") and ">>>traffic>>>" in name:
        parts = name.split(">>>")
        if len(parts) >= 4:
            email = parts[1]
            direction = parts[3]
            delta.setdefault(email, {"uplink": 0, "downlink": 0})
            delta[email][direction] = value

print(f"DELTA_COUNT:{len(delta)}", file=sys.stderr)

store = {"cumulative": {}, "daily": [], "_meta": {}}
if os.path.isfile(traffic_file):
    try:
        with open(traffic_file) as f:
            store = json.load(f)
    except Exception:
        pass

store.setdefault("cumulative", {})
store.setdefault("daily", [])

today = datetime.now().strftime("%Y-%m-%d")

for email, d in delta.items():
    if email not in store["cumulative"]:
        store["cumulative"][email] = {"uplink": 0, "downlink": 0}
    store["cumulative"][email]["uplink"] += d.get("uplink", 0)
    store["cumulative"][email]["downlink"] += d.get("downlink", 0)

found = False
for rec in store["daily"]:
    if rec.get("date") == today:
        for email, d in delta.items():
            if email not in rec.setdefault("users", {}):
                rec["users"][email] = {"uplink": 0, "downlink": 0}
            rec["users"][email]["uplink"] += d.get("uplink", 0)
            rec["users"][email]["downlink"] += d.get("downlink", 0)
        found = True
        break
if not found and delta:
    store["daily"].append({
        "date": today,
        "users": {e: dict(d) for e, d in delta.items()}
    })

cutoff = (datetime.now() - timedelta(days=365)).strftime("%Y-%m-%d")
store["daily"] = [r for r in store["daily"] if r.get("date", "9999") >= cutoff]

store["_meta"] = {
    "last_update": int(time.time()),
    "last_update_str": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "retention_days": 365
}

try:
    os.makedirs(os.path.dirname(traffic_file), exist_ok=True)
    with open(traffic_file, "w") as f:
        json.dump(store, f, indent=2, ensure_ascii=False)
    os.chmod(traffic_file, 0o600)
    print("OK", file=sys.stderr)
except Exception as e:
    print(f"WRITE_ERROR:{e}", file=sys.stderr)
    sys.exit(1)
PY

  # 查询成功后再 reset
  if grep -q "OK" "$TMPOUT" 2>/dev/null; then
    timeout 10 xray api statsquery --server="$API_ADDR" -reset=true >/dev/null 2>&1 || true
  fi

  rm -f "$TMPRAW" "$TMPOUT"
}

# ============================================================================
# 安装每小时流量累计定时任务
# 创建 systemd service + timer，每小时调用本脚本 --accumulate
# ============================================================================
setup_traffic_timer() {
  local SCRIPT_PATH
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

  cat > /etc/systemd/system/xray-traffic-accumulate.service <<EOF
[Unit]
Description=Xray Reality Traffic Accumulate
After=xray.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --accumulate
User=root
EOF

  cat > /etc/systemd/system/xray-traffic-accumulate.timer <<EOF
[Unit]
Description=Hourly Xray Traffic Accumulate

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now xray-traffic-accumulate.timer >/dev/null 2>&1 || true
  info "已启用每小时自动累计流量定时任务"
}

# ============================================================================
# Telegram 日报相关
# ============================================================================
load_tg_conf() {
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  [[ -f "$TG_CONF" ]] || return 1
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    v=${v%\"}; v=${v#\"}
    case "$k" in
      BOT_TOKEN) TG_BOT_TOKEN="$v" ;;
      CHAT_ID)   TG_CHAT_ID="$v" ;;
    esac
  done < "$TG_CONF"
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]
}

save_tg_conf() {
  mkdir -p "$(dirname "$TG_CONF")"
  cat > "$TG_CONF" <<EOF
BOT_TOKEN="${TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"
EOF
  chmod 600 "$TG_CONF"
}

send_tg_message() {
  local text="$1"
  load_tg_conf || return 1
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    >/dev/null 2>&1
}

# ============================================================================
# 生成 Telegram 昨日流量日报文本
# 从 traffic.json 的 daily 数组中取出昨天的记录，按用户汇总后格式化成 HTML
# ============================================================================
generate_tg_report() {
  # 先累计一次
  accumulate_traffic_silent >/dev/null 2>&1 || true

  [[ -f "$TRAFFIC_FILE" ]] || return 1

  # 获取服务器 IP（优先用已保存的，否则实时检测）
  local SRV_IP=""
  load_kv "$INFO_FILE" 2>/dev/null || true
  SRV_IP="${SERVER_IP:-}"
  [[ -z "$SRV_IP" ]] && SRV_IP=$(get_public_ip 2>/dev/null || echo "未知")

  python3 - "$TRAFFIC_FILE" "$SRV_IP" "$USERS_FILE" <<'PY'
import json, sys, os
from datetime import datetime, timedelta
from collections import defaultdict

try:
    with open(sys.argv[1]) as f:
        store = json.load(f)
except Exception:
    sys.exit(1)

srv_ip = sys.argv[2] if len(sys.argv) > 2 else "未知"
users_file = sys.argv[3] if len(sys.argv) > 3 else ""

# email -> note
email_to_note = {}
if users_file and os.path.isfile(users_file):
    with open(users_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) >= 2:
                email = parts[1]
                note = parts[2].strip() if len(parts) >= 3 else ""
                email_to_note[email] = note if note else email

def display_name(email):
    return email_to_note.get(email, email)

daily = store.get("daily", [])
yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")

# 聚合昨日
y_users = defaultdict(lambda: {"uplink": 0, "downlink": 0})
for rec in daily:
    if rec.get("date") == yesterday:
        for email, d in rec.get("users", {}).items():
            y_users[email]["uplink"] += d.get("uplink", 0)
            y_users[email]["downlink"] += d.get("downlink", 0)

def fmt(b):
    b = int(b or 0)
    if b < 1024: return f"{b} B"
    if b < 1024**2: return f"{b/1024:.1f} KB"
    if b < 1024**3: return f"{b/1024**2:.1f} MB"
    return f"{b/1024**3:.2f} GB"

lines = [
    "📊 <b>Xray Reality 流量日报</b>",
    f"📅 日期：<code>{yesterday}</code>",
    f"🖥 服务器：<code>{srv_ip}</code>",
    ""
]

if not y_users:
    lines.append("😴 昨日无流量记录")
else:
    total_up = total_down = 0
    # 按总流量从高到低排序
    sorted_emails = sorted(y_users.keys(), key=lambda e: -(y_users[e]["uplink"] + y_users[e]["downlink"]))
    for email in sorted_emails:
        up = y_users[email]["uplink"]
        down = y_users[email]["downlink"]
        total_up += up
        total_down += down
        lines.append(f"👤 <b>{display_name(email)}</b>")
        lines.append(f"   ⬆️ 上行  <code>{fmt(up)}</code>")
        lines.append(f"   ⬇️ 下行  <code>{fmt(down)}</code>")
        lines.append("")
    lines.append(f"📈 <b>合计</b>")
    lines.append(f"   ⬆️ 上行  <code>{fmt(total_up)}</code>")
    lines.append(f"   ⬇️ 下行  <code>{fmt(total_down)}</code>")
    lines.append(f"   📦 总计  <code>{fmt(total_up + total_down)}</code>")

lines.append("")
lines.append(f"⏰ 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

print("\n".join(lines))
PY
}

# ============================================================================
# Telegram 日报配置菜单
# 支持：配置 Token/ChatID、测试发送、手动发送昨日日报、启用/关闭每天 01:00 定时推送
# ============================================================================
do_telegram() {
  clear
  banner "Telegram 日报设置"
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  load_tg_conf 2>/dev/null || true

  echo
  echo -e "  ${BOLD}当前配置${NC}"
  line
  if [[ -n "${TG_BOT_TOKEN:-}" ]]; then
    echo -e "  Bot Token : ${TG_BOT_TOKEN:0:10}...（已设置）"
    echo -e "  Chat ID   : ${TG_CHAT_ID:-未设置}"
  else
    echo -e "  ${YELLOW}尚未配置${NC}"
  fi
  line
  echo
  mi 1 "配置 Token" "设置 Bot Token 和 Chat ID"
  mi 2 "测试发送" "立即发送一条测试消息"
  mi 3 "手动日报" "立即生成并发送昨日日报"
  mi 4 "启用定时" "每天 01:00 自动发送昨日日报"
  mi 5 "关闭定时" "停止自动日报"
  line
  mi 0 "返回" "返回主菜单"
  echo
  read -rp "  请选择 [0-5]: " TC
  case "$TC" in
    1)
      echo
      read -rp "  Bot Token: " TG_BOT_TOKEN
      read -rp "  Chat ID  : " TG_CHAT_ID
      [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && { warn "不能为空"; return; }
      save_tg_conf
      info "已保存"
      ;;
    2)
      if send_tg_message "✅ Reality 脚本测试消息 $(date '+%Y-%m-%d %H:%M:%S')"; then
        info "测试消息已发送"
      else
        warn "发送失败，请检查 Token / Chat ID / 网络"
      fi
      ;;
    3)
      local report
      report=$(generate_tg_report)
      if [[ -n "$report" ]] && send_tg_message "$report"; then
        info "日报已发送"
      else
        warn "生成或发送失败"
      fi
      ;;
    4)
      setup_tg_timer
      ;;
    5)
      systemctl disable --now xray-tg-report.timer 2>/dev/null || true
      info "已关闭自动日报"
      ;;
  esac
  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 安装每天 01:00 Telegram 日报定时任务
# 创建 systemd service + timer，每天凌晨 1 点调用本脚本 --tg-report
# ============================================================================
setup_tg_timer() {
  local SCRIPT_PATH
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

  cat > /etc/systemd/system/xray-tg-report.service <<EOF
[Unit]
Description=Xray Reality Telegram Daily Report
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --tg-report
User=root
EOF

  cat > /etc/systemd/system/xray-tg-report.timer <<EOF
[Unit]
Description=Daily Telegram Traffic Report at 01:00

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now xray-tg-report.timer >/dev/null 2>&1 || true
  info "已启用每天 01:00 自动发送 Telegram 日报"
}

# ============================================================================
# 自动检测并补全定时任务（无需重装）
# ============================================================================
auto_setup_timers() {
  [[ ! -f "$INFO_FILE" ]] && return 0

  local SCRIPT_PATH
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

  local need_reload=0

  # 流量累计 timer
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^xray-traffic-accumulate.timer'; then
    cat > /etc/systemd/system/xray-traffic-accumulate.service <<EOF
[Unit]
Description=Xray Reality Traffic Accumulate
After=xray.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --accumulate
User=root
EOF
    cat > /etc/systemd/system/xray-traffic-accumulate.timer <<EOF
[Unit]
Description=Hourly Xray Traffic Accumulate

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    need_reload=1
    info "已自动创建流量累计定时任务（每小时）"
  fi

  # TG 日报 timer（仅当已配置 Token 时才自动启用）
  if load_tg_conf 2>/dev/null && ! systemctl list-unit-files 2>/dev/null | grep -q '^xray-tg-report.timer'; then
    cat > /etc/systemd/system/xray-tg-report.service <<EOF
[Unit]
Description=Xray Reality Telegram Daily Report
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --tg-report
User=root
EOF
    cat > /etc/systemd/system/xray-tg-report.timer <<EOF
[Unit]
Description=Daily Telegram Traffic Report at 01:00

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    need_reload=1
    info "已自动创建 TG 日报定时任务（每天 01:00）"
  fi

  if [[ $need_reload -eq 1 ]]; then
    systemctl daemon-reload
    systemctl enable --now xray-traffic-accumulate.timer >/dev/null 2>&1 || true
    if systemctl list-unit-files 2>/dev/null | grep -q '^xray-tg-report.timer'; then
      systemctl enable --now xray-tg-report.timer >/dev/null 2>&1 || true
    fi
  fi
}

# ============================================================================
# 主循环
# ============================================================================
# 非交互模式
if [[ "$ACCUMULATE_MODE" == "1" ]]; then
  accumulate_traffic_silent
  exit $?
fi

if [[ "$TG_REPORT_MODE" == "1" ]]; then
  report=$(generate_tg_report)
  if [[ -n "$report" ]]; then
    send_tg_message "$report" && exit 0
  fi
  exit 1
fi

while true; do
  show_menu
  case "$CHOICE" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_status ;;
    4) do_show_client ;;
    5) users_menu ;;
    6) do_diagnose ;;
    7) do_traffic ;;
    8) do_telegram ;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
done
