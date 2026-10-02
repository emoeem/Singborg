#!/usr/bin/env bash
# 让 rootful podman 容器在 eBPF 模式下也被代理
#
#   sudo ./enable-container-proxy.sh              # 自动探测/创建 podman 网桥并启用 eBPF shared 数据面
#   sudo ./enable-container-proxy.sh --disable    # 关闭 shared（回到"容器只走直连"）
#   sudo ./enable-container-proxy.sh --iface br0  # 手动指定下游接口
#
# 背景（实测结论）：
#   rootless podman 默认用 pasta，它是把容器数据包 splice 进宿主网络栈、**不创建宿主 socket**，
#   所以 eBPF 的 local cgroup 钩子看不到容器流量（容器 DNS 通、国内直连通、境外直连被墙）。
#   TUN 模式靠 auto_route 管住了转发流量，eBPF 模式要管住转发流量只能用 shared 数据面。
#
#   本脚本在 podman 网桥上开 eBPF shared（packet_rewrite），并用 rootful 容器**实测**验证；
#   任一环节失败自动回滚。rootless 容器（pasta）不走网桥，不受此影响（仍需 --network=host）。
set -Eeuo pipefail

CONF="${CONF:-/etc/sing-box/config.json}"
BIN="${BIN:-/usr/bin/sing-box}"
SERVICE="${SERVICE:-sing-box}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
BACKUP_DIR="/etc/sing-box/backups"
MODE="enable"
FORCE=0
IFACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable) MODE="disable"; shift ;;
    --iface)   IFACE="${2:-}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    *) printf 'FATAL 未知参数：%s（可用：--disable --iface <接口> | --force）\n' "$1" >&2; exit 1 ;;
  esac
done

WORK="$(mktemp -d /tmp/container-proxy.XXXXXX)"
NEW_JSON="$WORK/new.json"
CHECK_OUT="$WORK/check.out"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0"
[[ -f $CONF ]] || die "找不到 $CONF"
command -v python3 >/dev/null || die "需要 python3"

say "① 前置检查"
systemctl is-active --quiet "$SERVICE" || die "$SERVICE 不是 active"
INBOUND_KIND="$(python3 -c "
import json
d=json.load(open('$CONF'))
t=[i.get('type') for i in d.get('inbounds',[])]
print('ebpf' if 'ebpf' in t else ('tun' if 'tun' in t else 'other'))")"
[[ $INBOUND_KIND == "ebpf" ]] || die "当前不是 eBPF 模式（是 $INBOUND_KIND）。TUN 模式下容器本来就靠 auto_route 管着，不需要本脚本"
say "   eBPF 模式确认"

if [[ $MODE == "enable" ]]; then
  say "①a 检查内核是否支持 shared 所需的 TC / packet_rewrite 路径"
  _pf="$("$BIN" tools ebpf status --mode all --json 2>/dev/null || true)"
  _res="$(printf '%s' "$_pf" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('result','unknown'))
except Exception: print('unknown')" 2>/dev/null || echo unknown)"
  printf '   --mode all 预检：result=%s\n' "$_res"
  if [[ $_res != passed ]]; then
    warn "shared 数据面（packet_rewrite）依赖 TC eBPF，而预检未确认支持（result=$_res）。"
    warn "本机内核实测会失败于：register TC eBPF TCP listener: operation not supported"
    cat <<'EOT' >&2

   结论：这台机器上 shared 方案不可用（改配置只会让 sing-box 起不来）。
   容器走代理的可行办法（已实测）：
       podman run --rm --network=host <镜像> ...
   此时容器直接用宿主 socket，能被 eBPF 的 local cgroup 数据面接管。
EOT
    (( FORCE )) || exit 3
    warn "已按 --force 继续（大概率失败，失败会自动回滚）"
  fi
fi

if [[ $MODE == "disable" ]]; then
  say "② 关闭 shared（容器将只走直连）"
  python3 - "$CONF" "$NEW_JSON" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
for i in cfg["inbounds"]:
    if i.get("type") == "ebpf":
        i["shared"] = {"enabled": False}
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("   shared.enabled → false")
PY
else
  say "② 确定下游接口"
  if [[ -z $IFACE ]]; then
    IFACE="$(ip -brief link show type bridge 2>/dev/null | awk '{print $1}' |
             grep -E '^(podman|cni-podman|podman[0-9]+|cni[0-9]+)$' | head -1 || true)"
  fi
  if [[ -z $IFACE ]]; then
    warn "没找到 podman 网桥，尝试用 rootful podman 创建一个（这会拉起一个临时容器）"
    if command -v podman >/dev/null; then
      podman network create sb-container-proxy >/dev/null 2>&1 || true
      timeout 120 podman run --rm --network sb-container-proxy docker.io/library/alpine:latest \
        /bin/true >/dev/null 2>&1 || warn "创建临时容器失败"
      IFACE="$(ip -brief link show type bridge 2>/dev/null | awk '{print $1}' |
               grep -E '^(podman|cni-podman|podman[0-9]+|cni[0-9]+)$' | head -1 || true)"
    fi
  fi
  if [[ -z $IFACE ]]; then
    warn "找不到 podman 网桥，先做一次自诊断（结果如下，可直接贴给维护者）："
    {
      printf 'podman 版本: %s\n' "$(podman --version 2>&1)"
      printf 'network backend=%s rootless_cmd=%s\n' \
        "$(podman info --format '{{.Host.NetworkBackend}}' 2>&1)" \
        "$(podman info --format '{{.Host.RootlessNetworkCmd}}' 2>&1)"
      printf '现有网络:\n'; podman network ls 2>&1 | sed 's/^/  /'
      printf '尝试创建桥网络 sbtest: '; podman network create --driver bridge sbtest 2>&1 | tail -1
      printf '用该网络跑一次容器: '; timeout 150 podman run --rm --network sbtest docker.io/library/alpine:latest \
        ip -brief addr show 2>&1 | tail -2
      printf '当前网桥接口:\n'; ip -brief link show type bridge 2>&1 | sed 's/^/  /'
    } | sed 's/^/   /'
    cat <<'EOT' >&2

   ↑ 如果上面显示 "创建桥网络" 或 "跑容器" 失败、并且始终没有网桥接口，
     说明你这版 podman(6.x) 连 rootful 也默认走 pasta —— 它把容器数据包直接 splice 进宿主栈、
     不创建宿主 socket，eBPF 的 local cgroup 数据面看不到，shared 也就没有可绑的下游接口。

   可行替代（已实测）：容器加 --network=host
     podman run --rm --network=host <镜像> ...
   此时容器直接用宿主 socket，能被 eBPF cgroup 钩子接管（实测出口 = 代理 IP）。
EOT
    exit 2
  fi
  ip link show "$IFACE" >/dev/null 2>&1 || die "接口 $IFACE 不存在"
  FRAMING_OK="$(ip -details link show "$IFACE" 2>/dev/null | grep -c 'link/ether' || true)"
  (( FRAMING_OK > 0 )) || die "接口 $IFACE 不是以太网帧（shared packet_rewrite 需要）"
  say "   接口：$IFACE（以太网帧 ✅）"

  say "③ 生成新配置（给 ebpf 入站开启 shared）"
  python3 - "$CONF" "$NEW_JSON" "$IFACE" <<'PY'
import json, sys
conf_path, out_path, iface = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(conf_path, encoding="utf-8"))
for i in cfg["inbounds"]:
    if i.get("type") == "ebpf":
        i["shared"] = {
            "enabled": True,
            "data_plane": "packet_rewrite",
            "interface": [iface],
            "dns_mode": "hijack",
            "bypass_private_address": True,
            "ipv6": True,
        }
        print(f"   shared: enabled, packet_rewrite, interface={iface}")
json.dump(cfg, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
fi

say "④ 校验新配置"
if ! "$BIN" check -c "$NEW_JSON" > "$CHECK_OUT" 2>&1; then
  tail -6 "$CHECK_OUT" | sed 's/^/    /'
  die "新配置 check 失败，线上未做任何改动"
fi
say "   check 通过 ✅"

say "⑤ 备份 → 原子替换 → 重启"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUP_DIR/config.$STAMP.pre-container-proxy.json"
install -d -m 755 "$BACKUP_DIR"
cp -a "$CONF" "$BK" && say "   备份：$BK"
cp -a "$NEW_JSON" "$CONF.new" && chmod 644 "$CONF.new" && mv -f "$CONF.new" "$CONF"
systemctl restart "$SERVICE"
sleep 3

say "⑥ 健康检查"
fail=""
for _ in $(seq 40); do systemctl is-active --quiet "$SERVICE" && break; sleep 0.5; done
systemctl is-active --quiet "$SERVICE" || { fail="服务未 active"; journalctl -u "$SERVICE" -n 12 --no-pager | sed 's/^/    /'; }

if [[ -z $fail ]]; then
  secret="$(python3 -c "
import json
try: print((json.load(open('$CONF')).get('experimental',{}).get('clash_api',{}) or {}).get('secret',''))
except Exception: print('')")"
  st="$("$BIN" api ebpf --url "$API_URL" --secret "$secret" 2>&1 || true)"
  printf '%s' "$st" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('   ⚠️ api ebpf 无输出'); raise SystemExit
for i in d.get('inbounds',[]):
    for a in i.get('attachments',[]) or []:
        print(f\"   附件: role={a.get('role')} mechanism={a.get('mechanism')} iface={a.get('interfaceName') or '-'}\")
" 2>/dev/null || true
fi

# 宿主不设代理仍必须走代理
if [[ -z $fail ]]; then
  h="$(curl -s -m 12 https://api.ipify.org || true)"
  p="$(curl -s -m 12 -x http://127.0.0.1:7892 https://api.ipify.org || true)"
  printf '   宿主不设代理=%s / 本地代理口=%s\n' "${h:-无}" "${p:-无}"
  [[ -n $h && "$h" == "$p" ]] || fail="宿主流量不再被接管"
fi

# 关键：rootful 容器实测（用 root 的 podman，走网桥）
if [[ -z $fail && $MODE == "enable" ]]; then
  printf '   rootful 容器实测（网桥 %s）…\n' "$IFACE"
  net="$(podman network ls --format '{{.Name}}' 2>/dev/null | grep -Fx sb-container-proxy || true)"
  cnet=()
  [[ -n $net ]] && cnet=(--network "$net")
  cip="$(timeout 180 podman run --rm "${cnet[@]}" docker.io/library/alpine:latest \
        sh -c 'apk add --no-cache curl >/dev/null 2>&1; curl -4 -s -m 25 https://api.ipify.org' 2>/dev/null | tail -1 || true)"
  printf '   容器出口=%s\n' "${cip:-失败}"
  if [[ -z $cip ]]; then fail="容器仍拿不到出口（shared 未生效或容器链路不同）"
  else
    prox="$(curl -s -m 12 -x http://127.0.0.1:7892 https://api.ipify.org || true)"
    [[ "$cip" == "$prox" ]] || fail="容器出口($cip) ≠ 代理出口($prox)"
  fi
fi

if [[ -n $fail ]]; then
  warn "健康检查失败：$fail —— 正在回滚"
  cp -a "$BK" "$CONF"
  systemctl restart "$SERVICE"
  sleep 3
  systemctl is-active --quiet "$SERVICE" && warn "已回滚并重启" || warn "回滚后仍异常，请手动检查！"
  exit 1
fi

say "✅ 完成"
echo "   备份：$BK（回滚：sudo cp -a $BK $CONF && sudo systemctl restart $SERVICE）"
if [[ $MODE == "enable" ]]; then
  echo "   注意：这只覆盖**走网桥**的 rootful 容器；rootless（pasta）容器不受影响，仍需 --network=host"
fi
