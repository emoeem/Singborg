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
# 判据一（缓存故障）：拿 DoH 的**真实答案**当基准，跟本机解析结果比。DoH 走
# HTTPS、并用 `--resolve` 直接连 IP，既不经过 53 劫持、也不依赖域名解析，所以是
# 一个独立的事实来源。只有「DoH 说这个域名有 A 记录、而本机说没有」才算故障。
# **拿不到 DoH 基准时一律判为「无法判断」，绝不动手** —— 网络本身坏了不该被
# 当成缓存故障来处理。
#
# 判据二（服务存活）：sing-box 自己死了也要能发现。**这条判据是必须的**，因为本机
# 出网走的是它的 eBPF 透明代理（`ip route` 里没有 tun 设备，流量由 eBPF 钩子改道），
# 它一停，连判据一要用的 DoH 基准（1.1.1.1 / 8.8.8.8 的 443）都不可达 ——
# 2026-10-12 受控演练实测：`systemctl stop sing-box` 之后三个域名全部变成
# 「无法判断」，判据一**永远发现不了「代理挂了」**。所以这里另用一条完全不依赖
# 网络的判据：unit 是 enabled（管理员要求它开机就跑）却不 active → 直接 start 它。
# 想长期停用就 `systemctl disable --now sing-box`：disabled 的 unit 看门狗不碰。
#
# 用法：
#   ./sing-box-dns-watchdog.sh --check      # 只探测、只打印（不需要 root）
#   sudo ./sing-box-dns-watchdog.sh --heal  # 探测 + 二次确认 + 自愈（systemd 跑这个）
#   ./sing-box-dns-watchdog.sh --self-test  # 用合成输入跑两条判据，不联网（免 root）
#
# 自愈动作**只动缓存、不碰配置**：stop sing-box → 删 cache.db → start
#   → resolvectl flush-caches → 复测。修不好就以非 0 退出，让 systemctl --failed 能看见。
# 存活自愈只做 `systemctl start`，不删缓存、不碰配置。
#
# 可调项放 /etc/sing-box/dns-watchdog.conf（可选，被 source）：
#   WATCH_DOMAINS="emoe.eu.cc www.baidu.com github.com"
#   WATCH_SERVICE_LIVENESS=yes   # 置 no 可关掉存活自愈
#   HEAL_COOLDOWN=900   START_COOLDOWN=300   RECHECK_DELAY=3   DOH_TIMEOUT=8
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
# 存活自愈的冷却期短得多：start 一个服务不打断任何流量，而且「代理挂了」是断网，
# 值得下一个周期（timer 每 5 分钟）就再试。
START_COOLDOWN="${START_COOLDOWN:-300}"
WATCH_SERVICE_LIVENESS="${WATCH_SERVICE_LIVENESS:-yes}"
STATE_FILE="${STATE_FILE:-/var/lib/sing-box/dns-watchdog.state}"
CACHE_DB="${CACHE_DB:-/var/lib/sing-box/cache.db}"
SERVICE="${SERVICE:-sing-box}"
# 允许把 systemd 调用指向别的实例（自测用：SYSTEMCTL='systemctl --user'）。
read -r -a SYSTEMCTL_CMD <<<"${SYSTEMCTL:-systemctl}"
(( ${#SYSTEMCTL_CMD[@]} > 0 )) || SYSTEMCTL_CMD=(systemctl)
# 锁必须落在**本进程可写**的目录里。unit 里的 ProtectSystem=strict 会把整个层次
# 挂成只读 —— 连 /run 本身也不例外，唯一例外是 RuntimeDirectory= 声明的那一个目录。
# 2026-10-12 首次装机正是死在这里：
#   line 180: /run/sing-box-dns-watchdog.lock: Read-only file system
# systemd 会把这个目录的路径放进 $RUNTIME_DIRECTORY；手跑（sudo）时该变量为空，
# 退回 /run，行为与修复前一致。
LOCK_FILE="${LOCK_FILE:-${RUNTIME_DIRECTORY:-/run}/sing-box-dns-watchdog.lock}"

mode="check"

log() { printf '[dns-watchdog] %s\n' "$*"; }

# 打印文件头部的注释块：从第 2 行到 `set -Eeuo pipefail` 之前。改注释不必同步改行号。
usage() { sed -n '2,/^set -Eeuo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; }

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

state_read() {
    local key="$1" value=""
    [[ -r "$STATE_FILE" ]] && value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1)"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

state_write() {
    local key="$1" value="$2" tmp
    mkdir -p -- "$(dirname -- "$STATE_FILE")"
    tmp="$(mktemp -- "${STATE_FILE}.XXXXXX")"
    {
        [[ -r "$STATE_FILE" ]] && grep -v "^${key}=" "$STATE_FILE" || true
        printf '%s=%s\n' "$key" "$value"
    } >"$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

state_last_heal() { state_read last_heal; }
state_write_heal() { state_write last_heal "$1"; }
state_last_start() { state_read last_start; }
state_write_start() { state_write last_start "$1"; }

# --- 判据二：服务存活（见文件头）。本机出网走 sing-box 的 eBPF 透明代理，它一停，
# 连 DoH 基准都不可达，判据一只会得到「无法判断」——所以这条判据必须独立于网络。
service_active_state() {
    "${SYSTEMCTL_CMD[@]}" show -p ActiveState --value "$SERVICE" 2>/dev/null || printf 'unknown\n'
}

service_unit_state() {
    "${SYSTEMCTL_CMD[@]}" show -p UnitFileState --value "$SERVICE" 2>/dev/null || printf 'unknown\n'
}

# 纯函数（便于自测）：<ActiveState> <UnitFileState> -> alive|dead|intentional
#   alive       在跑、或正在状态迁移中（systemd 自带的 Restart= 在处理）——不插手
#   dead        unit 是 enabled（管理员要求它开机就跑）却没在跑 —— 该 start
#   intentional 没在跑、也没被 enable（用户有意停用）—— 不碰
wd_liveness_verdict() {
    local active="$1" unit="$2"
    case "$active" in
        active | reloading | activating | deactivating)
            printf 'alive\n'
            return 0
            ;;
    esac
    case "$unit" in
        enabled | enabled-runtime)
            printf 'dead\n'
            return 0
            ;;
    esac
    printf 'intentional\n'
}

liveness_verdict_now() {
    if [[ "$WATCH_SERVICE_LIVENESS" != "yes" ]]; then
        printf 'alive\n'
        return 0
    fi
    wd_liveness_verdict "$(service_active_state)" "$(service_unit_state)"
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
    # 判据二的合成用例。
    run_live() {
        local expect="$1" active="$2" unit="$3" got
        got="$(wd_liveness_verdict "$active" "$unit")"
        if [[ "$got" == "$expect" ]]; then
            printf 'ok   存活 ActiveState=%s UnitFileState=%s -> %s\n' "$active" "$unit" "$got"
        else
            printf 'FAIL 存活 ActiveState=%s UnitFileState=%s -> %s（期望 %s）\n' \
                "$active" "$unit" "$got" "$expect"
            failures=$(( failures + 1 ))
        fi
    }
    # 2026-10-12 受控演练的真实签名：stop sing-box 之后 DoH 基准一起不可达。
    run_live dead inactive enabled
    run_live dead failed enabled
    # 正在跑、或 systemd 自己在拉它（Restart=），都不该插手。
    run_live alive active enabled
    run_live alive activating enabled
    # 用户有意停用（disabled / masked）：不碰。
    run_live intentional inactive disabled
    run_live intentional failed masked

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

    # 存活自愈放在最前面：它不依赖网络（只用 systemctl），而且 sing-box 一死，
    # 下面那套 DoH 基准也一起不可达，探测只会得到「无法判断」。
    if [[ "$(liveness_verdict_now)" == "dead" ]]; then
        active_state="$(service_active_state)"
        unit_state="$(service_unit_state)"
        log "$SERVICE 处于 $unit_state 却不活动（ActiveState=$active_state）→ 尝试启动"
        if (( EUID != 0 )); then
            log '启动服务需要 root：请用 sudo，或让 systemd unit 来跑'
            exit 2
        fi
        now="$(date +%s)"
        last="$(state_last_start)"
        if (( last > 0 && now - last < START_COOLDOWN )); then
            log "距上次存活自愈 $(( now - last ))s，仍在冷却期（${START_COOLDOWN}s）内；本轮不重启"
            exit 1
        fi
        state_write_start "$now"
        "${SYSTEMCTL_CMD[@]}" start "$SERVICE" || true
        sleep 2
        if "${SYSTEMCTL_CMD[@]}" is-active --quiet "$SERVICE"; then
            log "存活自愈成功：$SERVICE 已启动（继续做 DNS 判据）"
        else
            log "存活自愈失败：$SERVICE 起不来 —— 看 journalctl -u $SERVICE（多半是配置或端口问题）"
            exit 1
        fi
    fi
fi

faults=()
inconclusive=0
total=0
for domain in $WATCH_DOMAINS; do
    total=$(( total + 1 ))
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

# 存活状态在这里求值：它可能正是"DoH 基准拿不到"的原因，所以必须在任何 exit 之前看一眼。
live="$(liveness_verdict_now)"

if (( ${#faults[@]} == 0 )); then
    if [[ "$live" == "dead" ]]; then
        log "$SERVICE 处于 $(service_unit_state) 却不活动（ActiveState=$(service_active_state)）—— 这很可能就是上面拿不到 DoH 基准的原因"
        if [[ "$mode" == "check" ]]; then
            log '--check 模式不做任何改动；确认后请用 sudo 跑 --heal'
        fi
        exit 1
    fi
    if (( inconclusive == 0 )); then
        log '解析正常'
    elif (( inconclusive >= total )); then
        # 全部无法判断：DoH 基准完全不可达。不做任何改动（可能只是整条网络坏了），
        # 但也不再假称"解析正常" —— 2026-10-12 演练当时打印的正是这句误导性的话。
        log "全部无法判断：$inconclusive 个域名的 DoH 基准都拿不到；按设计不动手"
    else
        log "解析正常（$inconclusive 个域名无法判断）"
    fi
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

if ! "${SYSTEMCTL_CMD[@]}" is-active --quiet "$SERVICE"; then
    # 走到这里说明：有确认过的解析故障，但服务没在跑。存活自愈要么被关掉了
    # （WATCH_SERVICE_LIVENESS=no），要么它刚刚已经试过并且失败 —— 无论哪种，
    # "删缓存"都不是现在该做的事。
    log "$SERVICE 未在运行；这不是缓存故障（存活自愈已关闭或刚刚失败）"
    exit 1
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

"${SYSTEMCTL_CMD[@]}" stop "$SERVICE"
removed=no
if [[ -e "$CACHE_DB" ]]; then
    rm -f -- "$CACHE_DB"
    removed=yes
fi
"${SYSTEMCTL_CMD[@]}" start "$SERVICE"
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
