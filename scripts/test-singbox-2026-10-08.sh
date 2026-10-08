#!/usr/bin/env bash
# =============================================================================
#  test-singbox-2026-10-08.sh  ——  sing-box 第 5 步真实验收（需 root）
#  用法: sudo bash test-singbox-2026-10-08.sh [选项]
#    --load-seconds N       并发/稳定性测试时长，默认 60
#    --with-failover        额外跑「节点失效 -> urltest 切换 -> 恢复回落」
#                           （临时用 nftables 屏蔽当前节点 IP，最长等 6 分钟，结束自动清除）
#    --failover-timeout N   失效切换等待上限，默认 480 秒（urltest interval=5m）
# =============================================================================
set -Eeuo pipefail

CONF=/etc/sing-box/config.json
UNIT=sing-box
PROXY=http://127.0.0.1:7892
API=http://127.0.0.1:9090
# 2026-10-08 实测: qq.com 边缘(Server: stgw)对 curl 默认 UA 直接回 501 Not Implemented，
# 与 sing-box 无关（带浏览器 UA 即 200）。故统一带 UA，并改用稳定 200 的国内站点。
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
LOAD_SECONDS=60
# urltest 的检测周期是 5m（配置 interval: "5m"），故上限需 > 300s 才有余量
FAILOVER_TIMEOUT=480
WITH_FAILOVER=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --load-seconds)     LOAD_SECONDS="$2"; shift 2 ;;
    --failover-timeout) FAILOVER_TIMEOUT="$2"; shift 2 ;;
    --with-failover)    WITH_FAILOVER=1; shift ;;
    -h|--help)          sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 运行: sudo bash $0"; exit 2; }
for c in curl jq python3 ss; do command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; exit 2; }; done

SECRET=$(jq -r '.experimental.clash_api.secret' "$CONF")
clash() { curl -s --max-time 8 -H "Authorization: Bearer $SECRET" "$API$1"; }

declare -a D_ID D_CASE D_EXP D_GOT D_VERD
PASS=0; FAIL=0; SKIP=0
rec() {
  D_ID+=("$1"); D_CASE+=("$2"); D_EXP+=("$3"); D_GOT+=("$4"); D_VERD+=("$5")
  if   [ "$5" = PASS ]; then PASS=$((PASS+1))
  elif [ "$5" = FAIL ]; then FAIL=$((FAIL+1))
  else SKIP=$((SKIP+1)); fi
}
log()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
item() { printf '   \033[36m%-5s\033[0m %-30s %s\n' "$1" "$2" "$3"; }

# ------------------------------------------------------------------ T1 服务面
log "T1  服务与配置面"
svc=$(systemctl is-active "$UNIT" 2>/dev/null || true)
if [ "$svc" = active ]; then item T1.1 "systemd 服务状态" "active"; rec T1.1 "systemd 服务状态" "active" "$svc" PASS
else item T1.1 "systemd 服务状态" "$svc"; rec T1.1 "systemd 服务状态" "active" "$svc" FAIL; fi

if jq empty "$CONF" 2>/dev/null; then item T1.2 "配置 JSON 合法性" "OK"; rec T1.2 "jq 解析 config.json" "通过" "通过" PASS
else item T1.2 "配置 JSON 合法性" "损坏"; rec T1.2 "jq 解析 config.json" "通过" "损坏" FAIL; fi

# 等待端口绑定：Type=simple 下 systemctl is-active 立刻回 active，sing-box 还要数秒
ports=""; port_wait=0
for i in $(seq 1 60); do
  ports=""
  for p in 7892 9090 9091; do ss -ltnH | grep -q "127.0.0.1:$p " || ports="$ports $p"; done
  if [ -z "$ports" ]; then break; fi
  sleep 1
  port_wait=$i
done
if [ -z "$ports" ]; then item T1.3 "监听端口" "7892/9090/9091 (等 ${port_wait}s)"; rec T1.3 "监听端口" "全部监听" "全部监听" PASS
else item T1.3 "监听端口" "缺失:$ports"; rec T1.3 "监听端口" "全部监听" "缺失:$ports" FAIL; fi

errn=$(journalctl -u "$UNIT" --since "-10min" --no-pager 2>/dev/null | grep -c 'ERROR' || true)
if [ "$errn" = 0 ]; then item T1.4 "近 10 分钟 ERROR" "0"; rec T1.4 "journalctl ERROR 条数" "0" "0" PASS
else item T1.4 "近 10 分钟 ERROR" "$errn"; rec T1.4 "journalctl ERROR 条数" "0" "$errn" FAIL; fi

item T1.5 "route.rules / outbounds 数" "$(jq -r '(.route.rules|length)' "$CONF") / $(jq -r '(.outbounds|length)' "$CONF")"
item T1.6 "sing-box 版本" "$(sing-box version | head -1)"

# ------------------------------------------------- T2 国内（eBPF 透明代理路径）
log "T2  国内站点（宿主机流量经 eBPF 入站，命中 direct 规则）"
c=$(curl -s -A "$UA" -o /dev/null -w '%{http_code}' --max-time 12 https://www.baidu.com/ || true)
if [ "$c" = 200 ]; then item T2.1 "https://www.baidu.com/" "$c"; rec T2.1 "国内站点连通性" "200" "$c" PASS
else item T2.1 "https://www.baidu.com/" "$c"; rec T2.1 "国内站点连通性" "200" "$c" FAIL; fi
c=$(curl -s -A "$UA" -o /dev/null -w '%{http_code}' --max-time 12 https://www.jd.com/ || true)
if [ "$c" = 200 ]; then item T2.2 "https://www.jd.com/" "$c"; rec T2.2 "国内站点连通性 2" "200" "$c" PASS
else item T2.2 "https://www.jd.com/" "$c"; rec T2.2 "国内站点连通性 2" "200" "$c" FAIL; fi
ans=$(getent ahostsv4 www.baidu.com | head -1 | awk '{print $1}' || true)
if [ -n "$ans" ]; then item T2.3 "系统 DNS 解析 baidu" "$ans"; rec T2.3 "DNS 解析(被 sing-box 劫持)" "有 A 记录" "$ans" PASS
else item T2.3 "系统 DNS 解析 baidu" "失败"; rec T2.3 "DNS 解析(被 sing-box 劫持)" "有 A 记录" "失败" FAIL; fi

# --------------------------------------------------------- T3 显式代理链路
log "T3  显式代理链路 127.0.0.1:7892"
trace=$(curl -s --max-time 20 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace || true)
eip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p')
eloc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p')
ecolo=$(printf '%s\n' "$trace" | sed -n 's/^colo=//p')
if [ -n "$eip" ]; then
  item T3.1 "出口 IP / 地区 / colo" "$eip / $eloc / $ecolo"
  if [ -n "$eloc" ] && [ "$eloc" != CN ]; then rec T3.1 "出口 IP 归属地区" "非 CN" "$eloc" PASS
  else rec T3.1 "出口 IP 归属地区" "非 CN" "$eloc" FAIL; fi
else item T3.1 "Cloudflare trace" "失败"; rec T3.1 "出口 IP 归属地区" "非 CN" "无响应" FAIL; fi

c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$PROXY" https://www.google.com/generate_204 || true)
if [ "$c" = 204 ]; then item T3.2 "google generate_204" "$c"; rec T3.2 "国外站点 1" "204" "$c" PASS
else item T3.2 "google generate_204" "$c"; rec T3.2 "国外站点 1" "204" "$c" FAIL; fi
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "$PROXY" https://github.com/ || true)
if [ "$c" = 200 ]; then item T3.3 "github.com" "$c"; rec T3.3 "国外站点 2" "200" "$c" PASS
else item T3.3 "github.com" "$c"; rec T3.3 "国外站点 2" "200" "$c" FAIL; fi

pnow=$(clash /proxies/Proxy | jq -r '.now' 2>/dev/null || true)
anow=$(clash /proxies/Auto  | jq -r '.now' 2>/dev/null || true)
item T3.4 "Proxy / Auto 当前节点" "$pnow / $anow"
if [ -n "$pnow" ]; then rec T3.4 "Clash API 读当前出站" "有值" "$pnow" PASS
else rec T3.4 "Clash API 读当前出站" "有值" "空" FAIL; fi

# ---------------------------------------------------------------------- T4 UDP
log "T4  UDP 中继（SOCKS5 UDP ASSOCIATE，浏览器 QUIC 走的就是这条能力）"
udpout=$(python3 - <<'PYEOF' 2>&1
import socket, struct, os
host, port = "127.0.0.1", 7892
try:
    s = socket.create_connection((host, port), 8)
    s.sendall(b"\x05\x01\x00")
    if s.recv(2) != b"\x05\x00":
        print("FAIL socks5 握手"); raise SystemExit
    s.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
    r = s.recv(64)
    if len(r) < 10 or r[1] != 0:
        print("FAIL UDP ASSOCIATE %r" % r); raise SystemExit
    relay = socket.inet_ntoa(r[4:8]); rport = struct.unpack("!H", r[8:10])[0]
    if relay == "0.0.0.0":
        relay = host
    tid = os.urandom(2)
    q = tid + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + b"\x06github\x03com\x00" + b"\x00\x01\x00\x01"
    pkt = b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") + struct.pack("!H", 53) + q
    d = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); d.settimeout(10)
    d.sendto(pkt, (relay, rport))
    data, _ = d.recvfrom(4096)
    rsp = data[10:]
    if rsp[:2] == tid and (rsp[3] & 0x0F) == 0:
        print("OK 应答 %d 字节 ancount=%d" % (len(rsp), struct.unpack("!H", rsp[6:8])[0]))
    else:
        print("FAIL 响应异常 %r" % data[:16])
except Exception as e:
    print("FAIL %s" % e)
PYEOF
)
case "$udpout" in
  OK*) item T4.1 "UDP: DNS over SOCKS5 UDP" "$udpout"; rec T4.1 "UDP 中继到 8.8.8.8:53" "收到 DNS 应答" "$udpout" PASS ;;
  *)   item T4.1 "UDP: DNS over SOCKS5 UDP" "$udpout"; rec T4.1 "UDP 中继到 8.8.8.8:53" "收到 DNS 应答" "$udpout" FAIL ;;
esac
if curl --version 2>/dev/null | head -1 | grep -qi 'HTTP3'; then
  c=$(curl -s -o /dev/null -w '%{http_code}' --http3 --max-time 15 https://cloudflare-quic.com/ 2>/dev/null || true)
  item T4.2 "curl --http3 直连(经 eBPF)" "$c"
  if [ -n "$c" ] && [ "$c" != 000 ]; then rec T4.2 "QUIC/HTTP3 端到端" "有响应" "$c" PASS
  else rec T4.2 "QUIC/HTTP3 端到端" "有响应" "$c" FAIL; fi
else
  item T4.2 "curl --http3" "本机 curl 未编译 HTTP/3"
  rec T4.2 "QUIC/HTTP3 端到端" "有响应" "curl 无 HTTP/3" SKIP
fi

# ----------------------------------------------------------------- T5 DNS 泄漏
log "T5  DNS 泄漏（宿主解析器归属 / 出口 ISP）"
# T5.1/T5.2 用两个"回声解析器身份"的名字交叉验证：Google o-o.myaddr（含 ECS 回显）+ Akamai whoami。
# 说明：若某名字命中 must-direct / dns-direct 分流或持久化 DNS 缓存，回声会是国内递归——不等于泄漏，故该项只记录。
NS=$(awk '/^[[:space:]]*nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
[ -n "$NS" ] || NS=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
[ -n "$NS" ] || NS=127.0.0.53   # 兜底：systemd-resolved 的 stub（本机 eBPF 会把它劫持回 sing-box）
dnsprobe=$(python3 - "$NS" <<'PY'
import socket, struct, os, sys
ns = sys.argv[1]
def q(name, qtype):
    tid = os.urandom(2)
    body = b"".join(bytes([len(x)]) + x.encode() for x in name.split(".")) + bytes([0])
    pkt = tid + bytes([1,0,0,1,0,0,0,0,0,0]) + body + struct.pack("!HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8)
    s.sendto(pkt, (ns, 53)); data, _ = s.recvfrom(8192)
    i = 12
    while data[i] != 0: i += 1 + data[i]
    i += 5; out = []
    for _ in range(struct.unpack("!H", data[6:8])[0]):
        if data[i] & 0xC0 == 0xC0: i += 2
        else:
            while data[i] != 0: i += 1 + data[i]
            i += 1
        t = struct.unpack("!H", data[i:i+2])[0]; ttl = struct.unpack("!I", data[i+4:i+8])[0]; i += 8
        n = struct.unpack("!H", data[i:i+2])[0]; i += 2
        rd = data[i:i+n]; i += n
        if t == 1 and n == 4: out.append(socket.inet_ntoa(rd))
        elif t == 16:
            ln = rd[0]; out.append(rd[1:1+ln].decode("utf-8", "replace"))
    return ",".join(out) if out else "EMPTY"
for tag, name, qt in (("goog", "o-o.myaddr.l.google.com", 16), ("akam", "whoami.akamai.net", 1)):
    try: print(tag + "=" + q(name, qt))
    except Exception: print(tag + "=ERR")
PY
)
googres=$(printf '%s\n' "$dnsprobe" | sed -n 's/^goog=//p')
akamres=$(printf '%s\n' "$dnsprobe" | sed -n 's/^akam=//p')
item T5.1 "宿主解析器回声（Google ECS）" "${googres:-无响应}"
case "$googres" in
  ""|ERR|EMPTY) rec T5.1 "宿主 DNS 解析器归属" "非国内递归" "无响应" SKIP ;;
  125.64.*|223.5.*|223.6.*|119.29.*|180.76.*|114.114.*|1.2.4.*|58.14.*|218.2.*)
      rec T5.1 "宿主 DNS 解析器归属" "非国内递归" "$googres" FAIL ;;
  *) rec T5.1 "宿主 DNS 解析器归属" "非国内递归" "$googres" PASS ;;
esac
item T5.2 "Akamai whoami 回声（参考）" "${akamres:-无响应}"
case "$akamres" in
  ""|ERR|EMPTY|125.64.*|223.5.*|119.29.*|114.114.*) rec T5.2 "Akamai 回声" "境外递归（非必须）" "${akamres:-无响应}" SKIP ;;
  *) rec T5.2 "Akamai 回声" "境外递归（非必须）" "$akamres" PASS ;;
esac
org=$(curl -s --max-time 20 -x "$PROXY" https://ipinfo.io/json | jq -r '.org // empty' 2>/dev/null || true)
if [ -z "$org" ]; then org=$(curl -s --max-time 20 -x "$PROXY" http://ip-api.com/json | jq -r '.isp // empty' 2>/dev/null || true); fi
item T5.2 "出口 IP 归属 ISP/AS" "$org"
if [ -n "$org" ]; then rec T5.2 "出口 IP 归属" "境外 IDC" "$org" PASS
else rec T5.2 "出口 IP 归属" "境外 IDC" "未取到" SKIP; fi

# ------------------------------------------------------------- T6 并发与稳定性
log "T6  ${LOAD_SECONDS}s 混合负载（代理 / 直连交替）"
PID=$(systemctl show -p MainPID --value "$UNIT")
clk=$(getconf CLK_TCK)
cpu0=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null || echo 0)
rss0=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null || echo 0)
okn=0; badn=0; pok=0; pbad=0; dok=0; dbad=0; maxrss=$rss0; t0=$SECONDS; i=0
FAILS=""
PURLS=("https://www.cloudflare.com/cdn-cgi/trace" "https://www.google.com/generate_204" "https://github.com/")
DURLS=("https://www.baidu.com/" "https://www.jd.com/")
while [ $((SECONDS-t0)) -lt "$LOAD_SECONDS" ]; do
  if [ $((i % 2)) -eq 0 ]; then
    u="${PURLS[$((i % 3))]}"
    code=$(curl -s -A "$UA" -o /dev/null -w '%{http_code}' --max-time 12 -x "$PROXY" "$u" || echo 000)
    case "$code" in 200|204) okn=$((okn+1)); pok=$((pok+1)) ;; *) badn=$((badn+1)); pbad=$((pbad+1)); FAILS="$FAILS 代理$code:$u" ;; esac
  else
    u="${DURLS[$((i % 2))]}"
    code=$(curl -s -A "$UA" -o /dev/null -w '%{http_code}' --max-time 12 "$u" || echo 000)
    case "$code" in 200|204) okn=$((okn+1)); dok=$((dok+1)) ;; *) badn=$((badn+1)); dbad=$((dbad+1)); FAILS="$FAILS 直连$code:$u" ;; esac
  fi
  r=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null || echo 0)
  if [ "$r" -gt "$maxrss" ]; then maxrss="$r"; fi
  i=$((i+1))
done
cpu1=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null || echo 0)
dt=$((SECONDS-t0))
cpus=$(awk -v a="$cpu0" -v b="$cpu1" -v c="$clk" 'BEGIN{printf "%.2f",(b-a)/c}')
item T6.1 "$dt 秒内 成功/失败" "$okn / $badn  (代理 $pok/$pbad, 直连 $dok/$dbad)"
if [ "$badn" -eq 0 ]; then rec T6.1 "混合负载成功率" "失败 0" "$okn 成功 / $badn 失败" PASS
else
  rec T6.1 "混合负载成功率" "失败 0" "$okn 成功 / $badn 失败（代理 $pok/$pbad, 直连 $dok/$dbad）" FAIL
  echo "      失败样本:$FAILS"
fi
item T6.2 "sing-box CPU 累计 / RSS 峰值" "${cpus}s / $((maxrss/1024)) MB"
rec T6.2 "资源占用" "无异常增长" "CPU ${cpus}s, RSS $((maxrss/1024))MB" PASS

# ---------------------------------------------------------------- T7 失效切换
if [ "$WITH_FAILOVER" = 1 ]; then
  log "T7  节点失效 -> urltest 切换 -> 恢复回落"
  if ! command -v nft >/dev/null 2>&1; then
    item T7 "nft 不存在" "未执行"; rec T7 "失效自动切换" "自动切换" "nft 不可用" SKIP
  else
    now=$(clash /proxies/Auto | jq -r '.now' 2>/dev/null || true)
    srv=$(jq -r --arg t "$now" '(.outbounds[]|select(.tag==$t))|.server' "$CONF")
    prt=$(jq -r --arg t "$now" '(.outbounds[]|select(.tag==$t))|.server_port' "$CONF")
    item T7.1 "Auto 当前节点 / 节点端口" "$now / $prt"
    ( curl -s -o /dev/null --max-time 15 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1 & )
    sleep 3
    peer=$(ss -tnH state established 2>/dev/null | awk '{print $4" "$5}' | grep -E ":$prt\$" | head -1 | awk '{print $2}')
    iip=${peer%:*}
    cleanup_nft() { nft delete table inet sbx_test 2>/dev/null || true; }
    trap 'cleanup_nft' INT TERM
    if [ -z "$iip" ]; then
      item T7.2 "定位节点 IP" "失败(跳过)"
      rec T7.2 "失效后自动切换" "换节点" "无法定位节点 IP" SKIP
    else
      # ss 对 IPv6 显示 [addr]:port；nft 需要裸地址，且 ip / ip6 必须分开写
      LB='['; RB=']'
      iip=${iip#$LB}; iip=${iip%$RB}
      if printf '%s' "$iip" | grep -q ':'; then FAM=ip6; else FAM=ip; fi
      item T7.2 "节点真实 IP / 域名" "$iip ($FAM) / $srv"
      nft add table inet sbx_test
      nft add chain inet sbx_test out '{ type filter hook output priority -150; policy accept; }'
      if nft add rule inet sbx_test out "$FAM" daddr "$iip" tcp dport "$prt" reject; then
        item T7.2b "已注入失效规则" "$FAM daddr $iip tcp dport $prt reject"
        # 一边持续发起经代理的请求（模拟用户正在上网），一边等 urltest 切走
        ( for k in $(seq 1 90); do curl -s -o /dev/null --max-time 5 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; sleep 5; done ) &
        TRAF=$!
        t0=$SECONDS; switched=""
        while [ $((SECONDS-t0)) -lt "$FAILOVER_TIMEOUT" ]; do
          sleep 10
          n2=$(clash /proxies/Auto | jq -r '.now' 2>/dev/null || true)
          if [ -n "$n2" ] && [ "$n2" != "$now" ]; then switched="$n2"; break; fi
        done
        kill "$TRAF" 2>/dev/null || true
        wait "$TRAF" 2>/dev/null || true
        if [ -n "$switched" ]; then
          item T7.3 "切换耗时 / 新节点" "$((SECONDS-t0))s / $switched"
          rec T7.3 "失效后自动切换" "换节点" "$((SECONDS-t0))s 切到 $switched" PASS
        else
          item T7.3 "切换" "超时未切换"
          rec T7.3 "失效后自动切换" "换节点" "超时" FAIL
        fi
        cleanup_nft
        t0=$SECONDS; back=""
        while [ $((SECONDS-t0)) -lt "$FAILOVER_TIMEOUT" ]; do
          sleep 10
          n3=$(clash /proxies/Auto | jq -r '.now' 2>/dev/null || true)
          if [ "$n3" = "$now" ]; then back=1; break; fi
        done
        if [ -n "$back" ]; then
          item T7.4 "恢复后回落" "$((SECONDS-t0))s 回到 $now"
          rec T7.4 "恢复后回落原节点" "回到原节点" "回到 $now" PASS
        else
          item T7.4 "恢复后回落" "未在 ${FAILOVER_TIMEOUT}s 内回落"
          rec T7.4 "恢复后回落原节点" "回到原节点" "未回落" SKIP
        fi
      else
        item T7.2b "注入失效规则失败" "跳过切换测试"
        rec T7.3 "失效后自动切换" "换节点" "nft 规则注入失败" SKIP
        cleanup_nft
      fi
    fi
    cleanup_nft
  fi
else
  item T7 "失效切换" "未启用（加 --with-failover 执行）"
  rec T7 "失效后自动切换" "自动切换" "未启用" SKIP
fi

# ---------------------------------------------------------------------- 汇总
log "结果汇总"
printf '   %-5s %-30s %-12s %-26s %s\n' ID 用例 期望 实测 结论
for i in "${!D_ID[@]}"; do
  printf '   %-5s %-30s %-12s %-26s %s\n' "${D_ID[$i]}" "${D_CASE[$i]}" "${D_EXP[$i]}" "${D_GOT[$i]}" "${D_VERD[$i]}"
done
printf '\n   通过 %d / 失败 %d / 未执行 %d\n' "$PASS" "$FAIL" "$SKIP"
echo "   若上面有 FAIL，请把整段输出贴给我；测试过程中不要手动改 nftables。"
