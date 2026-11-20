#!/usr/bin/env bash
# ============================================================================
# Xray Reality + Vision / XHTTP 一键管理脚本
# ----------------------------------------------------------------------------
# 项目名称 : Xray Reality + Vision / XHTTP 一键管理脚本
# Xray 版本 : 默认 v26.6.27（可用 XRAY_VERSION=xxx 覆盖；安装失败自动回落 latest）
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
#   9. 流量开关   : 开启 / 关闭流量统计（关闭后不再写入 stats 段）
#                  定时任务（助手脚本 + systemd 单元）的校验与自动修复
#                  只在“开启流量统计”时执行，主菜单不再每次巡检
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

# 确保 python3 存在，没有就自动安装
ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  info "未检测到 python3，正在自动安装..."
  apt-get update -y >/dev/null 2>&1 || true
  if apt-get install -y python3 >/dev/null 2>&1; then
    info "python3 安装完成"
    return 0
  else
    warn "python3 自动安装失败，请手动执行: apt-get install -y python3"
    return 1
  fi
}

# 步骤标题：圆角边框 + 箭头
step() {
  echo
  echo -e "${BLUE}  ╭─────────────────────────────────────────────────╮${NC}"
  echo -e "${BLUE}  │  ▶ $*${NC}"
  echo -e "${BLUE}  ╰─────────────────────────────────────────────────╯${NC}"
}

# 大标题（无框简洁版）
banner() {
  local title="$1"
  echo
  echo -e "  ${CYAN}${BOLD}▶ ${title}${NC}"
  echo -e "  ${CYAN}────────────────────────────────────────────────────${NC}"
  echo
}

# 菜单项输出（美化两行式）
mi() {
  local num="$1" name="$2" desc="$3"
  printf "  ${GREEN}┌─${NC} ${BOLD}[%s]${NC}  ${CYAN}%s${NC}\n" "$num" "$name"
  printf "  ${GREEN}└─${NC}     ${DIM}%s${NC}\n" "$desc"
  echo
}

# 分隔线
line() {
  echo -e "  ${BLUE}────────────────────────────────────────────────────${NC}"
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
TIMER_HELPER=/usr/local/bin/xray-reality-timer   # 定时任务专用助手脚本（固定路径）
TG_TIMER_ON_FILE=/etc/reality-caddy/tg_timer.enabled  # TG 日报定时的启用标记（存在=用户启用过）
TRAFFIC_STATS=1                                  # 流量统计开关：1 开启 / 0 关闭（由 info.txt 覆盖）
LOG_RETENTION_DAYS=7                             # 日志保留天数
CADDY_BIN=""                                     # Caddy 可执行文件路径（安装后赋值）
ACME_CHALLENGE=""                                # 证书验证方式：http 或 dns
XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"         # Xray 安装版本（可用环境变量覆盖，失败自动回落 latest）

# ----------------------------------------------------------------------------
# 安装时探测到的“原有 Caddy”标记：1=安装前系统里已存在自装 Caddy（卸载时不删除）
CADDY_EXISTED_BEFORE=0
CADDY_OWNED=0                                    # 1=Caddy 由本脚本安装/编译，卸载时才删除

# ----------------------------------------------------------------------------
# 清理本脚本创建的 caddy-json.service（模式切换 / 卸载时统一走这里）
# ----------------------------------------------------------------------------
remove_caddy_json_service() {
  systemctl disable --now caddy-json.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/caddy-json.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed caddy-json.service >/dev/null 2>&1 || true
}

# caddy-json.service 是否已存在（不依赖 MODE，避免切模式后变幽灵服务）
has_caddy_json_service() {
  [[ -f /etc/systemd/system/caddy-json.service ]] \
    || systemctl list-unit-files 2>/dev/null | grep -q '^caddy-json\.service'
}

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
# 安装固定路径的定时任务助手脚本（独立于主脚本）
# ============================================================================
install_timer_helper() {
  cat > "$TIMER_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
INFO_FILE=/etc/reality-caddy/info.txt
TRAFFIC_FILE=/etc/reality-caddy/traffic.json
USERS_FILE=/etc/reality-caddy/users.txt
TG_CONF=/etc/reality-caddy/telegram.conf

ensure_python3() {
  command -v python3 >/dev/null 2>&1 && return 0
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y python3 >/dev/null 2>&1 || true
}

accumulate() {
  ensure_python3 || return 1
  [[ -f "$INFO_FILE" ]] || return 1
  [[ -x /usr/local/bin/xray ]] || return 1
  systemctl is-active --quiet xray || return 1

  local API_ADDR="127.0.0.1:10085"
  local TMPRAW
  TMPRAW=$(mktemp)

  timeout 15 xray api statsquery --server="$API_ADDR" >"$TMPRAW" 2>/dev/null || true
  if [[ ! -s "$TMPRAW" ]]; then
    rm -f "$TMPRAW"
    return 1
  fi

  # 注意：写盘失败时直接返回非 0，且不执行 reset，避免流量被清零后丢失
  if ! python3 - "$TMPRAW" "$TRAFFIC_FILE" <<'PY'
import json, sys, os, time
from datetime import datetime, timedelta

raw_file, traffic_file = sys.argv[1], sys.argv[2]
try:
    with open(raw_file, encoding="utf-8") as f:
        content = f.read().strip()
    if not content.startswith("{"):
        idx = content.find("{")
        if idx >= 0: content = content[idx:]
    data = json.loads(content)
except Exception as e:
    print(f"PARSE_ERROR:{e}", file=sys.stderr)
    sys.exit(1)

delta = {}
for item in data.get("stat", []):
    name = item.get("name", "")
    if name.startswith("user>>>") and ">>>traffic>>>" in name:
        parts = name.split(">>>")
        if len(parts) >= 4:
            email, direction = parts[1], parts[3]
            try:
                value = int(item.get("value", 0))
            except Exception:
                value = 0
            delta.setdefault(email, {"uplink": 0, "downlink": 0})
            delta[email][direction] = value

store = {"cumulative": {}, "daily": [], "_meta": {}}
if os.path.isfile(traffic_file):
    try:
        with open(traffic_file) as f:
            store = json.load(f)
    except Exception:
        pass

store.setdefault("cumulative", {})
store.setdefault("daily", [])
store.setdefault("_meta", {})

now = datetime.now()
today = now.strftime("%Y-%m-%d")
try:
    prev_ts = int(store["_meta"].get("last_update", 0) or 0)
except Exception:
    prev_ts = 0

# 累计量（自安装以来）永远是全量累加，不做拆分
for email, d in delta.items():
    if email not in store["cumulative"]:
        store["cumulative"][email] = {"uplink": 0, "downlink": 0}
    store["cumulative"][email]["uplink"] += d.get("uplink", 0)
    store["cumulative"][email]["downlink"] += d.get("downlink", 0)

# 日粒度按“采集区间”归属。
# 上次累计时刻与当前时刻若跨天，则按时间比例把这段流量拆到两天，
# 修掉旧实现把 23:00-24:00 的流量整体记到次日、导致日报偏小的问题。
segments = []
if prev_ts > 0:
    prev_dt = datetime.fromtimestamp(prev_ts)
    span = (now - prev_dt).total_seconds()
    if span > 0 and prev_dt.strftime("%Y-%m-%d") != today:
        midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
        old_ratio = max(0.0, min(1.0, (midnight - prev_dt).total_seconds() / span))
        if old_ratio > 0:
            segments.append((prev_dt.strftime("%Y-%m-%d"), old_ratio))
        if old_ratio < 1:
            segments.append((today, 1.0 - old_ratio))
    else:
        segments.append((today, 1.0))
if not segments:
    segments.append((today, 1.0))

def day_record(date_str):
    for r0 in store["daily"]:
        if r0.get("date") == date_str:
            r0.setdefault("users", {})
            return r0
    r0 = {"date": date_str, "users": {}}
    store["daily"].append(r0)
    return r0

assigned = {}
for idx, (date_str, ratio) in enumerate(segments):
    is_last = (idx == len(segments) - 1)
    rec = day_record(date_str)
    for email, d in delta.items():
        slot = rec["users"].setdefault(email, {"uplink": 0, "downlink": 0})
        for direction in ("uplink", "downlink"):
            done = assigned.get((email, direction), 0)
            if is_last:
                amount = d.get(direction, 0) - done
            else:
                amount = int(round(d.get(direction, 0) * ratio))
            if amount < 0:
                amount = 0
            assigned[(email, direction)] = done + amount
            if amount:
                slot[direction] += amount

cutoff = (now - timedelta(days=365)).strftime("%Y-%m-%d")
store["daily"] = [r for r in store["daily"] if r.get("date", "9999") >= cutoff]
store["daily"].sort(key=lambda r: r.get("date", ""))

store["_meta"] = {
    "last_update": int(time.time()),
    "last_update_str": now.strftime("%Y-%m-%d %H:%M:%S"),
    "retention_days": 365
}

try:
    os.makedirs(os.path.dirname(traffic_file), exist_ok=True)
    with open(traffic_file, "w") as f:
        json.dump(store, f, indent=2, ensure_ascii=False)
    os.chmod(traffic_file, 0o600)
except Exception as e:
    print(f"WRITE_ERROR:{e}", file=sys.stderr)
    sys.exit(1)
print("OK")
PY
  then
    rm -f "$TMPRAW"
    return 1
  fi

  timeout 10 xray api statsquery --server="$API_ADDR" -reset=true >/dev/null 2>&1 || true
  rm -f "$TMPRAW"
  return 0
}

tg_report() {
  accumulate >/dev/null 2>&1 || true
  [[ -f "$TRAFFIC_FILE" ]] || exit 1

  TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  if [[ -f "$TG_CONF" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "$k" || "$k" =~ ^# ]] && continue
      v=${v%\"}; v=${v#\"}
      case "$k" in
        BOT_TOKEN) TG_BOT_TOKEN="$v" ;;
        CHAT_ID)   TG_CHAT_ID="$v" ;;
      esac
    done < "$TG_CONF"
  fi
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] || exit 1

  local SRV_IP
  SRV_IP=$(grep -oP 'SERVER_IP="\K[^"]+' "$INFO_FILE" 2>/dev/null || true)
  [[ -z "$SRV_IP" ]] && SRV_IP=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "未知")

  local report
  report=$(python3 - "$TRAFFIC_FILE" "$SRV_IP" "$USERS_FILE" <<'PY'
import json, sys, os
from datetime import datetime, timedelta
from collections import defaultdict

try:
    with open(sys.argv[1]) as f:
        store = json.load(f)
except:
    sys.exit(1)

srv_ip = sys.argv[2]
users_file = sys.argv[3]

email_to_note = {}
if users_file and os.path.isfile(users_file):
    with open(users_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            parts = line.split("|")
            if len(parts) >= 2:
                email = parts[1]
                note = parts[2].strip() if len(parts) >= 3 else ""
                email_to_note[email] = note if note else email

def display_name(e):
    return email_to_note.get(e, e)

daily = store.get("daily", [])
yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
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
    for email in sorted(y_users.keys(), key=lambda e: -(y_users[e]["uplink"] + y_users[e]["downlink"])):
        up = y_users[email]["uplink"]
        down = y_users[email]["downlink"]
        total_up += up
        total_down += down
        lines.append(f"👤 <b>{display_name(email)}</b>")
        lines.append(f"   ⬆️ 上行  <code>{fmt(up)}</code>")
        lines.append(f"   ⬇️ 下行  <code>{fmt(down)}</code>")
        lines.append("")
    lines.append("📈 <b>合计</b>")
    lines.append(f"   ⬆️ 上行  <code>{fmt(total_up)}</code>")
    lines.append(f"   ⬇️ 下行  <code>{fmt(total_down)}</code>")
    lines.append(f"   📦 总计  <code>{fmt(total_up + total_down)}</code>")

lines.append("")
lines.append(f"⏰ 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("\n".join(lines))
PY
)

  [[ -n "$report" ]] || exit 1

  local resp
  # -f 让 HTTP 4xx/5xx 也返回非 0；再校验 Telegram 的 "ok":true，避免失败被当成成功
  if ! resp=$(curl -s -f --max-time 20 -X POST \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${report}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" 2>/dev/null); then
    echo "TELEGRAM_SEND_FAILED" >&2
    exit 1
  fi
  case "$resp" in
    *'"ok":true'*) exit 0 ;;
    *) echo "TELEGRAM_SEND_FAILED: $resp" >&2; exit 1 ;;
  esac
}

case "$MODE" in
  --accumulate) accumulate ;;
  --tg-report)  tg_report ;;
  *) echo "Usage: $0 --accumulate | --tg-report"; exit 1 ;;
esac
EOF
  chmod +x "$TIMER_HELPER"
}

# ============================================================================
# 主菜单显示函数
# ============================================================================
show_menu() {
  clear
  banner "Xray Reality + Vision / XHTTP  一键管理脚本"
  echo -e "  ${BOLD}${CYAN}功能菜单${NC}"
  line
  echo
  mi 1 "安装服务" "域名模式 / IP模式 一键部署"
  mi 2 "卸载服务" "停止并清理全部组件"
  mi 3 "查看状态" "服务运行状态与端口监听"
  mi 4 "查看参数" "输出客户端分享链接与详细配置"
  mi 5 "管理用户" "添加 / 删除 / 查看用户"
  mi 6 "诊断自检" "连不上时优先使用（只读）"
  mi 7 "流量统计" "按月查看用户累计流量"
  mi 8 "TG 日报" "配置 / 测试 Telegram 每日流量推送"
  mi 9 "流量开关" "启用 / 关闭流量统计（含定时任务校验）"
  line
  echo
  mi 0 "退出脚本" "安全退出"
  echo
  echo -e "  ${YELLOW}提示：连接异常时请先执行 [6] 诊断自检${NC}"
  echo
  read -rp "  请选择 [0-9]: " CHOICE
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
    key=$(echo "$key" | xargs)
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    printf -v "$key" '%s' "$value"
  done < "$FILE"
  return 0
}

# ============================================================================
# 逐行输出“有效用户记录”（uuid|email|note）
#   - 末行无换行符也能取到（旧实现会静默丢弃最后一个用户）
#   - 统一过滤：注释行 / 空行 / 非法 UUID / CRLF 残留
#   - 列表、删除、生成配置全部走这里，保证三处的编号与内容完全一致
# ============================================================================
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

list_user_records() {
  [[ -f "$USERS_FILE" ]] || return 0
  local u e n
  while IFS='|' read -r u e n || [[ -n "${u:-}" ]]; do
    u="${u//$'\r'/}"; u="${u//$'\n'/}"
    e="${e//$'\r'/}"; e="${e//$'\n'/}"
    n="${n//$'\r'/}"
    # 去掉首尾空白
    u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
    [[ -z "$u" || "$u" =~ ^# ]] && continue
    # VLESS 必须是标准 UUID，脏行直接忽略，避免一条坏数据让 xray 起不来
    [[ "$u" =~ $UUID_RE ]] || continue
    printf '%s|%s|%s\n' "$u" "${e:-user@local}" "${n:-}"
  done < "$USERS_FILE"
}

# ============================================================================
# 根据 users.txt 生成 Xray clients JSON 数组
#   额外做 email 去重（Xray 要求同一 inbound 内唯一）与 JSON 转义
# ============================================================================
build_clients_json() {
  [[ ! -f "$USERS_FILE" ]] && { echo '[]'; return 0; }
  local first=1
  local use_flow=0
  local uuid email _note
  local -A seen=()
  [[ "${TRANSPORT:-tcp}" == "tcp" ]] && use_flow=1
  echo "["
  while IFS='|' read -r uuid email _note; do
    # 重复 email 会导致流量统计串号，只保留第一条
    [[ -n "${seen[$email]:-}" ]] && continue
    seen[$email]=1
    # JSON 字符串转义（标识里可能出现引号或反斜杠）
    email="${email//\\/\\\\}"
    email="${email//\"/\\\"}"
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '          {\n'
    printf '            "id": "%s",\n' "$uuid"
    printf '            "email": "%s",\n' "$email"
    printf '            "level": 0'
    if [[ $use_flow -eq 1 ]]; then
      printf ',\n            "flow": "xtls-rprx-vision"\n'
    else
      printf '\n'
    fi
    printf '          }'
  done < <(list_user_records)
  echo
  echo "        ]"
}

# ============================================================================
# 统计用户数量（空文件 / 无有效记录时只输出一个 0）
#   旧写法 grep -vc ... || echo 0 在无匹配时会输出 "0\n0"，界面显示成 "0 0"
# ============================================================================
count_users() {
  list_user_records | awk 'END { print NR + 0 }'
}

# ============================================================================
# 重建 Xray 主配置文件
# ============================================================================
rebuild_xray_config() {
  load_kv "$INFO_FILE" || error "未找到 $INFO_FILE，请先安装"
  mkdir -p "$(dirname "$XRAY_CONF")"

  # 端口兜底：info.txt 被手工改坏（非数字/越界）时，不要让配置变成非法 JSON
  local DEFAULT_PORT=443
  [[ "${MODE:-domain}" == "ip" ]] && DEFAULT_PORT=8443
  if [[ ! "${XRAY_PORT:-}" =~ ^[0-9]{1,5}$ ]] \
     || (( 10#${XRAY_PORT:-0} < 1 || 10#${XRAY_PORT:-0} > 65535 )); then
    warn "info.txt 中的监听端口 [${XRAY_PORT:-空}] 非法，已回退为 ${DEFAULT_PORT}"
    XRAY_PORT="$DEFAULT_PORT"
  fi

  local CLIENTS_JSON
  CLIENTS_JSON=$(build_clients_json)

  local REALITY_DEST REALITY_SNI
  if [[ "${MODE:-domain}" == "ip" ]]; then
    local NORM
    NORM=$(normalize_dest "${DEST_DOMAIN:-}" 2>/dev/null) || {
      warn "伪装目标域名不合法: [${DEST_DOMAIN:-空}]"
      return 1
    }
    DEST_DOMAIN="$NORM"

    # 探测仅作提醒：加/删用户、开关统计都会走到这里，不能因为一次网络抖动就阻断操作
    probe_dest_tls "$DEST_DOMAIN" 443 \
      || warn "伪装目标 ${DEST_DOMAIN} 的 TLS 握手探测失败（不影响写入配置，稍后可在 [6] 诊断中复查）"

    REALITY_DEST="${DEST_DOMAIN}:443"
    REALITY_SNI="${DEST_DOMAIN}"
  else
    REALITY_DEST="127.0.0.1:8003"
    REALITY_SNI="${DOMAIN}"
  fi

  local STREAM_SETTINGS
  if [[ "${TRANSPORT:-tcp}" == "xhttp" ]]; then
    STREAM_SETTINGS=$(cat <<EOS
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["", "${SHORT_ID}"]
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
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["", "${SHORT_ID}"]
        }
EOS
)
  fi

  # 流量统计开关关闭时，不写入 stats / api / policy 段（真正的“关闭统计”）
  local STATS_BLOCK="" POLICY_BLOCK=""
  if [[ "${TRAFFIC_STATS:-1}" == "1" ]]; then
    STATS_BLOCK='  "stats": {},
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:10085",
    "services": ["StatsService"]
  },
'
    POLICY_BLOCK='  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  },
'
  fi

  cat > "$XRAY_CONF" <<EOF
{
  "log": {"loglevel": "warning"},
${STATS_BLOCK}${POLICY_BLOCK}  "inbounds": [
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
    {"protocol": "freedom", "tag": "direct"}
  ]
}
EOF

  if ! xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "Xray 配置校验失败"
    xray -test -config "$XRAY_CONF" || true
    return 1
  fi
  return 0
}

# ============================================================================
# 自动放行本机防火墙端口
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
      if iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        continue
      fi
      if iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        changed=1
      fi
    done
    if [[ $changed -eq 1 ]]; then
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
      fi
      info "iptables: 已放行 TCP ${ports[*]}"
      opened=1
    fi
  fi

  if [[ $opened -eq 0 ]]; then
    info "未检测到启用中的本机防火墙"
  fi
}

# ============================================================================
# 打印端口放行提醒
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
      echo -e "  │  必须放行：${CYAN}TCP 80${NC}（ACME HTTP-01）"
    else
      echo -e "  │  无需放行：TCP 80（DNS-01 模式）"
    fi
    echo -e "  │            ${CYAN}TCP ${port}${NC}（Xray 监听端口）"
  fi
  echo -e "  │  操作位置：云厂商控制台 → 安全组 / 防火墙 入站规则"
  echo -e "${YELLOW}  ╰──────────────────────────────────────────────────────╯${NC}"
}

# ============================================================================
# 处理常见 Web 服务端口占用
# ============================================================================
handle_common_occupiers() {
  step "检测并处理常见端口占用"

  if [[ "${ACME_CHALLENGE:-http}" == "http" ]]; then
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
    info "DNS-01 模式：Caddy 不监听 80"
    if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
      warn "端口 ${XRAY_PORT} 已被占用"
      ss -tlnp | grep -E ":${XRAY_PORT}\b" || true
      read -rp "是否继续？[y/N]: " C
      [[ "${C,,}" != "y" ]] && { info "已取消"; exit 0; }
    else
      info "端口 ${XRAY_PORT} 空闲"
    fi
  fi
}

# ============================================================================
# 配置日志保留策略
# ============================================================================
configure_log_retention() {
  step "配置日志保留策略（${LOG_RETENTION_DAYS} 天）"

  # journald 的配置是全局的，会影响本机所有服务的日志，先提示并备份非本脚本写入的旧配置
  local JD_CONF=/etc/systemd/journald.conf.d/99-retention.conf
  if [[ -f "$JD_CONF" ]] && ! grep -q 'Xray Reality' "$JD_CONF" 2>/dev/null; then
    local BAK
    BAK="${JD_CONF}.bak.$(date +%s)"
    cp -a "$JD_CONF" "$BAK" 2>/dev/null && warn "已存在其它 journald 保留策略，原文件已备份到 ${BAK}"
  fi
  warn "journald 保留策略为全局生效，会同时影响本机其它服务的日志"

  mkdir -p /etc/systemd/journald.conf.d
  cat > "$JD_CONF" <<EOF
# 由 Xray Reality 一键脚本写入（卸载脚本会删除本文件）
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
  # 注意：--vacuum-time 清理的是整机 journal 历史，不只是 xray 的日志
  journalctl --vacuum-time="${LOG_RETENTION_DAYS}d" >/dev/null 2>&1 || true
  info "已按 ${LOG_RETENTION_DAYS} 天清理整机 journal 历史日志"

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
# 端口校验：交互式取端口，必须是 1-65535 的整数
#   旧实现直接把用户输入拼进 JSON，输入 "443 " 或 "abc" 会让 xray -test 失败
# ============================================================================
normalize_port() {
  local val="$1" def="$2"
  val="${val//[[:space:]]/}"
  while true; do
    [[ -z "$val" ]] && val="$def"
    if [[ "$val" =~ ^[0-9]{1,5}$ ]]; then
      local n=$((10#$val))
      if (( n >= 1 && n <= 65535 )); then
        echo "$n"
        return 0
      fi
    fi
    warn "端口必须是 1-65535 之间的数字，当前输入: ${val}"
    read -rp "  请重新输入端口 (默认 ${def}): " val || return 1
    val="${val//[[:space:]]/}"
  done
}

# ============================================================================
# 真实 TLS 1.3 握手探测
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
    return 0
  fi

  if echo "$out" | grep -qiE 'alert|handshake failure|no protocols|timeout|Connection refused|connect:errno'; then
    return 1
  fi
  [[ -z "$out" ]] && return 1
  return 1
}

# ============================================================================
# IP 模式：交互式选择伪装目标域名
# ============================================================================
choose_dest_domain() {
  echo
  step "实测候选伪装目标（TLS1.3 握手探测）"
  echo -e "  说明：只有握手正常的目标才能作为 dest。"
  echo

  local -a GOOD=()
  local d
  for d in "${BUILTIN_DESTS[@]}"; do
    if probe_dest_tls "$d" 443; then
      GOOD+=("$d")
      echo -e "  ${GREEN}[通过]${NC} $d"
    else
      echo -e "  ${RED}[失败]${NC} $d"
    fi
  done

  echo
  if [[ ${#GOOD[@]} -eq 0 ]]; then
    warn "内置候选全部握手失败，请手动输入"
    while true; do
      read -rp "  请输入自定义伪装域名: " DEST_DOMAIN
      if DEST_DOMAIN=$(normalize_dest "${DEST_DOMAIN:-}"); then
        if probe_dest_tls "$DEST_DOMAIN" 443; then
          info "握手通过: $DEST_DOMAIN"
          return 0
        fi
        warn "$DEST_DOMAIN 握手失败，请换一个"
      else
        warn "域名格式不合法"
      fi
    done
  fi

  echo -e "  ${BLUE}▶ 请选择伪装目标域名${NC}"
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
      read -rp "  请输入自定义伪装域名: " INPUT_DEST
      if DEST_DOMAIN=$(normalize_dest "${INPUT_DEST:-}"); then
        if probe_dest_tls "$DEST_DOMAIN" 443; then
          info "握手通过: $DEST_DOMAIN"
          break
        fi
        warn "$DEST_DOMAIN 握手失败"
        read -rp "仍要使用它？[y/N]: " KEEP
        [[ "${KEEP,,}" == "y" ]] && break
      else
        warn "域名格式不合法"
      fi
    done
  else
    DEST_DOMAIN="${GOOD[0]}"
  fi

  info "已选择伪装域名: $DEST_DOMAIN"
}

# ============================================================================
# 服务器出网连通性自检
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
# 获取服务器公网 IPv4 地址
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
# ============================================================================
generate_reality_keys() {
  local out
  out=$(xray x25519 2>/dev/null || true)

  # 按标签解析（不同 Xray 版本输出格式不同：Private key / PrivateKey / 私钥）
  PRIVATE_KEY=$(printf '%s\n' "$out" | awk -F': *' \
    'tolower($1) ~ /^(private ?key|privatekey|私钥)$/ { print $2; exit }')
  PUBLIC_KEY=$(printf '%s\n' "$out" | awk -F': *' \
    'tolower($1) ~ /^(public ?key|publickey|password|公钥|密码)$/ { print $2; exit }')

  # 兜底：取前两行最后一个字段
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $NF}')
    PUBLIC_KEY=$(printf '%s\n' "$out" | sed -n '2p' | awk '{print $NF}')
  fi

  # 去掉可能混入的空白字符
  PRIVATE_KEY="${PRIVATE_KEY//[[:space:]]/}"
  PUBLIC_KEY="${PUBLIC_KEY//[[:space:]]/}"

  [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "生成 Reality 密钥失败"

  SHORT_ID=$(openssl rand -hex 8)
}

# ============================================================================
# 一、安装主流程
# ============================================================================
do_install() {
  local KEEP_USERS=0
  local PORT_IN=""

  # 安装中断（error 内部直接 exit）时给出明确的善后提示，避免留下无人知晓的“半装状态”
  INSTALL_STARTED=0
  INSTALL_DONE=0
  trap 'if [[ "${INSTALL_STARTED:-0}" == "1" && "${INSTALL_DONE:-0}" != "1" ]]; then
          echo
          warn "安装流程未完成，系统可能处于半装状态"
          info "可重新运行本脚本选择 [1] 覆盖安装，或选择 [2] 卸载后重装"
          info "排查日志: /tmp/caddy_validate.log 、 journalctl -u xray -u caddy-json"
        fi' EXIT

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
      echo -e "  用户数量  : $(count_users)"
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

  step "选择传输方式"
  echo
  mi 1 "TCP + Vision" "经典 Reality + Vision 流控（推荐）"
  mi 2 "XHTTP"        "XHTTP 传输（更现代）"
  echo
  read -rp "  请选择 [1-2] (默认 1): " TRANS_SEL
  TRANS_SEL=${TRANS_SEL:-1}
  if [[ "$TRANS_SEL" == "2" ]]; then
    TRANSPORT="xhttp"
    XHTTP_PATH="/$(openssl rand -hex 12)"
    info "已选择: XHTTP 传输，路径: ${XHTTP_PATH}"
  else
    TRANSPORT="tcp"
    XHTTP_PATH=""
    info "已选择: TCP + Vision"
  fi

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

    read -rp "  请输入 Xray 监听端口 (默认 8443): " PORT_IN
    XRAY_PORT=$(normalize_port "${PORT_IN:-}" 8443)

    choose_dest_domain
    EMAIL=""
    SITE_TITLE=""
    DOMAIN=""
    ACME_CHALLENGE=""
    CF_API_TOKEN=""
  else
    read -rp "  请输入你的域名 (例如: example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空"

    echo
    echo -e "  ${BLUE}▶ 证书验证方式${NC}"
    line
    mi 1 "HTTP 验证" "HTTP-01，需占用 80 端口"
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

    read -rp "  请输入用于 ACME 的邮箱 (如 admin@${DOMAIN}): " EMAIL
    [[ -z "$EMAIL" ]] && error "邮箱不能为空"
    if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
      error "邮箱格式不合法: $EMAIL"
    fi
    if [[ "$EMAIL" =~ @(example\.com|example\.org|example\.net)$ ]]; then
      error "Let's Encrypt 禁止使用 example.com/org/net 域名的邮箱"
    fi

    read -rp "  请输入伪装站标题 (默认: Welcome): " SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-Welcome}
    # 标题会直接写进伪装站 HTML，去掉可能破坏标签或注入脚本的字符
    SITE_TITLE="${SITE_TITLE//[<>\"\'\`]/}"
    SITE_TITLE=${SITE_TITLE:-Welcome}
    read -rp "  请输入 Xray 监听端口 (默认 443): " PORT_IN
    XRAY_PORT=$(normalize_port "${PORT_IN:-}" 443)
    SERVER_IP=""
    DEST_DOMAIN=""

    CF_API_TOKEN=""
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      echo
      warn "DNS-01 需要 Cloudflare API Token"
      read -rsp "  CF_API_TOKEN: " CF_API_TOKEN
      echo
      [[ -z "$CF_API_TOKEN" ]] && error "API Token 不能为空"
    fi
  fi
  info "参数已录入"
  INSTALL_STARTED=1

  UUID=$(cat /proc/sys/kernel/random/uuid)
  info "自动生成初始 UUID: $UUID"

  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl gnupg lsb-release ca-certificates openssl dnsutils python3

  if [[ "$MODE" == "domain" ]]; then
    step "安装 Caddy"
    # 记录安装前是否已存在 Caddy：卸载时不误删用户自装的 Caddy
    if command -v caddy >/dev/null 2>&1 || [[ -x /usr/local/bin/caddy ]]; then
      CADDY_EXISTED_BEFORE=1
    fi
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      info "DNS-01 模式：将使用 xcaddy 构建带 Cloudflare 插件的 Caddy"
      if ! command -v go >/dev/null 2>&1 || ! go version 2>/dev/null | grep -qE 'go1\.(2[1-9]|[3-9][0-9])'; then
        info "安装 Go 1.22（仅用于编译 Caddy，编译完自动清理）"
        GO_INSTALLED_BY_SCRIPT=1
        local ARCH
        case "$(dpkg --print-architecture)" in
          amd64) ARCH="amd64" ;;
          arm64) ARCH="arm64" ;;
          *) error "不支持的架构" ;;
        esac
        rm -rf /usr/local/go
        curl -sSL "https://go.dev/dl/go1.22.5.linux-${ARCH}.tar.gz" | tar -xz -C /usr/local
        export PATH="/usr/local/go/bin:$PATH"
      fi
      local GOPATH_BIN
      GOPATH_BIN="$(go env GOPATH)/bin"
      export PATH="$PATH:/usr/local/go/bin:${GOPATH_BIN}"
      if ! command -v xcaddy >/dev/null 2>&1; then
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
        export PATH="$PATH:${GOPATH_BIN}"
      fi
      xcaddy build --with github.com/caddy-dns/cloudflare --output /usr/local/bin/caddy
      CADDY_BIN=/usr/local/bin/caddy
      # 编译完成后清理由本脚本安装的 Go 工具链（约 250MB），用户自装的 Go 不动
      if [[ "$GO_INSTALLED_BY_SCRIPT" == "1" ]]; then
        info "清理临时安装的 Go 工具链"
        rm -rf /usr/local/go
        GO_INSTALLED_BY_SCRIPT=0
      fi
    else
      if ! command -v caddy >/dev/null 2>&1; then
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        fi
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt-get update -y
        apt-get install -y caddy
      fi
      CADDY_BIN=$(command -v caddy)
    fi
    [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]] && error "Caddy 安装失败"
    # 记录 Caddy 归属：安装前已存在说明是用户自己的，卸载时不能删
    if [[ "$CADDY_EXISTED_BEFORE" == "1" ]]; then
      CADDY_OWNED=0
    else
      CADDY_OWNED=1
    fi
    info "Caddy: $("$CADDY_BIN" version)"
  else
    info "IP 模式：跳过 Caddy 安装"
    CADDY_OWNED=0
    # 从域名模式覆盖重装成 IP 模式时，旧的 caddy-json.service 会继续占着 80 端口，
    # 而且卸载逻辑按 MODE 判断会漏掉它，所以这里主动清掉
    if has_caddy_json_service; then
      warn "检测到旧的 caddy-json.service（域名模式遗留），正在清理"
      remove_caddy_json_service
    fi
  fi

  step "安装 Xray ${XRAY_VERSION}"
  local XRAY_INSTALLER
  if ! XRAY_INSTALLER=$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
     || [[ -z "$XRAY_INSTALLER" ]]; then
    error "无法下载 Xray 安装脚本，请检查服务器出网"
  fi
  if ! bash -c "$XRAY_INSTALLER" @ install --version "$XRAY_VERSION"; then
    warn "Xray ${XRAY_VERSION} 安装失败（该 tag 可能已下架），回退安装最新版"
    bash -c "$XRAY_INSTALLER" @ install || error "Xray 安装失败"
    XRAY_VERSION="latest"
  fi
  [[ -x /usr/local/bin/xray ]] || error "Xray 安装失败：未找到 /usr/local/bin/xray"

  step "出网预检"
  if ! check_outbound; then
    warn "服务器出网受限"
    read -rp "仍要继续安装？[y/N]: " C
    if [[ "${C,,}" != "y" ]]; then
      info "已取消"
      warn "Xray/Caddy 已安装但尚未生成配置，如需清理请使用菜单 [2] 卸载"
      INSTALL_DONE=1
      trap - EXIT
      return
    fi
  fi

  if [[ "$MODE" == "domain" ]]; then
    handle_common_occupiers
  else
    if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
      warn "端口 ${XRAY_PORT} 已被占用"
      read -rp "是否继续？[y/N]: " C
      if [[ "${C,,}" != "y" ]]; then
        info "已取消"
        INSTALL_DONE=1
        trap - EXIT
        return
      fi
    fi
  fi
  configure_log_retention

  step "放行防火墙端口"
  if [[ "$MODE" == "domain" ]]; then
    if [[ "$ACME_CHALLENGE" == "http" ]]; then
      open_firewall_port 80 "$XRAY_PORT"
    else
      open_firewall_port "$XRAY_PORT"
    fi
  else
    open_firewall_port "$XRAY_PORT"
  fi

  step "生成 Reality 密钥"
  generate_reality_keys
  info "PrivateKey: $PRIVATE_KEY"
  info "PublicKey : $PUBLIC_KEY"
  info "ShortId   : $SHORT_ID"

  step "创建初始用户"
  mkdir -p /etc/reality-caddy
  if [[ "${KEEP_USERS:-0}" == "1" && -s "$USERS_FILE" ]]; then
    info "保留已有用户"
  else
    : > "$USERS_FILE"
    printf '%s|%s|%s\n' "$UUID" "default" "初始用户" >> "$USERS_FILE"
    info "已创建默认用户 default"
  fi
  chmod 600 "$USERS_FILE"

  INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  # 覆盖重装保留原流量统计开关状态；完全重装默认开启
  if [[ "${KEEP_USERS:-0}" == "1" ]]; then
    TRAFFIC_STATS=${TRAFFIC_STATS:-1}
  else
    TRAFFIC_STATS=1
  fi

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
TRAFFIC_STATS="${TRAFFIC_STATS}"
CADDY_OWNED="${CADDY_OWNED:-0}"
INSTALL_TIME="${INSTALL_TIME}"
EOF
  chmod 600 "$INFO_FILE"

  if [[ "$MODE" == "domain" ]]; then
    step "配置 Caddy"
    mkdir -p /etc/caddy

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

    # 注意：srvh2 不要加 "proxy_protocol" 监听器包装器
    #   1) 该模块属于第三方（caddy.listeners.proxy_protocol），官方标准构建（apt 安装）里没有，
    #      加上会让 "caddy validate" 直接报 unknown module，导致整个安装中断；
    #   2) Xray 侧 xver=0 表示回源不带 PROXY protocol 头，两头本来也不匹配。
    #   回源只来自 127.0.0.1，去掉包装器没有任何安全损失。
    cat > /etc/caddy/caddy.json <<EOF
{
  "apps": {
    "http": {
      "servers": {
${SRVH1_BLOCK}        "srvh2": {
          ${AUTOHTTPS_LINE}
          "listen": ["127.0.0.1:8003"],
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
          "protocols": ["h1", "h2"]
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

    local VAL_ENV=()
    if [[ "$ACME_CHALLENGE" == "dns" ]]; then
      VAL_ENV=("CF_API_TOKEN=${CF_API_TOKEN}")
    fi
    if ! env "${VAL_ENV[@]}" "$CADDY_BIN" validate --config /etc/caddy/caddy.json >/tmp/caddy_validate.log 2>&1; then
      warn "Caddy 配置校验失败"
      cat /tmp/caddy_validate.log
      error "Caddy 配置校验失败"
    fi
    info "Caddy 配置校验通过"

    step "创建伪装站点"
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${SITE_TITLE:-Welcome}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 40px; background: #f5f5f5; color: #333; }
    .container { max-width: 600px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
    h1 { color: #2c3e50; }
  </style>
</head>
<body>
  <div class="container">
    <h1>${SITE_TITLE:-Welcome}</h1>
    <p>This is a normal website.</p>
  </div>
</body>
</html>
EOF

    cat > /etc/systemd/system/caddy-json.service <<EOF
[Unit]
Description=Caddy (JSON config)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=${CADDY_BIN} run --environ --config /etc/caddy/caddy.json
ExecReload=${CADDY_BIN} reload --config /etc/caddy/caddy.json
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment=CF_API_TOKEN=${CF_API_TOKEN:-}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now caddy-json.service
    info "Caddy 服务已启动"
  fi

  step "生成并启动 Xray"
  if rebuild_xray_config; then
    systemctl enable --now xray
    info "Xray 服务已启动"
  else
    error "Xray 配置生成失败"
  fi

  step "安装后自检"
  local SELFCHECK_FAIL=0

  if systemctl is-active --quiet xray; then
    info "xray 运行中"
  else
    warn "xray 未运行"
    SELFCHECK_FAIL=1
  fi

  if [[ "$MODE" == "domain" ]]; then
    if systemctl is-active --quiet caddy-json.service; then
      info "caddy-json 运行中"
    else
      warn "caddy-json 未运行"
      SELFCHECK_FAIL=1
    fi
  fi

  if ss -tlnp 2>/dev/null | grep -qE ":${XRAY_PORT}\b"; then
    info "端口 ${XRAY_PORT} 已监听"
  else
    warn "未发现端口 ${XRAY_PORT} 监听"
    SELFCHECK_FAIL=1
  fi

  if check_outbound; then
    info "出网正常"
  else
    SELFCHECK_FAIL=1
    warn "服务器出网受限"
  fi

  if [[ "$MODE" == "ip" && -n "${DEST_DOMAIN:-}" ]]; then
    if probe_dest_tls "$DEST_DOMAIN" 443; then
      info "dest 握手正常"
    else
      SELFCHECK_FAIL=1
      warn "dest 握手异常"
    fi
  fi

  if [[ $SELFCHECK_FAIL -eq 0 ]]; then
    info "自检全部通过"
  else
    warn "自检存在问题"
  fi

  echo
  show_client_info

  print_port_notice "$MODE" "$XRAY_PORT"

  if [[ "${TRAFFIC_STATS:-1}" == "1" ]]; then
    setup_traffic_timer
  else
    info "流量统计为关闭状态，跳过累计定时任务"
  fi

  INSTALL_DONE=1
  trap - EXIT
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
  warn "即将卸载（模式: ${MODE}）"
  read -rp "确认卸载？输入 yes 继续: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  # 不按 MODE 判断：切换过模式时旧服务可能还在，一律清干净
  if has_caddy_json_service; then
    info "清理 caddy-json.service"
    remove_caddy_json_service
  fi
  systemctl daemon-reload

  if [[ "$MODE" == "domain" ]] || [[ -d /etc/caddy ]]; then
    if dpkg -l 2>/dev/null | grep -q "^ii  caddy "; then
      apt-get purge -y caddy || true
    fi
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -rf /etc/caddy /var/lib/caddy
    # 只删本脚本装/编译的 Caddy；用户原本自装的保留
    if [[ "${CADDY_OWNED:-0}" == "1" ]]; then
      rm -f /usr/local/bin/caddy
    elif [[ -x /usr/local/bin/caddy ]]; then
      warn "保留了 /usr/local/bin/caddy（安装前已存在，非本脚本安装）"
    fi
  fi

  local XRAY_REMOVER
  if [[ -x /usr/local/bin/xray ]]; then
    if XRAY_REMOVER=$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
       && [[ -n "$XRAY_REMOVER" ]]; then
      bash -c "$XRAY_REMOVER" @ remove --purge || warn "Xray 官方卸载脚本执行失败，请手动清理"
    else
      warn "无法下载 Xray 卸载脚本，跳过；请手动删除 /usr/local/bin/xray"
    fi
  fi
  rm -rf /usr/local/etc/xray /var/log/xray

  read -rp "删除 /etc/reality-caddy ? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -rf /etc/reality-caddy && info "已删除"

  if [[ "$MODE" == "domain" && -d /var/www/html ]]; then
    read -rp "删除伪装站 /var/www/html ? [y/N]: " DEL
    [[ "${DEL,,}" == "y" ]] && rm -rf /var/www/html && info "已删除"
  fi

  systemctl disable --now xray-traffic-accumulate.timer 2>/dev/null || true
  systemctl disable --now xray-traffic-accumulate.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray-traffic-accumulate.service \
        /etc/systemd/system/xray-traffic-accumulate.timer

  systemctl disable --now xray-tg-report.timer 2>/dev/null || true
  systemctl disable --now xray-tg-report.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray-tg-report.service \
        /etc/systemd/system/xray-tg-report.timer

  # 清理定时任务助手脚本与 TG 定时启用标记
  rm -f "$TIMER_HELPER" "$TG_TIMER_ON_FILE"

  # 清理本脚本写入的日志相关配置（tmpfiles 规则 + journald 保留策略）
  rm -f /etc/tmpfiles.d/xray-log.conf
  if [[ -f /etc/systemd/journald.conf.d/99-retention.conf ]] \
     && grep -q 'Xray Reality' /etc/systemd/journald.conf.d/99-retention.conf 2>/dev/null; then
    rm -f /etc/systemd/journald.conf.d/99-retention.conf
  fi
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  systemctl daemon-reload 2>/dev/null || true

  info "卸载完成"
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
  if traffic_stats_on; then
    echo -e "  流量统计  : 开启"
  else
    echo -e "  流量统计  : 关闭"
  fi
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
# 四、显示客户端参数
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
    local u e n
    while IFS='|' read -r u e n; do
      UUIDS+=("$u")
      EMAILS+=("$e")
      printf "  %d) %-24s  %s  %s\n" "$i" "$e" "$u" "${n:-}"
      ((i++))
    done < <(list_user_records)
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
    # info.txt 里的伪装目标可能带着 https:// 前缀，分享链接里的 sni 必须是纯域名
    SNI=$(normalize_dest "${DEST_DOMAIN:-}" 2>/dev/null) || SNI="${DEST_DOMAIN:-}"
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
}

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

users_list_noread() {
  printf "  %-4s %-40s %-24s %s\n" "No." "UUID" "标识" "备注"
  line
  local i=1
  local u e n
  while IFS='|' read -r u e n; do
    printf "  %-4s %-40s %-24s %s\n" "$i" "$u" "${e:-}" "${n:-}"
    ((i++))
  done < <(list_user_records)
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
  # 用 local 声明，避免污染全局 EMAIL（do_install 里的 ACME 邮箱也叫 EMAIL）
  local EMAIL NOTE
  read -rp "  用户标识 email (可空): " EMAIL
  read -rp "  备注 note (可空): " NOTE
  EMAIL=${EMAIL:-user$(date +%s)@local}

  # users.txt 以 | 分隔，任一字段含 | 都会破坏整行结构（后面读配置时会解析错乱）
  if [[ "$EMAIL" == *"|"* || "$NOTE" == *"|"* ]]; then
    warn "email 和备注都不能包含竖线字符 |"
    read -rp "  按回车返回..." _
    return 1
  fi
  if [[ "$EMAIL" =~ [[:space:]] ]]; then
    warn "email 不能包含空格或制表符"
    read -rp "  按回车返回..." _
    return 1
  fi
  # Xray 要求同一 inbound 内 email 唯一，重复会导致流量统计串号
  if [[ -f "$USERS_FILE" ]] \
     && awk -F'|' -v e="$EMAIL" '$1 !~ /^[[:space:]]*#/ && $2 == e { f=1 } END { exit !f }' "$USERS_FILE"; then
    warn "email 已存在: ${EMAIL}"
    info "同一 email 的流量会被合并统计，请换一个标识"
    read -rp "  按回车返回..." _
    return 1
  fi

  mkdir -p "$(dirname "$USERS_FILE")"
  [[ -f "$USERS_FILE" ]] || : > "$USERS_FILE"

  local UUID before_size
  UUID=$(cat /proc/sys/kernel/random/uuid)
  before_size=$(wc -c < "$USERS_FILE")
  printf '%s|%s|%s\n' "$UUID" "$EMAIL" "$NOTE" >> "$USERS_FILE"
  info "已添加: $EMAIL ($UUID)"

  if rebuild_xray_config; then
    systemctl restart xray
    info "Xray 已重启"
  else
    # 按字节数精确回滚，避免末行无换行时 sed '$ d' 删错行
    truncate -s "$before_size" "$USERS_FILE" 2>/dev/null || sed -i '$ d' "$USERS_FILE"
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
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; return; }

  local total rec target_uuid target_email
  total=$(count_users)
  (( IDX < 1 || IDX > total )) && { warn "编号越界"; return; }

  # 编号 -> 记录 -> UUID，删除时按 UUID 精确匹配，避免行号错位删错人
  rec=$(list_user_records | sed -n "${IDX}p")
  target_uuid="${rec%%|*}"
  rec="${rec#*|}"
  target_email="${rec%%|*}"
  [[ -n "$target_uuid" ]] || { warn "未找到该用户"; return; }

  read -rp "确认删除 ${target_email} ? [y/N]: " C
  [[ "${C,,}" != "y" ]] && { info "已取消"; return; }

  cp "$USERS_FILE" "${USERS_FILE}.bak"
  awk -v u="$target_uuid" -F'|' '
    {
      x=$1
      gsub(/\r/, "", x)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", x)
      if (x == u) next
      print
    }
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
    # info.txt 里的伪装目标可能带着 https:// 前缀，分享链接里的 sni 必须是纯域名
    SNI=$(normalize_dest "${DEST_DOMAIN:-}" 2>/dev/null) || SNI="${DEST_DOMAIN:-}"
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
# 六、诊断自检
# ============================================================================
do_diagnose() {
  clear
  banner "诊断自检"
  if [[ ! -f "$INFO_FILE" ]]; then
    warn "未找到 $INFO_FILE"
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
  if systemctl is-active --quiet xray; then
    info "xray 运行中"
  else
    warn "xray 未运行"
  fi
  if [[ "$MODE" == "domain" ]]; then
    if systemctl is-active --quiet caddy-json.service; then
      info "caddy-json 运行中"
    else
      warn "caddy-json 未运行"
    fi
  fi

  echo
  echo -e "  ${BOLD}[2] 端口监听${NC}"
  ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\b" | sed 's/^/  /' \
    || warn "端口 ${XRAY_PORT} 未监听"

  echo
  echo -e "  ${BOLD}[3] 服务器出网${NC}"
  check_outbound || warn "出网受限"

  if [[ "$MODE" == "ip" && -n "$DEST_DOMAIN" ]]; then
    echo
    echo -e "  ${BOLD}[4] 伪装目标 TLS1.3 握手${NC}"
    if probe_dest_tls "$DEST_DOMAIN" 443; then
      info "握手正常"
    else
      warn "握手异常"
    fi
  fi

  echo
  echo -e "  ${BOLD}[5] 密钥${NC}"
  echo -e "  PublicKey: ${PUBLIC_KEY:-空}  (长度 ${#PUBLIC_KEY})"
  echo -e "  ShortId  : ${SHORT_ID:-空}"

  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 七、用户流量统计
# ============================================================================
do_traffic() {
  clear
  banner "用户流量统计（按月）"
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  ensure_python3 || { read -rp "  按回车返回..." _; return; }

  load_kv "$INFO_FILE" 2>/dev/null || true

  if ! grep -q '"stats"' "$XRAY_CONF" 2>/dev/null; then
    warn "当前 Xray 配置未启用流量统计（可在 [9] 流量开关中开启）"
    read -rp "  是否现在重建配置并重启 Xray 以启用？[y/N]: " C
    if [[ "${C,,}" == "y" ]]; then
      set_info_value TRAFFIC_STATS 1
      TRAFFIC_STATS=1
      if rebuild_xray_config; then
        systemctl restart xray
        info "配置已重建，Xray 已重启"
        ensure_timer_units
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

  info "正在查询并累计流量数据..."
  accumulate_traffic_silent || warn "本次累计可能失败"

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

monthly = defaultdict(lambda: defaultdict(lambda: {"uplink": 0, "downlink": 0}))
for rec in daily:
    date = rec.get("date", "")
    if len(date) < 7:
        continue
    month = date[:7]
    for email, d in rec.get("users", {}).items():
        monthly[month][email]["uplink"] += d.get("uplink", 0)
        monthly[month][email]["downlink"] += d.get("downlink", 0)

months = sorted(monthly.keys(), reverse=True)

def display_width(s):
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

print("  【总累计（自安装以来）】")
print()
active_emails = [e for e in set(list(cumulative.keys()) + list(email_to_note.keys()))
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
  if systemctl is-active --quiet xray-traffic-accumulate.timer 2>/dev/null; then
    echo -e "  ${DIM}每小时自动累计: 已启用（systemd timer）${NC}"
  else
    echo -e "  ${DIM}每小时自动累计: 未启用（可在 [9] 流量开关中开启）${NC}"
  fi
  echo
  read -rp "  按回车返回主菜单..." _
}

# ============================================================================
# 静默累计流量
# ============================================================================
accumulate_traffic_silent() {
  # 统一复用固定助手脚本，避免主脚本与助手脚本存在两套统计逻辑（易漂移、易漏修）
  if [[ ! -x "$TIMER_HELPER" ]]; then
    install_timer_helper || return 1
  fi
  [[ -x "$TIMER_HELPER" ]] || return 1
  "$TIMER_HELPER" --accumulate
}

# ============================================================================
# 写入流量累计 systemd 单元（service + timer）
# ============================================================================
write_traffic_units() {
  cat > /etc/systemd/system/xray-traffic-accumulate.service <<EOF
[Unit]
Description=Xray Reality Traffic Accumulate
After=xray.service

[Service]
Type=oneshot
ExecStart=${TIMER_HELPER} --accumulate
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
}

# ============================================================================
# 写入 TG 日报 systemd 单元（service + timer）
# ============================================================================
write_tg_units() {
  cat > /etc/systemd/system/xray-tg-report.service <<EOF
[Unit]
Description=Xray Reality Telegram Daily Report
After=network-online.target

[Service]
Type=oneshot
ExecStart=${TIMER_HELPER} --tg-report
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
}

# ============================================================================
# 安装每小时流量累计定时任务（使用固定助手脚本）
# ============================================================================
setup_traffic_timer() {
  install_timer_helper
  write_traffic_units

  systemctl daemon-reload
  systemctl enable --now xray-traffic-accumulate.timer >/dev/null 2>&1 || true
  info "已启用每小时自动累计流量定时任务（独立助手）"
}

# ============================================================================
# Telegram 相关函数（简化版，完整逻辑在助手脚本中）
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
  local text="$1" resp
  load_tg_conf || return 1
  # -f：HTTP 4xx/5xx 也返回非 0；再校验 "ok":true，避免 Token/Chat ID 错误被当成发送成功
  resp=$(curl -s -f --max-time 20 -X POST \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" 2>/dev/null) || return 1
  case "$resp" in
    *'"ok":true'*) return 0 ;;
    *) return 1 ;;
  esac
}

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
        warn "发送失败"
      fi
      ;;
    3)
      # 助手脚本缺失时按需生成，避免手动日报因文件丢失而失败
      [[ -x "$TIMER_HELPER" ]] || install_timer_helper
      if "$TIMER_HELPER" --tg-report; then
        info "日报已发送"
      else
        warn "发送失败，请检查 Bot Token / Chat ID（返回菜单 [8] 重新配置）"
      fi
      ;;
    4)
      setup_tg_timer
      ;;
    5)
      systemctl disable --now xray-tg-report.timer 2>/dev/null || true
      rm -f "$TG_TIMER_ON_FILE"
      info "已关闭自动日报"
      ;;
  esac
  echo
  read -rp "  按回车返回..." _
}

setup_tg_timer() {
  install_timer_helper
  write_tg_units

  systemctl daemon-reload
  systemctl enable --now xray-tg-report.timer >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$TG_TIMER_ON_FILE")"
  : > "$TG_TIMER_ON_FILE"
  info "已启用每天 01:00 自动发送 Telegram 日报（独立助手）"
}

# ============================================================================
# 更新 info.txt 中的单个键值（不存在则追加）
# ============================================================================
set_info_value() {
  local key="$1" val="$2"
  [[ -f "$INFO_FILE" ]] || return 1
  if grep -qE "^${key}=" "$INFO_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$INFO_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$INFO_FILE"
  fi
}

# ============================================================================
# 流量统计是否真的开启（开关状态 + 配置内实际存在 stats 段）
# ============================================================================
traffic_stats_on() {
  [[ "${TRAFFIC_STATS:-1}" == "1" ]] || return 1
  grep -q '"stats"' "$XRAY_CONF" 2>/dev/null
}

# ============================================================================
# 流量统计开关
#   只在“开启 / 关闭流量统计”时校验并修复定时任务，不再每次进主菜单都跑
# ============================================================================
do_traffic_toggle() {
  clear
  banner "流量统计开关"
  if ! is_installed; then
    warn "尚未安装"
    read -rp "  按回车返回..." _
    return
  fi

  load_kv "$INFO_FILE" 2>/dev/null || true
  TRAFFIC_STATS=${TRAFFIC_STATS:-1}

  local current="关闭"
  traffic_stats_on && current="开启"

  echo
  echo -e "  当前状态：${BOLD}${current}${NC}"
  line
  mi 1 "开启流量统计" "启用统计 + 每小时累计 + 可查看报表"
  mi 2 "关闭流量统计" "停止统计并清理定时任务"
  line
  mi 0 "返回" "返回主菜单"
  echo
  read -rp "  请选择 [0-2]: " T

  case "$T" in
    1)
      # 先落盘开关状态，重建配置时按此值决定是否写入 stats / api 段
      set_info_value TRAFFIC_STATS 1
      TRAFFIC_STATS=1

      if rebuild_xray_config; then
        systemctl restart xray
        info "校验流量统计定时任务（助手脚本 + systemd 单元）..."
        ensure_timer_units
        info "流量统计已开启"
      else
        warn "开启失败，流量统计仍为关闭状态"
      fi
      ;;
    2)
      read -rp "  确认关闭流量统计？[y/N]: " C
      if [[ "${C,,}" != "y" ]]; then
        info "已取消"
      else
        set_info_value TRAFFIC_STATS 0
        TRAFFIC_STATS=0

        if rebuild_xray_config; then
          systemctl restart xray
          # 统计已关闭：累计与日报定时任务一并停用（历史数据保留）
          systemctl disable --now xray-traffic-accumulate.timer >/dev/null 2>&1 || true
          systemctl disable --now xray-tg-report.timer >/dev/null 2>&1 || true
          rm -f "$TG_TIMER_ON_FILE"
          info "流量统计已关闭，累计与日报定时任务已停止"
          echo -e "  ${DIM}历史流量数据保留在 ${TRAFFIC_FILE}${NC}"
        else
          set_info_value TRAFFIC_STATS 1
          TRAFFIC_STATS=1
          warn "关闭失败，已恢复为开启状态"
        fi
      fi
      ;;
    *)
      info "已取消"
      ;;
  esac
  echo
  read -rp "  按回车返回..." _
}

# ============================================================================
# 校验并修复定时任务（助手脚本 + systemd 单元）
#   仅在“流量统计开启”时调用：
#     - 助手脚本缺失 / 不可执行 / 内容异常 → 重新生成
#     - 单元缺失 或 ExecStart 路径不对     → 重建并重新启用
#     - 用户启用过 TG 日报               → 一并检查修复
#   用法：ensure_timer_units
# ============================================================================
ensure_timer_units() {
  [[ -f "$INFO_FILE" ]] || return 0
  [[ "${TRAFFIC_STATS:-1}" == "1" ]] || return 0

  local need_reload=0
  local SVC=/etc/systemd/system/xray-traffic-accumulate.service
  local TMR=/etc/systemd/system/xray-traffic-accumulate.timer

  # 1) 助手脚本：存在 + 可执行 + 内容可辨认
  if [[ ! -s "$TIMER_HELPER" || ! -x "$TIMER_HELPER" ]] \
     || ! grep -q -- '--accumulate' "$TIMER_HELPER" 2>/dev/null; then
    info "定时助手脚本缺失或异常，正在重建: ${TIMER_HELPER}"
    install_timer_helper
    need_reload=1
  fi

  # 2) 流量累计单元：缺失或路径错误 → 重建
  if [[ ! -f "$SVC" || ! -f "$TMR" ]]; then
    info "流量累计定时任务缺失，正在重建..."
    write_traffic_units
    need_reload=1
  elif ! grep -qE "^ExecStart=${TIMER_HELPER} --accumulate$" "$SVC" 2>/dev/null; then
    info "流量累计定时任务路径异常，正在修复..."
    write_traffic_units
    need_reload=1
  fi

  # 3) TG 日报单元：仅用户启用过（有标记，或 timer 仍处于启用状态）才检查修复
  local tg_on=0
  if [[ -f "$TG_TIMER_ON_FILE" ]]; then
    tg_on=1
  elif systemctl is-enabled --quiet xray-tg-report.timer 2>/dev/null; then
    tg_on=1
    mkdir -p "$(dirname "$TG_TIMER_ON_FILE")"
    : > "$TG_TIMER_ON_FILE"
  fi

  if [[ $tg_on -eq 1 && -f "$TG_CONF" ]]; then
    local TSVC=/etc/systemd/system/xray-tg-report.service
    local TTMR=/etc/systemd/system/xray-tg-report.timer
    if [[ ! -f "$TSVC" || ! -f "$TTMR" ]]; then
      info "TG 日报定时任务缺失，正在重建..."
      write_tg_units
      need_reload=1
    elif ! grep -qE "^ExecStart=${TIMER_HELPER} --tg-report$" "$TSVC" 2>/dev/null; then
      info "TG 日报定时任务路径异常，正在修复..."
      write_tg_units
      need_reload=1
    fi
  fi

  [[ $need_reload -eq 1 ]] && systemctl daemon-reload

  # 4) 确保已启用且正在运行
  if ! systemctl is-enabled --quiet xray-traffic-accumulate.timer 2>/dev/null \
     || ! systemctl is-active --quiet xray-traffic-accumulate.timer 2>/dev/null; then
    info "正在启用流量累计定时任务..."
    systemctl enable --now xray-traffic-accumulate.timer >/dev/null 2>&1 || true
  fi
  if [[ $tg_on -eq 1 && -f "$TG_CONF" ]] \
     && ! systemctl is-enabled --quiet xray-tg-report.timer 2>/dev/null; then
    info "正在启用 TG 日报定时任务..."
    systemctl enable --now xray-tg-report.timer >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# 主循环
# ============================================================================
if [[ "$ACCUMULATE_MODE" == "1" ]]; then
  accumulate_traffic_silent
  exit $?
fi

if [[ "$TG_REPORT_MODE" == "1" ]]; then
  if [[ -x "$TIMER_HELPER" ]]; then
    "$TIMER_HELPER" --tg-report
    exit $?
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
    9) do_traffic_toggle ;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
done
