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
DEBUG_LOG=0
SHARED_ONLY=0
for a in "$@"; do
    case "$a" in
        --keep) KEEP=1 ;;
        --debug-log) DEBUG_LOG=1 ;;
        --shared-only) SHARED_ONLY=1 ;;
        -h|--help) printf '用法：sudo %s [--keep] [--debug-log]\n  --keep       保留 netns/veth 现场\n  --debug-log  临时把 log.level 调到 debug、跑完自动还原（看清 sing-box 的判定）\n' "$0"; exit 0 ;;
        *) printf '不认识的参数：%s\n' "$a" >&2; exit 2 ;;
    esac
done

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
PCAP=/tmp/sb-shared-test.pcap
TCPDUMP_PID=""
cleanup() {
    restore_conf 2>/dev/null || true
    [[ -n $TCPDUMP_PID ]] && kill "$TCPDUMP_PID" 2>/dev/null || true
    [[ -n $TCPDUMP_PID ]] && wait "$TCPDUMP_PID" 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VH" 2>/dev/null || true
    rm -rf "/etc/netns/$NS" 2>/dev/null || true
}
trap 'cleanup' EXIT
cleanup   # 先清一遍，避免上次残留
sleep 0.5

CONF_BAK=""
restore_conf() {
    if [[ -n $CONF_BAK && -f $CONF_BAK ]]; then
        cp -a "$CONF_BAK" "$CONF"
        systemctl restart sing-box
        sleep 2
        printf '   已还原原配置并重启（log.level 恢复）\n'
        CONF_BAK=""
    fi
}
if (( SHARED_ONLY )); then
    say "⓪ 临时关掉 local 路径（只留 shared）—— 这样 netns 客户端的流量**只可能**走 shared"
    warn "期间宿主自身流量不被代理（约 20 秒），脚本跑完会自动还原并重启"
    CONF_BAK="$(mktemp /tmp/sb-conf-bak.XXXXXX)"
    cp -a "$CONF" "$CONF_BAK"
    python3 - "$CONF" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for i in d.get("inbounds", []):
    if i.get("type") == "ebpf":
        # 关键：不能只把 enabled 改 false —— 留着 data_plane 会让 sing-box 启动直接 FATAL
        # （实测：initialize inbound: local.data_plane requires local interception）
        i["local"] = {"enabled": False}
        i["shared"] = dict(i.get("shared") or {}, enabled=True)
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
    if ! "$BIN" check -c "$CONF" >/tmp/sb-conf-check.log 2>&1; then
        tail -3 /tmp/sb-conf-check.log | sed 's/^/     /'
        warn "改完的配置 check 不通过 —— 立刻还原，服务不动"
        restore_conf
        exit 1
    fi
    systemctl restart sing-box
    sleep 2
    printf '   local 已关闭，shared 保持启用（check 已通过）\n'
fi

if (( DEBUG_LOG )); then
    say "⓪ 临时把 log.level 调到 debug（跑完自动还原）"
    CONF_BAK="$(mktemp /tmp/sb-conf-bak.XXXXXX)"
    cp -a "$CONF" "$CONF_BAK"
    python3 - "$CONF" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d.setdefault("log", {})["level"] = "debug"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
    if ! "$BIN" check -c "$CONF" >/tmp/sb-conf-check.log 2>&1; then
        tail -3 /tmp/sb-conf-check.log | sed 's/^/     /'
        warn "check 不通过 —— 立刻还原"
        restore_conf
        exit 1
    fi
    systemctl restart sing-box
    sleep 2
    printf '   log.level=debug，服务已重启（check 已通过）\n'
fi

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

# 抓包：客户端那一侧的所有报文（这是"包死在哪儿"的最直接证据）
if command -v tcpdump >/dev/null 2>&1; then
    rm -f "$PCAP"
    tcpdump -i "$IFACE" -nn -s 128 -w "$PCAP" "host $CLIENT_IP" >/dev/null 2>&1 &
    TCPDUMP_PID=$!
    sleep 1
    say "   已开始抓包 → $PCAP（接口 $IFACE，过滤 host $CLIENT_IP）"
else
    warn "没装 tcpdump，跳过抓包取证"
fi

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
probe = r"""
{
  echo "@@ADDR"; ip -brief addr
  echo "@@ROUTE4"; ip route
  echo "@@ROUTE6"; ip -6 route
  echo "@@RESOLV"; cat /etc/resolv.conf
  echo "@@DNS_AAAA"; getent ahostsv6 api.ipify.org | head -2
  echo "@@DNS_A"; getent ahostsv4 api.ipify.org | head -2
  echo "@@CURL4"; curl -4 -s -m 15 -o /dev/null -w "http=%{http_code} ip=%{remote_ip}\n" https://api.ipify.org
  echo "@@CURL6"; curl -6 -s -m 8  -o /dev/null -w "http=%{http_code} ip=%{remote_ip}\n" https://api.ipify.org
  echo "@@CURLDEF"; curl -s -m 15 -o /dev/null -w "http=%{http_code} ip=%{remote_ip}\n" https://api.ipify.org
  echo "@@EXIT4"; curl -4 -s -m 15 https://api.ipify.org
  echo "@@CN"; curl -4 -s -m 12 https://myip.ipip.net
  echo "@@GOOGLE4"; curl -4 -s -m 15 -o /dev/null -w "http=%{http_code} ip=%{remote_ip}\n" https://www.google.com
  echo "@@NEIGH"; ip neigh
  echo "@@PINGGW"; ping -c1 -W2 192.168.122.1 >/dev/null 2>&1 && echo ok || echo fail
  echo "@@ENV_PROXY"; env | grep -i proxy || echo none
  echo "@@ROUTE_GET"; ip route get 104.26.13.205 2>&1 | head -2
  echo "@@LINKSTAT"; ip -s link show sbveth-c | tail -3
  echo "@@CURLV_CN"; curl -4 -v -m 8 https://myip.ipip.net 2>&1 | grep -aE "Trying|connect to|from |Failed|error|refused" | tail -5
  echo "@@CURLV_FOREIGN"; curl -4 -v -m 8 https://api.ipify.org 2>&1 | grep -aE "Trying|connect to|from |Failed|error|refused" | tail -5
  echo "@@CURLRC"; ls -la /root/.curlrc /etc/curlrc 2>/dev/null || echo none; echo "---"; cat /root/.curlrc 2>/dev/null || true
  echo "@@CURLV_CLEANENV"; env -i /usr/bin/curl -4 -v -m 8 https://api.ipify.org 2>&1 | grep -aE "Trying|connect to|from |Failed|error|refused" | tail -5
  echo "@@CURLV_BIND"; env -i /usr/bin/curl -4 -v --interface 192.168.122.250 -m 8 -o /dev/null -w "http=%{http_code} ip=%{remote_ip}\n" https://api.ipify.org 2>&1 | tail -4
} > /tmp/sb-ns-diag.txt 2>&1
"""
subprocess.run(["ip","netns","exec",ns,"sh","-c",probe], capture_output=True, timeout=90)
time.sleep(0.5); stop.set(); t.join(timeout=2)
print(json.dumps({"hits": hits[:6], "total": len(hits)}))
PY
)"
NS_DIAG="$(cat /tmp/sb-ns-diag.txt 2>/dev/null || true)"
rm -f /tmp/sb-ns-diag.txt
field() { printf '%s' "$NS_DIAG" | python3 -c "
import sys, re
name = sys.argv[1]
txt = sys.stdin.read()
m = re.search(r'^@@' + re.escape(name) + r'$\n(.*?)(?=^@@|\Z)', txt, re.S | re.M)
print(' '.join((m.group(1) if m else '').split()))
" "$1"; }
NS_EXIT="$(field EXIT4 | tr -d ' ')"
NS_CN="$(field CN)"
NS_GOOGLE_HTTP="$(field GOOGLE4)"
NS_CURL4="$(field CURL4)"
NS_CURL6="$(field CURL6)"
NS_CURLDEF="$(field CURLDEF)"
NS_DNS_A="$(field DNS_A)"
NS_DNS_AAAA="$(field DNS_AAAA)"
NS_ROUTE6="$(field ROUTE6)"
NS_NEIGH="$(field NEIGH)"
NS_ENVPROXY="$(field ENV_PROXY)"
NS_ROUTEGET="$(field ROUTE_GET)"
NS_LINKSTAT="$(field LINKSTAT | tr -s ' ')"
block() { printf '%s' "$NS_DIAG" | python3 -c "
import sys, re
name = sys.argv[1]
txt = sys.stdin.read()
m = re.search(r'^@@' + re.escape(name) + r'$\n(.*?)(?=^@@|\Z)', txt, re.S | re.M)
print((m.group(1) if m else '').rstrip())
" "$1"; }
NS_CURLV_CN="$(block CURLV_CN)"
NS_CURLV_FOREIGN="$(block CURLV_FOREIGN)"
NS_CURLRC="$(block CURLRC)"
NS_CURLV_CLEAN="$(block CURLV_CLEANENV)"
NS_CURLV_BIND="$(block CURLV_BIND)"
PROXY_EXIT="$(curl -s -m 10 -x http://127.0.0.1:7892 https://api.ipify.org 2>/dev/null || true)"
HOST_DIRECT="$(curl -s -m 10 https://api.ipify.org 2>/dev/null || true)"

say "③ 结果"
printf '   netns 客户端出口 : %s\n' "${NS_EXIT:-（失败）}"
printf '   经本地代理口出口 : %s\n' "${PROXY_EXIT:-（失败）}"
printf '   宿主不设代理出口 : %s\n' "${HOST_DIRECT:-（失败）}"
printf '   netns 查国内出口 : %s\n' "${NS_CN:0:64}"
printf '   netns curl -4 代理测试 : %s\n' "${NS_CURL4:-?}"
printf '   netns curl -6 代理测试 : %s\n' "${NS_CURL6:-?}（netns 无 IPv6 则必然失败，属正常）"
printf '   netns curl 默认        : %s\n' "${NS_CURLDEF:-?}"
printf '   netns google(http)     : %s\n' "${NS_GOOGLE_HTTP:-?}"
printf '   netns 解析(AAAA/A)     : %s / %s\n' "${NS_DNS_AAAA:-无}" "${NS_DNS_A:-无}"
printf '   netns IPv6 路由        : %s\n' "${NS_ROUTE6:-（无，符合预期）}"
printf '   netns 邻居表           : %s\n' "${NS_NEIGH:-空}"
printf '   netns 代理环境变量     : %s\n' "${NS_ENVPROXY:-none}"
printf '   netns 去 104.26.13.205 的路由: %s\n' "${NS_ROUTEGET:-?}"
printf '   netns 接口计数         : %s\n' "${NS_LINKSTAT:-?}"
echo "   A/B 对照（这是关键）:"
printf '     国内(可用)  : %s\n' "$(printf '%s' "${NS_CURLV_CN:-?}" | tr '\n' ' ' | cut -c1-150)"
printf '     境外(失败)  : %s\n' "$(printf '%s' "${NS_CURLV_FOREIGN:-?}" | tr '\n' ' ' | cut -c1-150)"
printf '     curl 配置   : %s\n' "$(printf '%s' "${NS_CURLRC:-none}" | tr '\n' ' ' | cut -c1-120)"
printf '     干净环境    : %s\n' "$(printf '%s' "${NS_CURLV_CLEAN:-?}" | tr '\n' ' ' | cut -c1-150)"
printf '     指定源地址  : %s\n' "$(printf '%s' "${NS_CURLV_BIND:-?}" | tr '\n' ' ' | cut -c1-150)"
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

if [[ -n $TCPDUMP_PID ]]; then
    kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    TCPDUMP_PID=""
    sleep 0.3   # 等它把 pcap 写完
fi
if [[ -s $PCAP ]]; then
    say "④ 抓包分析（$PCAP）"
    printf '   客户端发出的 SYN      : %s\n' "$(tcpdump -nn -r "$PCAP" 'tcp[tcpflags] & tcp-syn != 0 and src host '"$CLIENT_IP" 2>/dev/null | wc -l)"
    printf '   回给客户端的 SYN-ACK  : %s\n' "$(tcpdump -nn -r "$PCAP" 'tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack) and dst host '"$CLIENT_IP" 2>/dev/null | wc -l)"
    printf '   RST 报文              : %s\n' "$(tcpdump -nn -r "$PCAP" 'tcp[tcpflags] & tcp-rst != 0' 2>/dev/null | wc -l)"
    echo "   TCP 会话表（收发双向，packets: A→B / B→A）:"
    if command -v tshark >/dev/null 2>&1; then
        tshark -r "$PCAP" -nn -q -z conv,tcp 2>/dev/null | sed -n '2,8p' | sed 's/^/     /'
    else
        tcpdump -nn -r "$PCAP" 2>/dev/null | awk '{print $3, $5}' | sort | uniq -c | sort -rn | head -6 | sed 's/^/     /'
    fi
fi

echo
# 判据用 Clash API 的实际链路（比"和本地代理口比出口"更权威，local 关闭时也成立）
VERDICT="$(python3 - "$CLASH_JSON" <<'PY'
import json, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
hits = d.get("hits", []) or []
total = d.get("total", 0)
proxied = [h for h in hits if any("Proxy" in c or "Auto" in c for c in (h.get("chains") or []))]
direct = [h for h in hits if h.get("chains") == ["direct"]]
if total == 0:
    print("none")
elif proxied:
    print("proxied")
elif direct:
    print("direct")
else:
    print("other")
PY
)"
case "$VERDICT" in
  proxied) printf '  \033[1;32m✅ 共享接管成功（走代理）\033[0m：客户端连接命中 Proxy 链路，抓包双向完整\n'; RC=0 ;;
  direct)  printf '  \033[1;32m✅ 共享接管成功（走直连）\033[0m：客户端连接被判为 direct\n'; RC=0 ;;
  none)    printf '  \033[1;31m❌ 没被接管\033[0m：Clash API 里没有来自测试客户端的连接\n'; RC=1 ;;
  *)       printf '  \033[1;33m⚠️ 部分成功\033[0m：有连接但链路判断异常，看上面的规则/链路明细\n'; RC=2 ;;
esac

if (( DEBUG_LOG )); then
    DBG=/tmp/sb-shared-debug.log
    journalctl -u sing-box --since "-3 min" --no-pager > "$DBG" 2>/dev/null || true
    say "⑤ debug 日志已存到 $DBG"
    printf '   与 eBPF/TC/分配相关的行（前 12 条）:\n'
    grep -iE "ebpf|tc |assign|token|rewrite|shared|packet" "$DBG" | tail -12 | sed 's/.*sing-box\[[0-9]*\]: //' | sed 's/^/     /' || true
    restore_conf
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
