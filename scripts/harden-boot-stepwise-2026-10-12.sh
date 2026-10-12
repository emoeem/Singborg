#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# harden-boot-stepwise-2026-10-12.sh   （v1，2026-10-12）
#
# 目的：把 docs/11 P2-2 与 docs/12 R1 的加固，按"一步一确认"的节奏落地；并采集
#       "重启后 0–5 分钟网络是否稳定"的证据（任务第 5 项唯一还没定论的部分）。
#
# 四个步骤：
#   step1  /var/lib/sing-box/cache.db → 0600     P2-2：store_dns=true 会把 DNS 查询落盘，
#                                                而该文件曾是 0644（同机任意用户可读）
#   step2  安装 systemd/40-libvirtd-order.conf   P2-4/R1：让 sing-box 排在 libvirtd 之后启动，
#                                                关掉 virbr0（=192.168.122.1）就绪前的空窗
#   step3  安装 systemd/30-umask-hardening.conf  P2-2：UMask=0077 / StateDirectoryMode=0750，
#                                                防止今后新建的文件又变回 0644
#   step4  写"重启前标记"，然后由你重启；重启后跑 --post-reboot 出证据报告
#
# 关键设计（为什么这样最安全）：
#   * step2/step3 **不重启服务**。After= / Wants= / UMask= / StateDirectoryMode= 都由
#     daemon-reload 载入，在下一次启动（也就是 step4 那次重启）才起作用 ——
#     因此整个加固过程不会打断正在运行的代理。
#   * 默认交互式：每一步先打印"将要执行的命令"，再等你输入 y/N（默认 N）。--dry-run 只看不做；
#     --yes 无人值守（仅在你清楚后果时用）。
#   * 幂等：cache.db 已是 0600、drop-in 内容已一致 → 识别并跳过，重复运行无副作用。
#   * 失败回滚：安装步骤出错会自动删掉刚装的文件并 daemon-reload。
#   * --post-reboot 采集：本 boot 的 0–5 分钟窗口内 sing-box 与整机告警、各单元就绪时刻、
#     开机链路、端口/代理/DNS 健康检查，并与重启前标记逐项对比。
#
# 用法：
#   bash scripts/harden-boot-stepwise-2026-10-12.sh --preflight      # 只读体检，不需要 root
#   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --dry-run  # 打印全部计划，不写任何文件
#   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh            # 交互式走完 step1→step4
#   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --step2 --step3
#   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --post-reboot --out /tmp/reboot-report.txt
#   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --rollback
#
# 退出码：0 = 成功/无需改动；1 = 失败（安装模式下已自动回滚）
# ===== END HELP =====
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
CAND_ORDER="$REPO_DIR/systemd/40-libvirtd-order.conf"
CAND_UMASK="$REPO_DIR/systemd/30-umask-hardening.conf"
TARGET_ORDER="$DROPIN_DIR/40-libvirtd-order.conf"
TARGET_UMASK="$DROPIN_DIR/30-umask-hardening.conf"
STATE_DIR="/var/lib/sing-box"
CACHE_DB="$STATE_DIR/cache.db"
SERVICE="sing-box"
MARKER="/var/tmp/singbox-reboot-marker.env"
PROXY="http://127.0.0.1:7892"
PORTS=(7892 9090 9091)
WINDOW=300                      # 开机观察窗口（秒）
INSTALLED_THIS_RUN=""

DRY=0; YES=0; FORCE=0; RESTORE_PERMS=0; OUT_FILE=""
WANT_PREFLIGHT=0; WANT_POST=0; WANT_ROLLBACK=0
RUN_STEPS=()

# ---------------------------------------------------------------- 输出/交互 --
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*"; }
note() { printf '\033[35mnote\033[0m %s\n' "$*"; }

# 报告同时上屏 +（可选）落盘，落盘时剥掉 ANSI 颜色
emit() {
  printf '%s\n' "$*"
  if [ -n "$OUT_FILE" ]; then printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >>"$OUT_FILE"; fi
}
section() { emit ""; emit "$(info "──────── $* ────────")"; }

# 真正执行变更的唯一入口：dry-run 只打印；否则要求 root
mutate() {
  if [ "$DRY" = 1 ]; then note "[dry-run] 不执行： $*"; return 0; fi
  [ "$(id -u)" -eq 0 ] || die "这一步需要 root：请用 sudo 运行本脚本（将要执行：$*）"
  "$@"
}

confirm_or_skip() {
  local msg="$1" a=""
  if [ "$DRY" = 1 ]; then note "[dry-run] $msg"; return 0; fi
  if [ "$YES" = 1 ]; then note "--yes：自动确认（$msg）"; return 0; fi
  if [ ! -t 0 ]; then
    warn "stdin 不是终端，为安全默认不执行 → $msg"
    note "要无人值守请显式加 --yes"
    return 1
  fi
  printf '  \033[1m%s\033[0m [y/N] ' "$msg"
  read -r a || true
  case "$a" in y|Y|yes|YES|Yes) return 0 ;; *) warn "已跳过 → $msg"; return 1 ;; esac
}

on_err() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$INSTALLED_THIS_RUN" ]; then
    warn "本步骤失败，自动回滚：删除 $INSTALLED_THIS_RUN"
    rm -f "$INSTALLED_THIS_RUN" || true
    systemctl daemon-reload || true
    INSTALLED_THIS_RUN=""
  fi
  exit "$rc"
}
trap on_err ERR

# ------------------------------------------------------------------ 小工具 --
hms() { printf '%dm%02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; }
file_mode() { stat -c %a "$1" 2>/dev/null || echo '?'; }
port_listening() { ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE ":$1\$"; }
unit_field() { systemctl show -p "$2" --value "$1" 2>/dev/null || true; }
unit_line() {
  printf '%s/%s  %s' \
    "$(unit_field "$1" ActiveState)" "$(unit_field "$1" SubState)" \
    "$(unit_field "$1" ActiveEnterTimestamp)"
}
dropin_list() { ls -1 "$DROPIN_DIR" 2>/dev/null | tr '\n' ' ' || true; }
marker_get() { [ -f "$MARKER" ] && grep -m1 "^$1=" "$MARKER" 2>/dev/null | cut -d= -f2- || true; }

health_check() {
  local p code t0 t1 ms
  for p in "${PORTS[@]}"; do
    if port_listening "$p"; then emit "$(ok "端口 $p 监听中")"
    else emit "$(warn "端口 $p 未监听")"; fi
  done
  t0="$(date +%s%N)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$PROXY" \
            https://www.gstatic.com/generate_204 2>/dev/null || true)"
  t1="$(date +%s%N)"; ms=$(( (t1 - t0) / 1000000 ))
  if [ "$code" = "204" ]; then emit "$(ok "代理链路正常：HTTP 204（${ms}ms，经 $PROXY）")"
  else emit "$(warn "代理链路异常：HTTP '${code:-无响应}'（${ms}ms）")"; fi
  if getent hosts www.alidns.com >/dev/null 2>&1; then emit "$(ok "系统 DNS 解析可用")"
  else emit "$(warn "系统 DNS 解析失败")"; fi
}

# ---------------------------------------------------------------- 参数解析 --
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --force) FORCE=1 ;;
    --restore-perms) RESTORE_PERMS=1 ;;
    --preflight|--check) WANT_PREFLIGHT=1 ;;
    --post-reboot|--post) WANT_POST=1 ;;
    --rollback) WANT_ROLLBACK=1 ;;
    --step1) RUN_STEPS+=(step1) ;;
    --step2) RUN_STEPS+=(step2) ;;
    --step3) RUN_STEPS+=(step3) ;;
    --step4) RUN_STEPS+=(step4) ;;
    --out) shift; OUT_FILE="${1:-}" ;;
    -h|--help) awk 'NR>1 && /^# ===== END HELP/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
  shift
done

if [ -n "$OUT_FILE" ]; then : >"$OUT_FILE"; fi
if [ "$WANT_PREFLIGHT$WANT_POST$WANT_ROLLBACK" = "000" ] && [ "${#RUN_STEPS[@]}" -eq 0 ]; then
  RUN_STEPS=(step1 step2 step3 step4)
fi
if [ "$DRY" = 1 ]; then note "dry-run 模式：不会修改任何文件/服务"; fi

# ------------------------------------------------------------------ 体检 --
cmd_preflight() {
  section "现状体检（只读）"
  emit "boot_id        : $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo '?')"
  emit "开机时刻       : $(uptime -s 2>/dev/null || echo '?')   （已运行 $(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')）"
  emit "sing-box       : $(unit_line $SERVICE)"
  emit "                NRestarts=$(unit_field $SERVICE NRestarts)  Restart=$(unit_field $SERVICE Restart)"
  emit "UMask/StateDir : $(unit_field $SERVICE UMask) / $(unit_field $SERVICE StateDirectoryMode)"
  emit "libvirtd       : $(unit_line libvirtd.service)"
  if ip -br link show virbr0 >/dev/null 2>&1; then
    emit "virbr0         : $(ip -br link show virbr0 2>/dev/null | tr -s ' ')"
  else
    emit "virbr0         : 不存在"
  fi
  if ss -Hltn 2>/dev/null | grep -q '192\.168\.122\.1:53'; then
    emit "$(ok "libvirt 默认网络已激活（192.168.122.1:53 在听）→ step2 的前提成立")"
  fi
  emit "drop-in 目录   : $(dropin_list)"
  emit "cache.db       : mode=$(file_mode "$CACHE_DB")  目录 $STATE_DIR: mode=$(file_mode "$STATE_DIR")"
  emit ""
  emit "候选文件："
  for f in "$CAND_ORDER" "$CAND_UMASK"; do
    emit "  $(basename "$f"): $([ -f "$f" ] && echo "存在（$REPO_DIR/systemd/）" || echo '缺失')"
  done
  emit "$( [ -f "$TARGET_ORDER" ] && printf '%s' "$(ok "40-libvirtd-order.conf 已安装")" || printf '%s' "$(note "40-libvirtd-order.conf 未安装")" )"
  emit "$( [ -f "$TARGET_UMASK" ] && printf '%s' "$(ok "30-umask-hardening.conf 已安装")" || printf '%s' "$(note "30-umask-hardening.conf 未安装")" )"
  emit ""
  health_check
  section "下一步"
  if [ "$(file_mode "$CACHE_DB")" = "600" ]; then
    emit "$(ok "step1 已满足（cache.db=600），脚本会自动跳过")"
  else
    emit "$(warn "step1 待做：cache.db=$(file_mode "$CACHE_DB")")"
  fi
  emit "接着跑： sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --dry-run   # 先看计划"
  emit "然后：   sudo bash scripts/harden-boot-stepwise-2026-10-12.sh           # 交互式落地"
}

# ----------------------------------------------------------------- step1 --
cmd_step1() {
  section "step1 · cache.db 权限 → 0600（docs/11 P2-2）"
  [ -e "$CACHE_DB" ] || { warn "找不到 $CACHE_DB（可能尚未生成），跳过"; return 0; }
  local cur dm
  cur="$(file_mode "$CACHE_DB")"; dm="$(file_mode "$STATE_DIR")"
  emit "当前： $CACHE_DB mode=$cur ；目录 $STATE_DIR mode=$dm"
  if [ "$cur" = "600" ] || [ "$cur" = "400" ]; then
    ok "已经是 $cur —— 无需改动（幂等）"
    note "目录 $dm 只暴露文件名；装好 step3 后由 systemd 在下次启动改为 0750"
    return 0
  fi
  warn "该文件是 DNS 缓存（cache_file.store_dns=true），mode=$cur 时同机任意用户可读"
  info "将执行： chmod 600 $CACHE_DB"
  confirm_or_skip "把 $CACHE_DB 改成 0600 ？" || return 0
  mutate chmod 600 "$CACHE_DB"
  if [ "$(file_mode "$CACHE_DB")" = "600" ]; then ok "验证通过：mode=600"
  else warn "验证失败：mode=$(file_mode "$CACHE_DB")"; fi
  note "回滚（会重新暴露 DNS 缓存）： sudo chmod 644 $CACHE_DB"
}

# ---- step2/step3 共用的 drop-in 安装流程 ----
install_dropin() {
  local cand="$1" target="$2" label="$3"
  [ -f "$cand" ] || die "找不到候选文件：$cand"
  if [ -f "$target" ] && cmp -s "$cand" "$target"; then
    ok "$label 内容已一致 —— 无需改动（幂等）"; return 0
  fi
  local bak=""
  if [ -f "$target" ]; then
    bak="$target.bak.$(date +%Y%m%d-%H%M%S)"
    warn "目标已存在且内容不同，将先备份 → $bak"
  fi
  info "将执行： install -D -m644 $cand $target"
  if [ "$DRY" = 0 ]; then info "         systemctl daemon-reload"; fi
  confirm_or_skip "安装 $label ？" || return 0
  if [ -n "$bak" ]; then mutate cp -a "$target" "$bak"; fi
  mutate install -D -m644 "$cand" "$target"
  INSTALLED_THIS_RUN="$target"
  mutate systemctl daemon-reload
  INSTALLED_THIS_RUN=""
  if [ "$DRY" = 1 ]; then note "[dry-run] 未真正安装，不做验证"
  else ok "已安装 $target（daemon-reload 完成，服务未重启）"; fi
}

verify_order() {
  if [ "$DRY" = 1 ]; then note "[dry-run] 跳过验证（After=/Wants= 尚未载入）"; return 0; fi
  local a w
  a="$(unit_field $SERVICE After | tr ' ' '\n' | grep -cx 'libvirtd.service' || true)"
  w="$(unit_field $SERVICE Wants | tr ' ' '\n' | grep -cx 'libvirtd.service' || true)"
  if [ "${a:-0}" -ge 1 ]; then ok "验证：After= 已含 libvirtd.service"
  else warn "验证失败：After= 里没有 libvirtd.service"; fi
  if [ "${w:-0}" -ge 1 ]; then ok "验证：Wants= 已含 libvirtd.service"
  else warn "验证失败：Wants= 里没有 libvirtd.service"; fi
  note "该依赖只在下次启动产生时序效果；本次不重启，代理不受影响"
}

verify_umask() {
  if [ "$DRY" = 1 ]; then note "[dry-run] 跳过验证（UMask 尚未载入）"; return 0; fi
  local u s dm cm
  u="$(unit_field $SERVICE UMask)"; s="$(unit_field $SERVICE StateDirectoryMode)"
  dm="$(file_mode "$STATE_DIR")"; cm="$(file_mode "$CACHE_DB")"
  [ "$u" = "0077" ] && ok "验证：UMask=$u" || warn "UMask=$u（期望 0077）"
  [ "$s" = "0750" ] && ok "验证：StateDirectoryMode=$s" || warn "StateDirectoryMode=$s（期望 0750）"
  note "目录当前=$dm、cache.db 当前=$cm；systemd 会在下次启动把 StateDirectory 调成 0750"
  note "今后新建文件为 0600（UMask 生效于启动之后创建的文件）"
}

cmd_step2() {
  section "step2 · 安装 40-libvirtd-order.conf（docs/12 R1：virbr0 就绪时序）"
  if systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | grep -q '^libvirtd\.service'; then
    ok "libvirtd.service 存在：$(unit_line libvirtd.service)"
  else
    warn "系统里没有 libvirtd.service —— 这个 drop-in 会是空操作"
    [ "$FORCE" = 1 ] || { note "跳过（确实要装请加 --force）"; return 0; }
  fi
  if ip -br link show virbr0 >/dev/null 2>&1; then
    ok "virbr0 存在：$(ip -br link show virbr0 2>/dev/null | tr -s ' ')"
    note "virbr0 由 libvirtd 提供（192.168.122.1 = libvirt 默认网络）——前提成立"
  else
    warn "当前没有 virbr0（VM 未运行 / libvirt 网络未定义）"
  fi
  install_dropin "$CAND_ORDER" "$TARGET_ORDER" "40-libvirtd-order.conf" || return 0
  verify_order
}

cmd_step3() {
  section "step3 · 安装 30-umask-hardening.conf（docs/11 P2-2：防止权限回退）"
  note "目的：UMask=0077 + StateDirectoryMode=0750，让今后新建的文件不再变回 0644"
  install_dropin "$CAND_UMASK" "$TARGET_UMASK" "30-umask-hardening.conf" || return 0
  verify_umask
}

# ----------------------------------------------------------------- step4 --
cmd_step4() {
  section "step4 · 写重启前标记（供重启后对比）"
  local tmp
  tmp="$(mktemp)"
  {
    echo "# harden-boot-stepwise-2026-10-12.sh 生成的重启前快照"
    echo "MARK_VERSION=1"
    echo "MARK_TIME=$(date -Is)"
    echo "BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo '?')"
    echo "BOOT_TIME=$(uptime -s 2>/dev/null || echo '?')"
    echo "SB_ACTIVE=$(unit_field $SERVICE ActiveEnterTimestamp)"
    echo "SB_NRESTARTS=$(unit_field $SERVICE NRestarts)"
    echo "UMASK=$(unit_field $SERVICE UMask)"
    echo "STATEDIRMODE=$(unit_field $SERVICE StateDirectoryMode)"
    echo "AFTER_LIBVIRTD=$(unit_field $SERVICE After | tr ' ' '\n' | grep -cx 'libvirtd.service' || true)"
    echo "WANTS_LIBVIRTD=$(unit_field $SERVICE Wants | tr ' ' '\n' | grep -cx 'libvirtd.service' || true)"
    echo "CACHE_DB_MODE=$(file_mode "$CACHE_DB")"
    echo "STATE_DIR_MODE=$(file_mode "$STATE_DIR")"
    echo "DROPIN=$(dropin_list)"
    echo "LIBVIRTD_ACTIVE=$(unit_field libvirtd.service ActiveEnterTimestamp)"
  } >"$tmp"
  info "将执行： install -m644 <快照> $MARKER"
  if [ "$DRY" = 1 ]; then
    note "[dry-run] 快照内容如下 ——"
    sed 's/^/    /' "$tmp" | while IFS= read -r l; do emit "$l"; done
  else
    confirm_or_skip "写入重启前标记 $MARKER ？" || { rm -f "$tmp"; return 0; }
    mutate install -D -m644 "$tmp" "$MARKER"
    ok "标记已写入 $MARKER"
  fi
  rm -f "$tmp"

  section "现在请你重启（这一步只能你来做）"
  emit "重启命令： sudo systemctl reboot"
  emit ""
  emit "重启后回来跑（不需要 root，但若 journalctl 报权限不足就用 sudo）："
  emit "  bash scripts/harden-boot-stepwise-2026-10-12.sh --post-reboot --out /tmp/reboot-report.txt"
  emit ""
  emit "重点看两件事："
  emit "  1) boot+0..${WINDOW}s 窗口内 sing-box 与整机的 warning/error 条数 —— 直接对应"
  emit "     「开机后几分钟网络不稳定」这个症状；"
  emit "  2) libvirtd 与 sing-box 的就绪时刻 —— step2 装完后两者间距应从 4 秒变成稳定为正。"
  emit ""
  emit "$(note "如果重启后网络仍不稳，把 --post-reboot 的报告贴回来，我按窗口内的日志继续定位。")"
}

# ------------------------------------------------------------ 重启后报告 --
cmd_post() {
  section "重启后证据报告"
  local now_boot boot_epoch since until n sn
  now_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo '?')"
  emit "当前 boot_id : $now_boot"
  emit "当前开机时刻 : $(uptime -s 2>/dev/null || echo '?')"
  if [ -f "$MARKER" ]; then
    local old; old="$(marker_get BOOT_ID)"
    emit "重启前 boot_id: ${old:-（缺失）}"
    if [ -n "$old" ] && [ "$old" = "$now_boot" ]; then
      warn "boot_id 未变化 —— 还没有重启（或没重启成功），下面的时序对比无效"
    elif [ -n "$old" ]; then
      ok "已发生重启（boot_id 已变化）—— 时序对比有效"
    fi
    emit "重启前 UMask/StateDir = $(marker_get UMASK) / $(marker_get STATEDIRMODE)  →  现在 = $(unit_field $SERVICE UMask) / $(unit_field $SERVICE StateDirectoryMode)"
    emit "重启前 After 含 libvirtd = $(marker_get AFTER_LIBVIRTD)  →  现在 = $(unit_field $SERVICE After | tr ' ' '\n' | grep -cx 'libvirtd.service' || true)"
    emit "重启前 cache.db/目录 mode = $(marker_get CACHE_DB_MODE) / $(marker_get STATE_DIR_MODE)  →  现在 = $(file_mode "$CACHE_DB") / $(file_mode "$STATE_DIR")"
  else
    note "没有找到 $MARKER（未跑过 step4）—— 仍做现状检查，但没有前后对比"
  fi

  section "各单元就绪时刻（相对本次开机）"
  boot_epoch="$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)"
  local u ts ep d
  for u in network-online.target NetworkManager.service systemd-resolved.service libvirtd.service "$SERVICE.service" sing-box-panel.service; do
    ts="$(unit_field "$u" ActiveEnterTimestamp)"
    if [ -z "$ts" ]; then emit "  $(printf '%-26s' "$u") （无 ActiveEnterTimestamp / 不存在）"; continue; fi
    ep="$(date -d "$ts" +%s 2>/dev/null || echo '')"
    if [ -n "$ep" ] && [ "$boot_epoch" -gt 0 ]; then d="boot+$(hms $(( ep - boot_epoch )))"; else d="?"; fi
    emit "  $(printf '%-26s' "$u") $ts   ($d)"
  done
  if [ "$boot_epoch" -gt 0 ]; then
    local la sa
    la="$(date -d "$(unit_field libvirtd.service ActiveEnterTimestamp)" +%s 2>/dev/null || echo '')"
    sa="$(date -d "$(unit_field $SERVICE ActiveEnterTimestamp)" +%s 2>/dev/null || echo '')"
    if [ -n "$la" ] && [ -n "$sa" ]; then
      if [ $(( sa - boot_epoch )) -gt 600 ]; then
        note "sing-box 的 ActiveEnter 是 boot+$(hms $(( sa - boot_epoch )))，不是这次开机启动的"
        note "（期间被手工或 systemd 重启过）→ 与 libvirtd 的「间距」此刻没有时序含义。"
        note "要测 step2 的真实效果，请在真正重启后立刻跑本命令。"
      elif [ "$sa" -ge "$la" ]; then
        emit "$(ok "libvirtd → sing-box 间距 = $(hms $(( sa - la )))（step2 目标：sing-box 不早于 libvirtd）")"
      else
        emit "$(warn "sing-box 早于 libvirtd $(( la - sa ))s —— 时序未被约束（step2 未生效？）")"
      fi
    fi
  fi

  section "开机窗口 boot+0 .. boot+${WINDOW}s 的告警（对应「开机后几分钟不稳」）"
  since="@$boot_epoch"; until="@$(( boot_epoch + WINDOW ))"
  n="$(journalctl -u $SERVICE -b --since "$since" --until "$until" -p warning --no-pager 2>/dev/null \
        | grep -vc '^-- No entries --$' || true)"
  if [ "${n:-0}" -eq 0 ]; then ok "sing-box：该窗口内 0 条 warning/error"
  else
    warn "sing-box：该窗口内 $n 条"
    journalctl -u $SERVICE -b --since "$since" --until "$until" -p warning --no-pager 2>/dev/null \
      | sed 's/^/    /' | tail -20 | while IFS= read -r l; do emit "$l"; done
  fi
  sn="$(journalctl -b -p warning --since "$since" --until "$until" --no-pager 2>/dev/null \
         | grep -vc '^-- No entries --$' || true)"
  emit "整机同窗口 warning/error：${sn:-0} 条"
  local nf
  nf="$(journalctl -b -p warning --since "$since" --until "$until" --no-pager 2>/dev/null \
        | grep -Ei 'NetworkManager|systemd-resolved|network-online|dhcp|sing-box|libvirt|virbr|emoeem|resolv' || true)"
  if [ -n "$nf" ]; then
    emit "↑ 其中与「网络 / 开机链路」相关的（已滤掉桌面噪声）："
    printf '%s\n' "$nf" | tail -20 | sed 's/^/    /' | while IFS= read -r l; do emit "$l"; done
  else
    ok "整机告警里没有网络/开机链路相关条目（其余基本是桌面会话噪声）"
  fi
  if [ "${sn:-0}" -gt 0 ]; then
    emit "整机原始末 10 条（含桌面噪声，仅供确认没有漏看）："
    journalctl -b -p warning --since "$since" --until "$until" --no-pager 2>/dev/null \
      | tail -10 | sed 's/^/    /' | while IFS= read -r l; do emit "$l"; done
  fi
  local v
  v="$(journalctl -b -k --no-pager 2>/dev/null | grep -i -m2 'virbr0' | sed 's/^/    /' || true)"
  [ -n "$v" ] && { emit "内核里的 virbr0 事件："; printf '%s\n' "$v" | while IFS= read -r l; do emit "$l"; done; }

  section "出站握手失败（最近 30 分钟）—— 常见的不稳来源，与开机时序无关"
  local e30 t30 top tg ip pt okc badc
  e30="$(journalctl -u $SERVICE --since '-30 min' --no-pager 2>/dev/null | grep -c 'i/o timeout' || true)"
  t30="$(journalctl -u $SERVICE --since '-30 min' --no-pager 2>/dev/null | grep -c 'ERROR' || true)"
  if [ "${e30:-0}" -eq 0 ]; then
    ok "最近 30 分钟没有 i/o timeout（ERROR 共 ${t30:-0} 条）"
  else
    warn "最近 30 分钟 i/o timeout ${e30} 条（ERROR 共 ${t30:-0} 条）—— 这是节点/上游侧信号，不是开机时序"
    top="$(journalctl -u $SERVICE --since '-30 min' --no-pager 2>/dev/null \
           | grep -oE 'dial tcp [0-9.]+:[0-9]+' | awk '{print $3}' | sort | uniq -c | sort -rn | head -6 || true)"
    emit "  按目标分组（次数 / IP:PORT）："
    printf '%s\n' "$top" | sed 's/^/    /' | while IFS= read -r l; do emit "$l"; done
    emit "  逐个测 TCP 连通性（能连上 ≠ 隧道可用）："
    okc=0; badc=0
    for tg in $(printf '%s\n' "$top" | awk '{print $2}' | head -4); do
      ip="${tg%:*}"; pt="${tg#*:}"
      if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$pt" 2>/dev/null; then
        emit "    ✅ $tg TCP 可连（若仍握手超时 → 服务端/中间盒/协议层问题，不是网络不通）"; okc=$((okc+1))
      else
        emit "    ❌ $tg TCP 连不上（节点真的挂了或被墙）"; badc=$((badc+1))
      fi
    done
    [ "$okc" -gt 0 ] && note "有 $okc 个目标 TCP 通但握手超时 → 优先查节点负载/被墙/TFO，而不是本机开机顺序"
  fi

  section "开机链路 / 耗时"
  systemd-analyze 2>/dev/null | sed 's/^/  /' | while IFS= read -r l; do emit "$l"; done || true
  systemd-analyze critical-chain "$SERVICE.service" 2>/dev/null | sed 's/^/  /' | while IFS= read -r l; do emit "$l"; done || true

  section "现状健康检查"
  emit "sing-box：$(unit_line $SERVICE)   NRestarts=$(unit_field $SERVICE NRestarts)"
  health_check

  section "结论怎么读"
  emit "· 若「开机窗口」sing-box 0 条、整机也 0 条 → 该 boot 没有可观测的不稳证据，"
  emit "  症状若仍出现，需要在下一次不稳定发生时立刻抓现场（journalctl -b -p warning 全量）。"
  emit "· 若出现 DNS/路由类告警 → 贴回报告，按告警原文继续定位（DNS 未就绪 / 路由表刷新 /"
  emit "  auto_detect_interface 抢跑是 docs/12 列出的三个候选机制）。"
  emit "· NRestarts 若 >0 → sing-box 崩过，journalctl -u sing-box -b 给完整上下文。"
  emit "· ⚠️ 「开机窗口 0 条」**不等于**没问题：本机实测的持续不稳发生在开机几分钟之后，"
  emit "  表现为「出站握手 i/o timeout」而非 boot 窗口告警 —— 见上面「最近 30 分钟」那一节。"
  emit "  排查顺序建议：先看 30 分钟出站失败，再看 boot 窗口。"
  if [ -n "$OUT_FILE" ]; then note "报告已保存：$OUT_FILE"; fi
  return 0
}

# ---------------------------------------------------------------- 回滚 --
cmd_rollback() {
  section "回滚：卸载两个 drop-in（不动 cache.db 权限）"
  local f found=0
  for f in "$TARGET_ORDER" "$TARGET_UMASK"; do
    if [ -f "$f" ]; then
      found=1
      info "将执行： rm -f $f"
      confirm_or_skip "删除 $(basename "$f") ？" || continue
      mutate rm -f "$f"
      ok "已删除 $f"
    else
      note "$f 不存在，跳过"
    fi
  done
  if [ "$found" = 1 ]; then
    mutate systemctl daemon-reload
    ok "daemon-reload 完成（当前运行的 sing-box 不受影响，这两个文件只在启动时起作用）"
  fi
  if [ "$RESTORE_PERMS" = 1 ]; then
    warn "恢复成 0644/0755 会重新打开 DNS 缓存泄漏（同机任意用户可读）"
    mutate chmod 644 "$CACHE_DB"
    mutate chmod 755 "$STATE_DIR"
  else
    note "权限未动。确实要恢复旧权限：加 --restore-perms（不推荐）"
  fi
}

# ---------------------------------------------------------------- 调度 --
if [ "$WANT_PREFLIGHT" = 1 ]; then cmd_preflight; fi
if [ "$WANT_POST" = 1 ]; then cmd_post; fi
if [ "$WANT_ROLLBACK" = 1 ]; then cmd_rollback; fi
for s in "${RUN_STEPS[@]}"; do "cmd_$s"; done

if [ "${#RUN_STEPS[@]}" -gt 0 ] && [ "$DRY" = 0 ]; then
  section "本轮结束"
  emit "· 当前 drop-in：$(dropin_list)"
  emit "· 服务未被重启：$SERVICE $(unit_line $SERVICE)"
  emit "· 回滚（卸载本次安装的 drop-in）： sudo bash scripts/harden-boot-stepwise-2026-10-12.sh --rollback"
  emit "· 下一步：重启并用 --post-reboot 采集开机证据（step4 已打印命令）"
fi
exit 0
