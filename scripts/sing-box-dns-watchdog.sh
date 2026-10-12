#!/usr/bin/env bash
# sing-box DNS 看门狗：识别并自愈「缓存里落了一条错误的否定应答」这一类故障。
#
# 为什么需要它（2026-10-12 实测）：eBPF 入站的 `dns_mode: hijack` 把所有 UDP/53
# 查询截到 sing-box 自己的 DNS 缓存，而 `experimental.cache_file.store_dns = true`
# 把这份缓存落了盘（/var/lib/sing-box/cache.db）。一旦里面存下一条**错误的
# NODATA**，命中它的查询就会「0 条答案、0 ms」返回，带 EDNS0 的查询因为缓存键
# 不同会绕过它 —— 于是症状是「某些网站打不开、别的都正常」，而且**重启不消失**
# （缓存落了盘）。当时表现为 Firefox 打不开 emoe.eu.cc，但 dig @8.8.8.8 /
# @1.1.1.1 / @不可路由地址 全都被本机接管、四种结果一模一样，正是这个原因。
#
# 判据：拿 DoH 的**真实答案**当基准，跟本机解析结果比。DoH 走 HTTPS、并用
# `--resolve` 直接连 IP，既不经过 53 劫持、也不依赖域名解析，所以是一个独立的
# 事实来源。只有「DoH 说这个域名有 A 记录、而本机说没有」才算故障。
# **拿不到 DoH 基准时一律判为「无法判断」，绝不动手** —— 网络本身坏了不该被
# 当成缓存故障来处理。
#
# 用法：
#   ./sing-box-dns-watchdog.sh --check      # 只探测、只打印（不需要 root）
#   sudo ./sing-box-dns-watchdog.sh --heal  # 探测 + 二次确认 + 自愈（systemd 跑这个）
#   ./sing-box-dns-watchdog.sh --self-test  # 用合成输入跑判据，不联网（免 root）
#
# 自愈动作**只动缓存、不碰配置**：stop sing-box → 删 cache.db → start
#   → resolvectl flush-caches → 复测。修不好就以非 0 退出，让 systemctl --failed 能看见。
#
# 可调项放 /etc/sing-box/dns-watchdog.conf（可选，被 source）：
#   WATCH_DOMAINS="emoe.eu.cc www.baidu.com github.com"
#   HEAL_COOLDOWN=900   RECHECK_DELAY=3   DOH_TIMEOUT=8
set -Eeuo pipefail

# dig 的输出要按固定文本解析，本地化标签会让匹配悄悄变成空操作。
export LC_ALL=C

config_file="${SING_BOX_DNS_WATCHDOG_CONFIG:-/etc/sing-box/dns-watchdog.conf}"
if [[ -r "$config_file" ]]; then
    # shellcheck source=/dev/null
    source "$config_file"
fi

# 三个域名覆盖两条 DNS 路径：emoe.eu.cc / github.com 走 dns-proxy（代理侧 DoH），
# www.baidu.com 走 dns-direct（国内 DoH）。国内域名被墙外解析污染、或反向的情况
# 都能被这组覆盖到。
WATCH_DOMAINS="${WATCH_DOMAINS:-emoe.eu.cc www.baidu.com github.com}"
DOH_TIMEOUT="${DOH_TIMEOUT:-8}"
RECHECK_DELAY="${RECHECK_DELAY:-3}"
HEAL_COOLDOWN="${HEAL_COOLDOWN:-900}"
STATE_FILE="${STATE_FILE:-/var/lib/sing-box/dns-watchdog.state}"
CACHE_DB="${CACHE_DB:-/var/lib/sing-box/cache.db}"
SERVICE="${SERVICE:-sing-box}"
LOCK_FILE="${LOCK_FILE:-/run/sing-box-dns-watchdog.lock}"

mode="check"

log() { printf '[dns-watchdog] %s\n' "$*"; }

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}"; }

while (( $# > 0 )); do
    case "$1" in
        --check) mode="check" ;;
        --heal) mode="heal" ;;
        --self-test) mode="self-test" ;;
        --help | -h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# 本机解析结果里的 A 记录条数。<domain> [额外的 dig 参数...]
#
# 走默认解析器（systemd-resolved）＝ 浏览器看到的那个结果；显式加 +noedns 再问一次
# ＝ 原始事故里命中坏缓存的那条路径。两条都要看：事故当时正是不带 EDNS0 才拿到 0 条。
resolve_count() {
    local domain="$1"
    shift
    dig +time=3 +tries=1 +short "$@" A "$domain" 2>/dev/null |
        grep -cE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
}

# DoH 上这个域名的 A 记录条数。拿不到基准时返回 1（调用方必须当成「无法判断」）。
doh_count() {
    local domain="$1" body=""
    body="$(curl -sS --max-time "$DOH_TIMEOUT" \
        --resolve 'cloudflare-dns.com:443:1.1.1.1' \
        "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H 'accept: application/dns-json' 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
        body="$(curl -sS --max-time "$DOH_TIMEOUT" \
            --resolve 'dns.google:443:8.8.8.8' \
            "https://dns.google/resolve?name=${domain}&type=A" \
            -H 'accept: application/dns-json' 2>/dev/null || true)"
    fi
    [[ -n "$body" ]] || return 1
    printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
print(sum(1 for answer in (data.get("Answer") or []) if answer.get("type") == 1))
' || return 1
}

# 判据本体：<DoH 条数> <本机条数> <无 EDNS0 条数> -> ok|fault
wd_verdict() {
    local truth="$1" local_count="$2" noedns_count="$3"
    # DoH 也没有 A 记录：这个域名本来就不该解析出来，本机给 0 条是对的。
    if (( truth == 0 )); then
        printf 'ok\n'
        return 0
    fi
    if (( local_count == 0 || noedns_count == 0 )); then
        printf 'fault\n'
        return 0
    fi
    printf 'ok\n'
}

state_last_heal() {
    [[ -r "$STATE_FILE" ]] || {
        printf '0\n'
        return 0
    }
    local value
    value="$(sed -n 's/^last_heal=//p' "$STATE_FILE" | head -n1)"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

state_write_heal() {
    mkdir -p -- "$(dirname -- "$STATE_FILE")"
    printf 'last_heal=%s\n' "$1" >"$STATE_FILE"
}

self_test() {
    local failures=0 expect truth local_count noedns_count got
    run_case() {
        expect="$1" truth="$2" local_count="$3" noedns_count="$4"
        got="$(wd_verdict "$truth" "$local_count" "$noedns_count")"
        if [[ "$got" == "$expect" ]]; then
            printf 'ok   DoH=%s 本机=%s 无EDNS0=%s -> %s\n' \
                "$truth" "$local_count" "$noedns_count" "$got"
        else
            printf 'FAIL DoH=%s 本机=%s 无EDNS0=%s -> %s（期望 %s）\n' \
                "$truth" "$local_count" "$noedns_count" "$got" "$expect"
            failures=$(( failures + 1 ))
        fi
    }
    # 2026-10-12 事故的真实签名：DoH 2 条，本机两种问法都 0 条。
    run_case fault 2 0 0
    # 原始事故更微妙的一档：带 EDNS0 能过、不带就 0 条（缓存键不同）。
    run_case fault 2 2 0
    run_case fault 2 0 2
    # 健康：三边一致。
    run_case ok 2 2 2
    run_case ok 1 1 1
    # 域名本来就没有 A 记录（或被广告规则 NXDOMAIN 掉）：本机 0 条不算故障。
    run_case ok 0 0 0
    if (( failures > 0 )); then
        log "self-test: $failures 个用例失败"
        exit 1
    fi
    log 'self-test: 全部通过'
}

if [[ "$mode" == "self-test" ]]; then
    self_test
    exit 0
fi

for tool in dig curl python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        log "缺少 $tool，无法探测"
        exit 2
    }
done

if [[ "$mode" == "heal" ]]; then
    # 单实例：定时器和手跑撞在一起时，让后来者直接退出而不是并发删缓存。
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        log '已有实例在运行，跳过本轮'
        exit 0
    }
fi

faults=()
inconclusive=0
for domain in $WATCH_DOMAINS; do
    local_count="$(resolve_count "$domain")"
    noedns_count="$(resolve_count "$domain" '+noedns')"
    if ! truth="$(doh_count "$domain")"; then
        inconclusive=$(( inconclusive + 1 ))
        log "$domain: 无法判断（DoH 基准拿不到；本机 $local_count 条）"
        continue
    fi
    verdict="$(wd_verdict "$truth" "$local_count" "$noedns_count")"
    log "$domain: DoH $truth 条 / 本机 $local_count 条 / 无EDNS0 $noedns_count 条 → $verdict"
    if [[ "$verdict" == "fault" ]]; then
        faults+=("$domain")
    fi
done

if (( ${#faults[@]} == 0 )); then
    log "解析正常${inconclusive:+（$inconclusive 个域名无法判断）}"
    exit 0
fi

log "可疑：${faults[*]}"

if [[ "$mode" == "check" ]]; then
    log '--check 模式不做任何改动；确认后请用 sudo 跑 --heal'
    exit 1
fi

# 二次确认：坏缓存是持续性的，隔几秒再问一次仍然 0 条才算数，
# 免得把上游抖动那一下当成缓存故障（那就白白重启一次代理）。
confirmed=()
for domain in "${faults[@]}"; do
    sleep "$RECHECK_DELAY"
    if (( "$(resolve_count "$domain")" == 0 )); then
        confirmed+=("$domain")
    else
        log "$domain: 复测已恢复，判为抖动，不动手"
    fi
done

if (( ${#confirmed[@]} == 0 )); then
    log '二次确认后没有确认的故障'
    exit 0
fi

if ! systemctl is-active --quiet "$SERVICE"; then
    # 服务都没在跑，"清缓存"不是它的问题（此时 53 劫持也不存在，探测结果本身可疑）。
    log "$SERVICE 未在运行；这不是缓存故障，交给别的排查手段"
    exit 0
fi

now="$(date +%s)"
last="$(state_last_heal)"
if (( last > 0 && now - last < HEAL_COOLDOWN )); then
    log "距上次自愈 $(( now - last ))s，仍在冷却期（${HEAL_COOLDOWN}s）内；本轮不动手"
    exit 0
fi

if (( EUID != 0 )); then
    log '自愈需要 root：请用 sudo，或让 systemd unit 来跑'
    exit 2
fi

log "确认故障：${confirmed[*]}；开始自愈"
state_write_heal "$now"

systemctl stop "$SERVICE"
removed=no
if [[ -e "$CACHE_DB" ]]; then
    rm -f -- "$CACHE_DB"
    removed=yes
fi
systemctl start "$SERVICE"
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
fi
sleep 2

still_broken=()
for domain in "${confirmed[@]}"; do
    if (( "$(resolve_count "$domain")" == 0 )); then
        still_broken+=("$domain")
    fi
done

if (( ${#still_broken[@]} == 0 )); then
    log "自愈成功（删除 cache.db: $removed）"
    exit 0
fi

log "自愈后仍解析不出来：${still_broken[*]} —— 这不是缓存问题，需要人工看 sing-box 日志"
exit 1
