#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# probe-local-names.sh —— 只读自查：本局域网里"到底有没有可解析的内网主机名"
#
# 用法：bash scripts/probe-local-names.sh          # 不需要 root，不改任何文件，约 20 秒
#
# 为什么需要它：docs/11 §2.1 的 P2-1（给 `.lan/.home` 加本地域直查）已因"本网络没有本地
# 域名空间"而撤回。本脚本把这件事一次查清：DHCP 有没有下发搜索域、邻居表里有哪些设备、
# 这些设备的 PTR 反查有没有名字、常见主机名/mDNS 能不能解析出**内网地址**。
#
# 判读（脚本末尾会再打印一次）：
#   出现"名字 ↔ 内网 IP(10./172.16-31./192.168./fd../fe80../::1)" ⇒ 存在内网名字空间，
#       值得单独设计解析方案（若来自 mDNS 则与 sing-box 无关）；
#   全部为空 / NXDOMAIN / 超时 / 只解析出公网 IP ⇒ 确认没有，P2-1 撤回正确。
#
# 已知干扰（如实标注）：本机所有 53 端口探测都可能被自己的 eBPF 入站（`dns_mode: hijack`）
# 截获，所以"超时/NXDOMAIN"未必反映路由器本体。因此第 6 节的"路由器管理页"是**权威且不
# 经 DNS** 的交叉验证手段。
# ---------------------------------------------------------------------------
set -uo pipefail

GW="$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')"
SYS_DNS="$(resolvectl dns 2>/dev/null | awk '{for(i=2;i<=NF;i++) print $i}' | sort -u | tr '\n' ' ')"
HITS=0
hr() { printf '\n%s\n' "──── $* ────────────────────────────────────────"; }
hit() { HITS=$((HITS+1)); printf '   \033[32m★ 内网名命中\033[0m %s\n' "$*"; }

# 只把"内网地址"算作命中：公网 IP（如 miwifi.com → 106.120.x.x）说明解析走的是上游公网 DNS。
is_private_ip() {
  case "$1" in
    10.*|192.168.*|127.*|fd*|fe80*|::1*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}
# dig +short 在超时时会把 ";; communications error ..." 打到 stdout，必须滤掉，否则误报。
clean_dig() { grep -vE '^;' | head -1; }

printf '本机内网名空间自查（只读）· %s\n' "$(date '+%F %T')"
printf '默认网关: %s   系统正在用的 DNS: %s\n' "${GW:-N/A}" "${SYS_DNS:-N/A}"

hr "1. DHCP / RA 有没有下发'搜索域'（有搜索域才存在'本地域'概念）"
printf '   nmcli IP4.DOMAIN : %s\n' "$(nmcli -f IP4.DOMAIN device show 2>/dev/null | grep -v '^$' | tr '\n' ' ' | sed 's/  */ /g')"
printf '   resolvectl domain: %s\n' "$(resolvectl domain 2>/dev/null | tr '\n' ' ')"
printf '   ⇒ 都为空 = 网络没有宣告任何本地域（P2-1 撤回第 1 条依据）\n'

hr "2. 本机自己认识哪些内网名"
grep -vE '^\s*#|^\s*$' /etc/hosts 2>/dev/null | sed 's/^/   /' || true
printf '   nsswitch hosts: %s\n' "$(awk '/^\s*hosts:/{ $1=""; print; exit }' /etc/nsswitch.conf 2>/dev/null)"

hr "3. 局域网邻居表（实际在线的设备）"
ip neigh show 2>/dev/null | grep -E '^(192\.168\.|10\.|172\.)' | sed 's/^/   /' | head -12
NEIGHBORS="$(ip neigh show 2>/dev/null | awk '/^(192\.168\.|10\.|172\.)/{print $1}' | grep -v "^${GW}$" | head -6)"
printf '   共 %s 个邻居（下面最多对 6 个做反查）\n' "$(ip neigh show 2>/dev/null | grep -cE '^(192\.168\.|10\.|172\.)')"

hr "4. 这些设备的 PTR 反查有没有'名字'（分别问系统解析器 / 网关）"
if [ -z "$NEIGHBORS" ]; then printf '   （没有可反查的邻居）\n'; fi
for ip in $NEIGHBORS; do
  a="$(dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null | clean_dig)"
  b=""; [ -n "$GW" ] && b="$(dig +short +time=1 +tries=1 -x "$ip" "@$GW" 2>/dev/null | clean_dig)"
  printf '   %-16s 系统解析器: %-24s 网关: %s\n' "$ip" "${a:-（无）}" "${b:-（无）}"
  [ -n "$a" ] && hit "PTR $ip → $a"
  [ -n "$b" ] && hit "PTR $ip → $b（经网关）"
done
printf '   ⇒ 全是"（无）"= 没有任何设备注册了 DNS 名字\n'

hr "5. 常见主机名 + mDNS 探测（mDNS 不经路由器 DNS；若能用则根本不必改 sing-box）"
for n in router router.lan nas nas.lan server openwrt; do
  r="$(timeout 2 getent hosts "$n" 2>/dev/null | head -1)"
  ip="${r%% *}"
  printf '   %-12s getent: %s\n' "$n" "${r:-（无）}"
  if [ -n "$r" ]; then
    if is_private_ip "$ip"; then hit "getent $n → $r（内网）"; else printf '        ↑ 公网地址，不算内网名\n'; fi
  fi
done
# 对照：一个已知的公网小米域名 —— 若它也解析成功，说明系统 DNS 走公网上游（与内网名无关）
m="$(timeout 2 getent hosts miwifi.com 2>/dev/null | head -1)"
printf '   %-12s getent: %s   ← 对照（公网名）\n' miwifi.com "${m:-（无）}"
if command -v avahi-browse >/dev/null; then
  printf '   --- avahi-browse（mDNS，最多 4 秒）---\n'
  timeout 4 avahi-browse -at 2>/dev/null | grep -E '^=' | head -6 | sed 's/^/   /' || true
else
  printf '   avahi-browse 未安装（mDNS 自查可试： timeout 2 resolvectl query <主机名>.local）\n'
fi

hr "6. 权威交叉验证：路由器管理页（HTTP，不经 DNS，不受 eBPF 劫持影响）"
printf '   打开 http://%s 看"已连接设备/终端管理"——那里列出的名字才是真的。\n' "${GW:-192.168.31.1}"

hr "判读"
if [ "$HITS" -gt 0 ]; then
  printf '   ★ 内网名命中 %s 项。⇒ **本网络有可解析的内网名字**，值得单独设计解析方案。\n' "$HITS"
  printf '   注意：若命中来自 mDNS(.local/avahi)，则与 sing-box 无关，不需要改配置。\n'
else
  printf '   0 命中。⇒ 本网络没有可解析的内网主机名，"本地域直查"没有查询对象；\n'
  printf '   与 docs/11 §3.8 的结论一致（P2-1 撤回正确）。\n'
fi
printf '   提醒：若上面多为"超时"，可能是本机 eBPF（dns_mode: hijack）截获了探针，\n'
printf '   此时以第 6 节的路由器管理页为准。\n'
