#!/usr/bin/env bash
# 验证 eBPF shared（下游接管）是否真的在接管流量 —— **不需要虚拟机**。
#
#   sudo ./test-shared-interception.sh          # 跑完自动清理
#   sudo ./test-shared-interception.sh --keep   # 出问题时保留环境，方便自己进去看
#
# 做法：临时建一个 network namespace + 一对 veth，把其中一端接进**当前配置里的 shared 接口**
# （通常是 virbr0），在 netns 里当"下游客户端"发请求，然后看它从哪个 IP 出去：
#
#   出口 == 代理出口  → ✅ 被 eBPF shared 接管（同时能在 Clash API 里看到来源是 netns 的 IP）
#   出口 == 家宽 IP   → ❌ 没接管，直接走宿主出去了
#   完全失败         → 链路/桥接/网段问题（提示会说明）
#
# 它**不改 sing-box 配置**，只动临时的 netns/veth；退出时（含 Ctrl-C）自动删干净，
# virbr0 会回到原来的状态。
set -Eeuo pipefail

CONF="${CONF:-/etc/sing-box/config.json}"
BIN="${BIN:-sing-box}"
CLASH="${CLASH:-http://127.0.0.1:9090}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0"
command -v python3 >/dev/null || die "需要 python3"

# ── 从配置里找 shared 接口 ────────────────────────────────────────────────────
IFACE="$(python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for i in d.get("inbounds", []):
    if i.get("type") == "ebpf":
        sh = i.get("shared") or {}
        if sh.get("enabled") and sh.get("interface"):
            print(sh["interface"][0]); raise SystemExit
print("")
PY
)"
[[ -n $IFACE ]] || die "配置里没有启用 shared（先用：sudo ./switch-to-ebpf.sh --shared <接口>）"
ip link show "$IFACE" >/dev/null 2>&1 || die "接口 $IFACE 不存在"
say "shared 接口：$IFACE"

CIDR="$(ip -brief addr show "$IFACE" | awk '{print $3}' | head -1)"
[[ -n $CIDR ]] || die "$IFACE 上没有 IPv4 地址，无法取网段"
GW="${CIDR%%/*}"; PREFIX="${CIDR##*/}"
CLIENT_IP="$(awk -F. -v p="250" '{print $1"."$2"."$3"."p}' <<<"$GW")"
say "网段 $CIDR → 测试客户端 $CLIENT_IP/$PREFIX，网关 $GW"

NS=sb-shared-test; VH=sbveth-h; VC=sbveth-c
cleanup() {
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VH" 2>/dev/null || true
    rm -rf "/etc/netns/$NS" 2>/dev/null || true
}
trap 'cleanup' EXIT
cleanup   # 先清一遍，避免上次残留
sleep 0.5

say "① 建 netns + veth，并把宿主端接进 $IFACE"
ip netns add "$NS"
ip link add "$VH" type veth peer name "$VC"
ip link set "$VC" netns "$NS"
ip link set "$VH" master "$IFACE"
ip link set "$VH" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$VC" up
ip netns exec "$NS" ip addr add "$CLIENT_IP/$PREFIX" dev "$VC"
ip netns exec "$NS" ip route add default via "$GW" 2>/dev/null || \
    ip netns exec "$NS" ip route add default dev "$VC"
# 关键：netns 里没有 systemd-resolved（127.0.0.53 是它自己的 loopback）。
# 给它一份 netns 专用 resolv.conf，指向公共解析器 —— 该查询会被 shared 的 dns_mode=hijack 接管，
# 所以这一步同时验证了「DNS 劫持」在共享路径上是否生效。
mkdir -p "/etc/netns/$NS"
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "/etc/netns/$NS/resolv.conf"
printf '   netns DNS: %s\n' "$(tr '\n' ' ' < "/etc/netns/$NS/resolv.conf")"
printf '   桥状态: %s\n' "$(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo '?')"
printf '   客户端路由: %s\n' "$(ip netns exec "$NS" ip route show default | head -1)"
sleep 2   # 等桥 learning / carrier 稳定

inside() { ip netns exec "$NS" "$@"; }
say "② 在 netns 里发请求（同时盯 Clash API，看有没有来自 $CLIENT_IP 的连接）"
CLASH_JSON="$(python3 - "$CLASH" "$NS" "$(python3 -c "
import json;d=json.load(open('$CONF'));print((d.get('experimental',{}).get('clash_api') or {}).get('secret',''))")" "$CLIENT_IP" <<'PY'
import json, subprocess, sys, threading, time, urllib.request
clash, ns, secret, client_ip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def conns():
    r = urllib.request.Request(f"{clash}/connections")
    if secret: r.add_header("Authorization", f"Bearer {secret}")
    with urllib.request.urlopen(r, timeout=6) as x:
        return json.loads(x.read().decode()).get("connections", [])
try:
    base = {c.get("id") for c in conns()}
except Exception as e:
    print(json.dumps({"error": str(e)})); raise SystemExit
hits, stop = [], threading.Event()
def poll():
    while not stop.is_set():
        try:
            for c in conns():
                if c.get("id") in base: continue
                md = c.get("metadata", {}) or {}
                if md.get("sourceIP") == client_ip or md.get("sourceIP", "").startswith(client_ip.rsplit(".", 1)[0]):
                    hits.append({"host": md.get("host",""), "dest": md.get("destinationIP",""),
                                 "port": md.get("destinationPort",""),
                                 "rule": c.get("rule",""), "chains": list(reversed(c.get("chains", [])))})
        except Exception: pass
        time.sleep(0.03)
t = threading.Thread(target=poll, daemon=True); t.start()
# 从 netns 里发真实请求（由外层 shell 调用）
subprocess.run(["ip","netns","exec",ns,"sh","-c",
                "curl -s -m 12 https://api.ipify.org > /tmp/sb-ns-exit.txt 2>/dev/null; "
                "curl -s -m 12 https://myip.ipip.net > /tmp/sb-ns-cn.txt 2>/dev/null; "
                "curl -s -m 12 -o /dev/null https://www.google.com 2>/dev/null; echo $? > /tmp/sb-ns-google.txt; "
                "curl -s -m 12 https://api.ipify.org -x http://192.168.122.1:7892 >/dev/null 2>&1 || true"],
               capture_output=True, timeout=60)
time.sleep(0.5); stop.set(); t.join(timeout=2)
print(json.dumps({"hits": hits[:6], "total": len(hits)}))
PY
)"
NS_EXIT="$(cat /tmp/sb-ns-exit.txt 2>/dev/null || true)"
NS_CN="$(cat /tmp/sb-ns-cn.txt 2>/dev/null || true)"
NS_GOOGLE="$(cat /tmp/sb-ns-google.txt 2>/dev/null || true)"
rm -f /tmp/sb-ns-exit.txt /tmp/sb-ns-cn.txt /tmp/sb-ns-google.txt
PROXY_EXIT="$(curl -s -m 10 -x http://127.0.0.1:7892 https://api.ipify.org 2>/dev/null || true)"
HOST_DIRECT="$(curl -s -m 10 https://api.ipify.org 2>/dev/null || true)"

say "③ 结果"
printf '   netns 客户端出口 : %s\n' "${NS_EXIT:-（失败）}"
printf '   经本地代理口出口 : %s\n' "${PROXY_EXIT:-（失败）}"
printf '   宿主不设代理出口 : %s\n' "${HOST_DIRECT:-（失败）}"
printf '   netns 查国内出口 : %s\n' "${NS_CN:0:64}"
printf '   netns 访问 google: %s\n' "$( [[ ${NS_GOOGLE:-1} == 0 ]] && echo '成功' || echo "失败(exit=${NS_GOOGLE:-?})" )"
python3 - "$CLASH_JSON" <<'PY'
import json, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
if d.get("error"):
    print(f"   Clash API: 读不到（{d['error']}）")
    raise SystemExit
print(f"   Clash API 记录到来自 netns 的连接: {d.get('total',0)} 条")
for h in d.get("hits", [])[:4]:
    print(f"     {h['host'] or h['dest']}:{h['port']} 规则={h['rule'] or '-'} 链路={' → '.join(h['chains']) or '-'}")
PY

echo
if [[ -n $NS_EXIT && -n $PROXY_EXIT && $NS_EXIT == "$PROXY_EXIT" ]]; then
    printf '  \033[1;32m✅ 共享接管成功\033[0m：netns 里的流量确实被 eBPF shared 接管并走了代理\n'
    RC=0
elif [[ -n $NS_EXIT && $NS_EXIT == "$HOST_DIRECT" ]]; then
    printf '  \033[1;31m❌ 没被接管\033[0m：netns 出口 = 宿主直连出口，说明流量绕过了 sing-box\n'
    RC=1
else
    printf '  \033[1;33m⚠️ 结论不明\033[0m：netns 出口拿不到（链路/网段/桥的问题）\n'
    RC=2
fi

if (( KEEP )); then
    warn "--keep：保留 netns $NS 与 veth $VH，自己进去看：ip netns exec $NS sh"
    printf '   清掉：ip netns del %s; ip link del %s\n' "$NS" "$VH"
    trap - EXIT
else
    say "④ 清理临时环境"
    cleanup
    printf '   已删除 netns %s 与 veth %s\n' "$NS" "$VH"
fi
exit $RC
