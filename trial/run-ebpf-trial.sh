#!/usr/bin/env bash
# eBPF 入站 A/B 试跑：基线打分 → 停 TUN 起 eBPF → 同一套判据再打分 → 无论成败都恢复 TUN
#
#   用法：sudo ./run-ebpf-trial.sh
#         sudo SHARED_IFACE=virbr0 ./run-ebpf-trial.sh     # 顺带接管 libvirt 虚拟机
#
# 安全性：不写任何开机项；不覆盖 /etc/sing-box/config.json；
#         **试跑用独立 -D 状态目录与独立 cache.db**（绝不碰服务自己的 /var/lib/sing-box）；
#         kill/异常/幂等退出时都会把原 TUN 服务拉回来并轮询到 active。
#
# 教训（v2 修复）：
#   1) 旧版试跑直接用 -D /var/lib/sing-box，会与服务共用 cache.db；
#      一旦 cache.db 属主不是服务用户（例如被非 root 的 `sing-box check` 重建过），
#      服务重启就会 FATAL: initialize cache-file: permission denied。
#   2) 旧版 systemctl start 后只等 2s，撞上 RestartSec=10s 的退避窗口会误报失败。
set -Eeuo pipefail

BIN="${BIN:-/home/emo/.cache/sing-box-bin/sing-box-v1.14.2-reF1nd-with_ebpf}"
LIVE_CONF="${LIVE_CONF:-/etc/sing-box/config.json}"
# 私有工作目录：/tmp 是 sticky 且内核开了 fs.protected_regular=1，
# root 写不了「别的用户已创建的固定 /tmp 文件」——统一放进独占的 mktemp 目录避免这类偶发 EACCES。
WORK="$(mktemp -d /tmp/sing-box-ebpf-trial.XXXXXX)"
TRIAL_CONF="$WORK/trial-config.json"
TRIAL_STATE="$WORK/state"                      # ← 独立状态目录，cache.db 也在这里
LOG="$WORK/trial.log"
RESULT="$WORK/result.txt"
BEFORE="$WORK/before.txt"
AFTER="$WORK/after.txt"
SERVICE=sing-box
SHARED_IFACE="${SHARED_IFACE:-}"      # 留空 = 只接管本机流量
SB_PID=""
RESTORED=0

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0"
[[ -x $BIN ]]      || die "找不到可执行文件：$BIN"
[[ -f $LIVE_CONF ]] || die "找不到线上配置：$LIVE_CONF"
command -v python3 >/dev/null || die "需要 python3"

# ---------------------------------------------------------------- 恢复（幂等）
restore() {
  (( RESTORED )) && return 0
  RESTORED=1
  say "恢复：停掉试跑进程 → 拉回系统 $SERVICE（TUN）"
  if [[ -n $SB_PID ]] && kill -0 "$SB_PID" 2>/dev/null; then
    kill "$SB_PID" 2>/dev/null || true
    for _ in $(seq 40); do kill -0 "$SB_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$SB_PID" 2>/dev/null || true
  fi
  # 等试跑占的端口释放，避免服务撞 "address already in use"
  for _ in $(seq 40); do
    ss -ltnH 2>/dev/null | grep -q ':7892' || break
    sleep 0.25
  done
  systemctl restart "$SERVICE" 2>/dev/null || systemctl start "$SERVICE" 2>/dev/null || true
  local ok=0
  for _ in $(seq 60); do                       # 最多等 30s（覆盖 RestartSec=10s 退避）
    if systemctl is-active --quiet "$SERVICE"; then ok=1; break; fi
    sleep 0.5
  done
  if (( ok )); then
    # systemctl 报 active 时 TUN 设备可能还没建好（实测有 1 秒级竞态），轮询最多 10s
    local tun=0
    for _ in $(seq 20); do
      ip link show tun0 >/dev/null 2>&1 && { tun=1; break; }
      sleep 0.5
    done
    if (( tun )); then
      say "系统 $SERVICE 已恢复（TUN 模式，tun0 已回来）"
    else
      warn "服务 active 但 10s 内没等到 tun0，请查：journalctl -u $SERVICE -n 30"
    fi
  else
    warn "系统 $SERVICE 未 active —— 最近日志："
    journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
    warn "若看到 'initialize cache-file: ... permission denied'，执行："
    warn "    sudo chown sing-box:sing-box /var/lib/sing-box/cache.db && sudo systemctl restart $SERVICE"
  fi
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------- 前置体检
say "前置体检"
if ! systemctl is-active --quiet "$SERVICE"; then
  warn "系统 $SERVICE 当前不是 active —— 先修好它再试跑（试跑会先停它，基线也不可信）"
  journalctl -u "$SERVICE" -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || true
  die "已中止，未改动任何东西"
fi

# cache.db 属主必须是服务用户（旧版脚本就是踩了这个坑）
CACHE_PATH="$(python3 -c "import json;print((json.load(open('$LIVE_CONF')).get('experimental',{}).get('cache_file') or {}).get('path',''))" 2>/dev/null || true)"
SVC_USER="$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)"
if [[ -n $CACHE_PATH && -e $CACHE_PATH && -n $SVC_USER && $SVC_USER != root ]]; then
  owner="$(stat -c %U "$CACHE_PATH")"
  if [[ $owner != "$SVC_USER" ]]; then
    warn "$CACHE_PATH 属主是 $owner，而服务用户是 $SVC_USER → 服务重启会 FATAL"
    chown "$SVC_USER" "$CACHE_PATH" && say "已顺手纠正属主为 $SVC_USER（缓存文件，安全）"
  fi
fi

mkdir -p "$TRIAL_STATE"

# ---------------------------------------------------------------- 生成试跑配置
say "由线上配置生成 eBPF 试跑配置（tun-in → ebpf-in，cache 指向独立状态目录）"
SHARED_IFACE="$SHARED_IFACE" TRIAL_CONF="$TRIAL_CONF" LIVE_CONF="$LIVE_CONF" \
TRIAL_STATE="$TRIAL_STATE" python3 - <<'PY'
import json, os
live, out = os.environ["LIVE_CONF"], os.environ["TRIAL_CONF"]
state = os.environ["TRIAL_STATE"]
iface = os.environ.get("SHARED_IFACE", "").strip()
d = json.load(open(live, encoding="utf-8"))

local = {
    "enabled": True,
    "data_plane": "cgroup",          # 用内核 socket hook，不跟随网卡
    "dns_mode": "hijack",            # 端口 53 在内核侧接管
    "bypass_private_address": True,  # 私网/特殊地址直连（LAN、路由器、podman 网关）
    "ipv6": True,
}
shared = {"enabled": True, "data_plane": "packet_rewrite", "interface": [iface],
          "dns_mode": "hijack", "bypass_private_address": True, "ipv6": True} if iface \
         else {"enabled": False}

ebpf = {"type": "ebpf", "tag": "ebpf-in", "network": ["tcp", "udp"],
        "local": local, "shared": shared}

kept, dropped = [], []
for i in d.get("inbounds", []):
    (dropped if i.get("type") == "tun" else kept).append(i)
d["inbounds"] = kept + [ebpf]
d.setdefault("log", {})["level"] = "info"        # 试跑要看启动与 eBPF 日志

# 关键：试跑的 cache 必须落在自己的目录，绝不能和服务共用 /var/lib/sing-box/cache.db
cf = d.setdefault("experimental", {}).setdefault("cache_file", {})
old = cf.get("path", "")
cf["path"] = os.path.join(state, "cache.db")
json.dump(d, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"  去掉 {len(dropped)} 个 tun 入站，保留 {[i.get('tag') for i in kept]}，"
      f"新增 ebpf-in（shared={iface or '关'}）")
print(f"  cache_file: {old} → {cf['path']}")
PY

say "先用 root 校验试跑配置（eBPF 入站会真的建 map，非 root 一定失败）"
"$BIN" check -c "$TRIAL_CONF" || die "试跑配置未通过 check，已中止（系统未改动）"
say "check 通过 ✅"

# ---------------------------------------------------------------- 打分函数
probe() {
  local f=$1
  resolvectl flush-caches >/dev/null 2>&1 || true
  {
    echo "direct_isp_ip   $(curl -4 -s -m 12 https://myip.ipip.net || echo TIMEOUT)"
    echo "proxy_exit_ip   $(curl -4 -s -m 12 https://api.ipify.org || echo TIMEOUT)"
    echo "ipv6_http_code  $(curl -6 -s -m 12 -o /dev/null -w '%{http_code}' https://ipv6.google.com || echo FAIL)"
    echo "ipv6_blackhole  $(ip -6 rule show 2>/dev/null | grep -c unreachable || true)"
    # 直接问外部解析器：绕开 systemd-resolved 自己的缓存，才是 sing-box DNS 规则的真实答案
    echo "ads_dns_answer  [$(dig +time=3 +tries=1 @1.1.1.1 +short doubleclick.net 2>/dev/null | tr '\n' ' ')]"
    echo "resolve_github  $(resolvectl query github.com >/dev/null 2>&1 && echo ok || echo FAIL)"
    echo "tun0_state      $(ip link show tun0 >/dev/null 2>&1 && echo present || echo absent)"
  } >"$f" 2>&1
}

show() { sed 's/^/    /' "$1"; }

say "① 基线打分（当前 TUN 模式，上面这套已经过完整审计）"
probe "$BEFORE"; show "$BEFORE"

# ---------------------------------------------------------------- 切换
say "② 停 $SERVICE，前台起 eBPF 核心（日志 $LOG，状态目录 $TRIAL_STATE）"
systemctl stop "$SERVICE"
sleep 1
: >"$LOG"
"$BIN" -D "$TRIAL_STATE" -c "$TRIAL_CONF" run >>"$LOG" 2>&1 &
SB_PID=$!

ready=0
for _ in $(seq 60); do
  kill -0 "$SB_PID" 2>/dev/null || break
  grep -qiE 'FATAL|panic:' "$LOG" && break
  grep -qi 'sing-box started' "$LOG" && { ready=1; break; }
  sleep 0.5
done
if (( ! ready )); then
  warn "核心未在 30s 内报 started —— 日志尾部："
  tail -25 "$LOG" | sed 's/^/    /'
  die "试跑失败，进入恢复流程"
fi
say "核心已启动，关键日志："
grep -iE 'ebpf|started|inbound' "$LOG" | tail -12 | sed 's/^/    /'
sleep 4

say "③ eBPF 模式打分（同一套判据）"
probe "$AFTER"; show "$AFTER"

# ---------------------------------------------------------------- 结论
{
  echo "=== eBPF 试跑对比（$(date '+%F %T')，binary=$("$BIN" version | head -1)） ==="
  echo "--- TUN 基线 ---"; cat "$BEFORE"
  echo "--- eBPF 试跑 ---"; cat "$AFTER"
  echo "--- 差异 ---"; diff -u "$BEFORE" "$AFTER" || true
} >"$RESULT"

say "④ 结论"
if diff -q "$BEFORE" "$AFTER" >/dev/null; then
  say "两模式打分**完全一致** → 行为等价，可按需切换"
else
  warn "两模式存在差异，逐行看下面（direct/proxy 应分别等于电信 IP / 节点 IP；"
  warn "proxy_exit_ip 每次可能落在不同节点，属正常）"
  diff -u "$BEFORE" "$AFTER" | sed 's/^/    /' || true
fi
echo
say "完整记录：$RESULT"
say "核心日志：$LOG"
warn "试跑到此结束，正在恢复 TUN —— 确认无误后再谈长期切换（打包 + 改 systemd 单元）"
