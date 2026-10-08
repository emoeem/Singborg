#!/usr/bin/env bash
# =============================================================================
#  sing-box 审计 · 加固 · 优化  ——  apply-hardening-2026-10-08.sh
#  对象: /etc/sing-box/config.json  (sing-box v1.14.2-reF1nd + systemd)
#  用法: sudo bash apply-hardening-2026-10-08.sh [选项]
#    --dry-run       只生成候选配置 + sing-box check + 打印 diff；不落盘、不重启
#    --keep-cors     跳过 CORS 收紧（保留 allow_origin ["*"] 与 allow_private_network）
#    --no-routing    跳过 Auto / Auto-Japan / Download 的选路调整
#    --no-retention  跳过备份权限加固与归档
#    --harden-cache-db  额外把 cache_file 的 DNS 缓存 DB 权限收紧到 600
#    -h, --help      显示本帮助
#  注意: 为做一次「无资源冲突」的 sing-box check，脚本会短暂停服（约 5~10 秒），
#        校验通过后立即以新配置启动；dry-run 同样会停服再按原配置拉起。
#  安全约定: 任一步失败 -> 自动用本次备份回滚并重启服务，并打印手动回滚命令。
# =============================================================================
set -Eeuo pipefail

CONF_DIR=/etc/sing-box
CONF=/etc/sing-box/config.json
BAK_DIR=/etc/sing-box/backups
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=${DROPIN_DIR}/20-network-online.conf
UNIT=sing-box
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=${CONF_DIR}/config.json.bak.${TS}
NEWCFG=$(mktemp /tmp/sing-box-new.XXXXXX.json)
OLDCFG=$(mktemp /tmp/sing-box-old.XXXXXX.json)
DIFF=$(mktemp /tmp/sing-box-diff.XXXXXX.txt)
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
DRY_RUN=0
KEEP_CORS=0
DO_ROUTING=1
DO_RETENTION=1
HARDEN_CACHE_DB=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --keep-cors)    KEEP_CORS=1 ;;
    --no-routing)   DO_ROUTING=0 ;;
    --no-retention) DO_RETENTION=0 ;;
    --harden-cache-db) HARDEN_CACHE_DB=1 ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *)              echo "未知参数: $arg"; sed -n '2,14p' "$0"; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '   \033[31m✘\033[0m %s\n' "$*"; }
mask() { sed -E 's/("secret"[[:space:]]*:[[:space:]]*")[^"]*(")/\1******\2/g'; }

SERVICE_DOWN=0
cleanup() {
  rm -f "$NEWCFG" "$OLDCFG" "$DIFF"
  if [ "$SERVICE_DOWN" = 1 ] && ! systemctl is-active --quiet "$UNIT"; then
    printf '\n\033[33m!\033[0m 脚本退出时服务处于停止状态，正在按当前配置恢复...\n'
    systemctl start "$UNIT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rollback() {
  local why="$1" i
  printf '\n\033[1;31m!! 触发回滚: %s\033[0m\n' "$why" >&2
  install -m 600 -o root -g root "$OLDCFG" "$CONF_DIR/.config.json.ROLLBACK"
  mv -f "$CONF_DIR/.config.json.ROLLBACK" "$CONF"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do systemctl is-active --quiet "$UNIT" && break; sleep 1; done
  if systemctl is-active --quiet "$UNIT"; then
    printf '   已回滚，服务恢复运行。配置来自: %s\n' "$BACKUP" >&2
  else
    printf '   回滚后服务仍未运行！请手动排查:\n' >&2
    printf '     journalctl -u %s -n 120 --no-pager\n' "$UNIT" >&2
    printf '     sudo install -m 600 -o root -g root %s %s && sudo systemctl restart %s\n' "$BACKUP" "$CONF" "$UNIT" >&2
  fi
  exit 1
}

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 运行: sudo bash $0"; exit 2; }
for c in python3 jq curl ss sing-box; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; exit 2; }
done
[ -f "$CONF" ] || { echo "找不到 $CONF"; exit 2; }
exec 9>/run/singbox-apply.lock
flock -n 9 || { echo "已有另一个实例在运行（/run/singbox-apply.lock）"; exit 2; }
mkdir -p "$BAK_DIR"

# ---------------------------------------------------------------- 0 备份
log "0/7  前置备份"
install -m 600 -o root -g root "$CONF" "$BACKUP"
install -m 600 -o root -g root "$CONF" "$OLDCFG"
ok "正式备份: $BACKUP  ($(stat -c%s "$BACKUP") B, mode $(stat -c%a "$BACKUP"))"
ok "回滚副本: $OLDCFG （/tmp，与配置目录解耦）"

# ---------------------------------------------------- 1 备份加固与归档
if [ "$DO_RETENTION" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  log "1/7  备份权限加固与归档"
  chmod 700 "$BAK_DIR"
  find "$CONF_DIR" -maxdepth 1 -type f -name 'config.json.bak.*' -exec chmod 600 {} +
  find "$BAK_DIR"    -maxdepth 1 -type f -name '*.json'          -exec chmod 600 {} +
  ok "$BAK_DIR -> 700；所有备份文件 -> 600"

  mapfile -t STALE < <(python3 - <<'PYEOF'
import glob, os, time
now = time.time()
stale = []
for d in ("/etc/sing-box", "/etc/sing-box/backups"):
    files = [p for p in glob.glob(os.path.join(d, "config*.json"))
             if os.path.isfile(p) and not os.path.basename(p).startswith("archive-")]
    files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in files[10:]:
        if now - os.path.getmtime(p) < 7 * 86400:
            continue
        stale.append(p)
print("\n".join(stale))
PYEOF
)
  if [ "$(printf '%s' "${STALE[*]:-}")" != "" ]; then
    ARCHIVE="$BAK_DIR/archive-pre-$TS.tar.gz"
    tar -czf "$ARCHIVE" "${STALE[@]}" 2>/dev/null
    chmod 600 "$ARCHIVE"
    if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
      n=0
      for f in "${STALE[@]}"; do rm -f -- "$f"; n=$((n+1)); done
      ok "归档 $n 个旧备份 -> $ARCHIVE（归档已校验可读，原件删除）"
    else
      warn "归档校验失败，保留原文件未删除"; rm -f "$ARCHIVE"
    fi
  else
    ok "无需归档（策略：每目录保留最新 10 份，且 7 天内的不归档）"
  fi
fi

# -------------------------------------------- 1b 可选: 加固 DNS 缓存文件权限
# 默认关闭（不在已批准的变更清单内）。加 --harden-cache-db 启用。
# experimental.cache_file 的 DB 在 store_dns=true 时含本机 DNS 查询历史，
# 实测为 644 root:root，本机任意用户可读。
if [ "$HARDEN_CACHE_DB" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  CACHE_DB=$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("experimental",{}).get("cache_file",{}) or {}).get("path",""))' "$CONF")
  if [ -n "$CACHE_DB" ] && [ -f "$CACHE_DB" ]; then
    before=$(stat -c%a "$CACHE_DB")
    chmod 600 "$CACHE_DB"
    ok "cache_file 权限加固: $CACHE_DB  $before -> $(stat -c%a "$CACHE_DB")"
  else
    warn "未找到 cache_file 路径（读到: '$CACHE_DB'），跳过"
  fi
fi

# ------------------------------------------------------ 2 生成候选配置
log "2/7  生成候选配置（Python 原地改写，仅动目标字段）"
KEEP_CORS="$KEEP_CORS" DO_ROUTING="$DO_ROUTING" python3 - "$CONF" > "$NEWCFG" <<'PYEOF'
import json, os, secrets, sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
keep_cors = os.environ["KEEP_CORS"] == "1"
do_routing = os.environ["DO_ROUTING"] == "1"
ch = []

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})

old = clash.get("secret", "")
clash["secret"] = secrets.token_urlsafe(32)
ch.append("experimental.clash_api.secret: %d 字符 -> 新随机 %d 字符" % (len(old), len(clash["secret"])))

for svc in cfg.get("services") or []:
    if svc.get("type") == "api":
        o = svc.get("secret", "")
        svc["secret"] = secrets.token_urlsafe(32)
        ch.append("services[type=api].secret: %d 字符 -> 新随机 %d 字符（与 clash_api 不同值）"
                  % (len(o), len(svc["secret"])))

if not keep_cors:
    old_origin = clash.get("access_control_allow_origin")
    clash["access_control_allow_origin"] = ["http://127.0.0.1:9096", "http://localhost:9096"]
    ch.append("clash_api.access_control_allow_origin: %s -> ['http://127.0.0.1:9096', 'http://localhost:9096']"
              % json.dumps(old_origin, ensure_ascii=False))
    if clash.pop("access_control_allow_private_network", None) is not None:
        ch.append("clash_api: 移除 access_control_allow_private_network")

before = len(cfg.get("outbounds") or [])
cfg["outbounds"] = [o for o in (cfg.get("outbounds") or [])
                    if not (o.get("type") == "block" and o.get("tag") == "block")]
if len(cfg["outbounds"]) != before:
    ch.append("移除未被任何规则引用的 outbound「block」（route 第 5 条已用 action:reject）")

if do_routing:
    DL = "\U0001F1EF\U0001F1F5 日本Z05 | 下载专用"
    for o in cfg["outbounds"]:
        if o.get("tag") == "Download" and o.get("type") == "selector":
            if DL in (o.get("outbounds") or []) and o.get("default") != DL:
                ch.append("Download.default: %s -> %s" % (o.get("default"), DL))
                o["default"] = DL
    for tag in ("Auto", "Auto-Japan"):
        for o in cfg["outbounds"]:
            if o.get("tag") == tag and o.get("type") == "urltest" and DL in (o.get("outbounds") or []):
                n = len(o["outbounds"])
                o["outbounds"] = [x for x in o["outbounds"] if x != DL]
                ch.append("%s: 剔除下载专用节点, %d -> %d 个候选" % (tag, n, len(o["outbounds"])))

sys.stderr.write("   变更清单:\n")
for c in ch:
    sys.stderr.write("     - %s\n" % c)
if not ch:
    sys.stderr.write("     （无）\n")
sys.stdout.write(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
PYEOF

# --------------------------------------------------------- 3 校验
log "3/7  校验候选配置（先停服，避免与在跑的 eBPF 实例争用 BPF 资源）"
SERVICE_DOWN=1
systemctl stop "$UNIT" || true
for i in $(seq 1 15); do systemctl is-active --quiet "$UNIT" || break; sleep 1; done
if systemctl is-active --quiet "$UNIT"; then
  bad "服务停止失败；未改动任何文件"
  SERVICE_DOWN=0
  exit 1
fi
ok "服务已停止（停机窗口预计 5~10 秒）"

if sing-box check -c "$NEWCFG"; then
  ok "sing-box check 通过"
else
  bad "sing-box check 失败 —— 现网配置未被改动，正在按原配置恢复服务"
  systemctl start "$UNIT" >/dev/null 2>&1 || true
  SERVICE_DOWN=0
  exit 1
fi

diff -u --label "a/config.json (现网)" --label "b/config.json (候选)" "$OLDCFG" "$NEWCFG" > "$DIFF" || true

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: 候选 diff（密钥已打码）"
  mask < "$DIFF"
  systemctl start "$UNIT" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do systemctl is-active --quiet "$UNIT" && break; sleep 1; done
  SERVICE_DOWN=0
  if systemctl is-active --quiet "$UNIT"; then
    ok "已在原配置上恢复服务"
  else
    warn "服务未恢复，请手动: sudo systemctl start $UNIT"
  fi
  printf '\n'; ok "dry-run 结束；正式配置未改动"
  exit 0
fi

# --------------------------------------------------------- 4 落盘
log "4/7  原子替换正式配置"
install -m 600 -o root -g root "$NEWCFG" "$CONF_DIR/.config.json.new"
mv -f "$CONF_DIR/.config.json.new" "$CONF"
ok "$CONF 已更新（mode $(stat -c%a "$CONF"), $(stat -c%s "$CONF") B）"

log "5/7  systemd drop-in：补 Wants=network-online.target"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<'EOF'
# 2026-10-08 审计新增: 原 unit 只有 After=network-online.target，没有 Wants=。
# After= 只排序、不把 target 拉进事务；该 target 缺席时启动早期会出现
# "network: missing default interface"（journalctl 2026-10-07 12:53 / 17:08）。
[Unit]
Wants=network-online.target
EOF
chmod 644 "$DROPIN"
systemctl daemon-reload
ok "$DROPIN （删除该文件后 daemon-reload 即恢复原状）"

# --------------------------------------------------------- 6 重启+验证
log "6/7  按新配置启动并验证"
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
if ! systemctl start "$UNIT"; then rollback "systemctl start $UNIT 返回非 0"; fi
i=""
for i in $(seq 1 30); do systemctl is-active --quiet "$UNIT" && break; sleep 1; done
systemctl is-active --quiet "$UNIT" || rollback "服务 30 秒内未进入 active"
SERVICE_DOWN=0

# 等待端口真正进入监听：Type=simple 下 systemctl is-active 会立刻返回 active，
# 而 sing-box 还需加载 17 个 rule-set 与 eBPF 程序（实测数秒）。
# 2026-10-08 首次执行正因缺少这段等待，把「仍在启动」误判为失败并触发了一次
# 不必要的回滚（候选配置本身已通过 sing-box check）。
missing=""; waited=0
for i in $(seq 1 60); do
  missing=""
  for p in 7892 9090 9091; do ss -ltnH | grep -q "127.0.0.1:$p " || missing="$missing $p"; done
  if [ -z "$missing" ]; then break; fi
  if ! systemctl is-active --quiet "$UNIT"; then break; fi
  sleep 1
  waited=$i
done
if [ -n "$missing" ]; then
  warn "启动 60 秒后端口仍未监听:$missing"
  printf '   ---- 新实例日志（末 40 行）----\n'
  journalctl -u "$UNIT" --since "$START_TS" --no-pager 2>/dev/null | tail -40
  printf '   ------------------------------\n'
  rollback "端口未监听:$missing"
fi
ok "服务 active；监听 127.0.0.1:{7892,9090,9091} 正常（绑定等待 ${waited}s）"

ERRN=$(journalctl -u "$UNIT" --since "$START_TS" --no-pager 2>/dev/null | grep -c 'ERROR' || true)
if [ "$ERRN" = 0 ]; then ok "启动后无 ERROR 日志"; else warn "启动后有 $ERRN 条 ERROR: journalctl -u $UNIT --since '$START_TS'"; fi

NEW_CLASH=$(jq -r '.experimental.clash_api.secret' "$CONF")
NEW_API=$(jq -r '.services[] | select(.type=="api") | .secret' "$CONF")
OLD_CLASH=$(jq -r '.experimental.clash_api.secret' "$OLDCFG")

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $NEW_CLASH" http://127.0.0.1:9090/version || true)
[ "$code" = 200 ] || rollback "Clash API 用新密钥访问失败 (HTTP $code)"
ok "9090 Clash API: 新密钥 HTTP 200"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OLD_CLASH" http://127.0.0.1:9090/version || true)
if [ "$code" = 200 ]; then warn "旧密钥仍可用（预期 401）"; else ok "9090: 旧密钥已失效 (HTTP $code)"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/version || true)
if [ "$code" = 401 ]; then ok "9090: 无密钥被拒 (401)"; else warn "9090 无密钥返回 $code"; fi

if [ "$KEEP_CORS" = 0 ]; then
  hdr=$(curl -s -D- -o /dev/null -H 'Origin: http://127.0.0.1:9096' http://127.0.0.1:9090/version | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)
  case "$hdr" in
    *127.0.0.1:9096*) ok "CORS: 本机面板源已放行  ($hdr)" ;;
    *)                warn "CORS: 面板源未获放行  ($hdr)" ;;
  esac
  evil=$(curl -s -D- -o /dev/null -H 'Origin: https://evil.example' http://127.0.0.1:9090/version | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)
  case "$evil" in
    *evil.example*|*'*'*) warn "CORS: 外部源仍被放行  ($evil)" ;;
    *)                    ok "CORS: 外部源不再获得放行头" ;;
  esac
fi

code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9096/ || true)
if [ "$code" = 200 ]; then ok "管理面板 9096 正常"; else warn "管理面板 9096 返回 $code"; fi

PT=$(cat /var/lib/sing-box-panel/token 2>/dev/null || true)
if [ -n "$PT" ]; then
  if curl -s -H "X-Panel-Token: $PT" http://127.0.0.1:9096/api/state | jq -e --arg s "$NEW_CLASH" '..|strings|select(.==$s)' >/dev/null 2>&1; then
    ok "面板已读到新密钥（zashboard 深链会自动带上，无需手输）"
  else
    warn "面板 /api/state 未见新密钥，刷新面板页确认"
  fi
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x http://127.0.0.1:7892 https://www.gstatic.com/generate_204 || true)
if [ "$code" = 204 ]; then ok "代理链路 127.0.0.1:7892 -> 204"; else warn "代理链路返回 $code"; fi

# --------------------------------------------------------- 7 汇总
log "7/7  完成"
printf '   备份     : %s\n' "$BACKUP"
printf '   变更 diff:\n'
mask < "$DIFF"
printf '\n   回滚一行 : sudo install -m 600 -o root -g root %s %s && sudo systemctl restart %s\n' "$BACKUP" "$CONF" "$UNIT"
printf '   drop-in  : %s\n' "$DROPIN"
printf '   新密钥   : clash_api=%s…（%s 字符） services.api=%s…（%s 字符，独立值）\n' \
       "$(printf '%s' "$NEW_CLASH" | cut -c1-6)" "${#NEW_CLASH}" "$(printf '%s' "$NEW_API" | cut -c1-6)" "${#NEW_API}"
printf '   取完整值 : sudo jq -r .experimental.clash_api.secret %s\n' "$CONF"
printf '   下一步   : sudo bash test-singbox-2026-10-08.sh\n'
