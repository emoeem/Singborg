#!/usr/bin/env bash
# sing-box-burst-probe.sh —— 抓住 `connection upload handshake: dial tcp <IP>:<PORT>: i/o timeout`
# 的下一次突发，并在**当时**对同一端点做 A/B：裸 TCP connect  vs  TCP-Fast-Open connect(MSG_FASTOPEN)。
#
# 为什么需要它：sing-box 的 `tcp_fast_open: true` 让拨号变成 tfo-go 的 slowOpenConn ——
# **TCP 连接本身被推迟到首次 write**（见 common/dialer/tfo.go）。所以：
#   - 日志里的 `dial tcp ...: i/o timeout` 是「首次 write 时才发生的 connect 超时」，5.0s = constant.TCPConnectTimeout；
#   - 事后用裸 connect 测「✅ 可连」**不能**反驳它，因为二者不是同一个 syscall（connect vs sendto(MSG_FASTOPEN)）。
# 只有在突发发生的那一刻同时测两条路径，才能区分「中转入口丢了 SYN」还是「TFO 路径被中间盒吃了」。
#
# 只读：不 sudo、不改配置、不重启。journal 对当前用户可读（实测 rc=0）。
# 用法：
#   scripts/sing-box-burst-probe.sh                 # 守着 journal，突发即测
#   scripts/sing-box-burst-probe.sh once 1.2.3.4 80 # 立刻单测一个端点
set -uo pipefail

LOG=${PROBE_LOG:-$HOME/.local/state/sing-box-burst-probe.log}
COOLDOWN=${PROBE_COOLDOWN:-20}   # 同一端点重复测量间隔（秒）

probe() { # $1=ip $2=port
  python3 - "$1" "$2" <<'PY'
import errno, select, socket, sys, time

MSG_FASTOPEN = getattr(socket, "MSG_FASTOPEN", 0x20000000)   # Linux = 536870912
PAYLOAD = b"\x00" * 8                                        # 模拟 SS 首包（TFO 会把它塞进 SYN）

def plain(ip, port, t=5.0):
    t0 = time.perf_counter()
    try:
        c = socket.create_connection((ip, port), timeout=t)
        c.close()
        return round((time.perf_counter() - t0) * 1000), "OK"
    except Exception as e:
        return round((time.perf_counter() - t0) * 1000), type(e).__name__

def tfo(ip, port, t=5.0):
    """真正的 TFO 连接：sendto(MSG_FASTOPEN) 把首包塞进 SYN。
    非阻塞 socket 上 EINPROGRESS(=BlockingIOError) 是**正常**状态，代表连接进行中。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)   # 必须在 sendto 之前：否则这里就阻塞了，且没有超时控制
    t0 = time.perf_counter()
    try:
        s.sendto(PAYLOAD, MSG_FASTOPEN, (ip, port))
    except BlockingIOError:
        pass                                     # EINPROGRESS：SYN(+data) 已发出
    except OSError as e:
        s.close()
        return round((time.perf_counter() - t0) * 1000), errno.errorcode.get(e.errno, str(e))
    _, w, x = select.select([], [s], [s], t)
    dt = round((time.perf_counter() - t0) * 1000)
    if x:
        s.close(); return dt, "EXC"
    if not w:
        s.close(); return dt, "TIMEOUT"
    err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
    s.close()
    return dt, ("OK" if err == 0 else errno.errorcode.get(err, str(err)))

ip, port = sys.argv[1], int(sys.argv[2])
pm, pr = plain(ip, port)
tm, tr = tfo(ip, port)
print(f"{pm}\t{pr}\t{tm}\t{tr}")
PY
}

if [ "${1:-watch}" = "once" ]; then
  [ $# -eq 3 ] || { echo "用法: $0 once <ip> <port>" >&2; exit 2; }
  printf 'plain_ms\tplain\ttfo_ms\ttfo\n'; probe "$2" "$3"; exit $?
fi

mkdir -p "$(dirname "$LOG")"
echo "== 守着 journalctl -u sing-box；突发端点立即 A/B 测量；记录 → $LOG"
echo "== 列格式: probe_time  endpoint  plain_ms plain_result  tfo_ms tfo_result   (Ctrl-C 结束)"
[ -s "$LOG" ] || printf 'probe_time\tendpoint\tplain_ms\tplain\ttfo_ms\ttfo\n' >>"$LOG"

# 下标是 "ip:port"，含 . 和 :，必须显式声明成关联数组，否则 bash 会把它当算术表达式求值
declare -A seen=()

probe_stream() {   # 从 stdin 读日志行（journalctl -f 或文件，后者便于自测）
  while IFS= read -r line; do
    ep=$(printf '%s' "$line" \
      | sed -nE 's/.*connection upload handshake: dial tcp ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+): .*/\1/p')
    [ -n "$ep" ] || continue
    now=$(date +%s)
    if [ -n "${seen["$ep"]:-}" ] && [ $(( now - ${seen["$ep"]} )) -lt "$COOLDOWN" ]; then
      continue
    fi
    seen["$ep"]=$now
    ip=${ep%:*}; port=${ep#*:}
    res=$(probe "$ip" "$port")
    # 裸 connect 成功 + TFO 超时 ⇒ TFO/中间盒问题；两者都失败 ⇒ 路径/中转入口问题
    verdict="?"
    case "$res" in
      *"	OK	"*"	TIMEOUT") verdict="TFO-only-fail(疑似中间盒吃 SYN+data)";;
      *"	Timeout	"*"	TIMEOUT") verdict="both-fail(路径/中转入口丢包)";;
      *"	OK	"*) verdict="both-ok(突发已过,需立刻复测)";;
    esac
    printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$ep" "$res" "$verdict" | tee -a "$LOG"
  done
}

# PROBE_SOURCE=<文件> 时从文件读（自测用，不碰 journal）
if [ -n "${PROBE_SOURCE:-}" ]; then
  probe_stream <"$PROBE_SOURCE"
else
  journalctl -u sing-box -f -o cat --no-pager 2>/dev/null | probe_stream
fi
