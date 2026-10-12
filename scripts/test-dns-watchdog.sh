#!/usr/bin/env bash
# 钉子：看门狗 unit 的沙箱放行范围，必须覆盖脚本会写的每一个路径。
#
# 为什么需要它（2026-10-12 真实故障）：unit 里的 ProtectSystem=strict 把整个文件
# 层次挂成只读，**连 /run 本身也不例外**，而脚本的 flock 锁当时写死在
# /run/sing-box-dns-watchdog.lock。装到系统上第一次运行就失败：
#   sing-box-dns-watchdog[...]: line 180: /run/sing-box-dns-watchdog.lock:
#   Read-only file system
# 这类错误"静态审查看不出、只有真跑才炸"，所以这里做四层：
#   1) 静态核对：unit 声明 strict 时，脚本的 LOCK_FILE/STATE_FILE/CACHE_DB 默认值
#      必须落在 ReadWritePaths= 或 RuntimeDirectory= 之下；
#   2) 反向真沙箱探针：用 systemd-run --user 起一个同样 ProtectSystem=strict 的临时
#      unit，证明"写到 /run 顶层会被拒"这条测试本身有效；
#   3) 正向真沙箱探针：在同一个沙箱里用 RuntimeDirectory 建锁，必须成功；
#   4) 存活判据接线：把 SYSTEMCTL 指到 user 实例上的临时 unit，离线（WATCH_DOMAINS=' '
#      让探测循环跑 0 个域名）验证"enabled 却不 active → 报错"这条接线真的通。
#
# 用法：./scripts/test-dns-watchdog.sh        （免 root；systemd-run 不可用时跳过真沙箱层）
set -Eeuo pipefail

export LC_ALL=C

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname -- "$here")"
script="$here/sing-box-dns-watchdog.sh"
unit="$repo/systemd/sing-box-dns-watchdog.service"

pass=0
fail=0
skipped=0
ok() { printf 'ok    %s\n' "$*"; pass=$(( pass + 1 )); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$(( fail + 1 )); }
skip() { printf 'skip  %s\n' "$*"; skipped=$(( skipped + 1 )); }

if [[ ! -r "$script" || ! -r "$unit" ]]; then
    printf '找不到 %s 或 %s\n' "$script" "$unit" >&2
    exit 2
fi

# ---------------------------------------------------------------- 1) 静态核对
protect="$(sed -n 's/^ProtectSystem=//p' "$unit" | tail -n1)"
runtime="$(sed -n 's/^RuntimeDirectory=//p' "$unit" | tail -n1)"
mapfile -t rw < <(sed -n 's/^ReadWritePaths=//p' "$unit")

if [[ "$protect" != "strict" ]]; then
    skip "unit 未使用 ProtectSystem=strict（当前：${protect:-未设置}），无需核对放行路径"
else
    ok "unit 使用 ProtectSystem=strict（整个层次只读，含 /run）"

    # systemd 会把这些目录隐含加入可写集：RuntimeDirectory 是 /run/<name>，其余在此
    # 仅供提示，不参与下面的判断（脚本不写它们）。
    writable=("${rw[@]}")
    [[ -n "$runtime" ]] && writable+=("/run/$runtime")

    if [[ -z "$runtime" ]]; then
        bad "unit 没有 RuntimeDirectory=，而脚本的锁默认落在 /run 下 —— 沙箱会拒绝（这正是 2026-10-12 的故障）"
    fi

    # 按 systemd 的方式求值脚本里的默认路径：RUNTIME_DIRECTORY 由 unit 的
    # RuntimeDirectory= 决定。手跑（sudo）时该变量为空，会退回 /run —— 那条路径
    # 不在沙箱里，所以必须靠 RuntimeDirectory 撑住。
    paths="$(RUNTIME_DIRECTORY="${runtime:+/run/$runtime}" bash -c '
        set -Eeuo pipefail
        eval "$(grep -E "^(LOCK_FILE|STATE_FILE|CACHE_DB)=" "$1")"
        printf "%s\n%s\n%s\n" "$LOCK_FILE" "$STATE_FILE" "$CACHE_DB"
    ' _ "$script")"

    covered() {
        local p="$1" root
        for root in "${writable[@]}"; do
            [[ "$p" == "$root" || "$p" == "$root"/* ]] && return 0
        done
        return 1
    }

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if covered "$path"; then
            ok "沙箱放行了 $path"
        else
            bad "沙箱没放行 $path（可写集：${writable[*]}）"
        fi
    done <<<"$paths"
fi

# ------------------------------------------------------------ 2) 真沙箱探针
sandbox_ready=no
if command -v systemd-run >/dev/null 2>&1 &&
    systemd-run --user --wait --pipe -q true >/dev/null 2>&1; then
    sandbox_ready=yes
fi

if [[ "$sandbox_ready" != "yes" ]]; then
    skip "systemd-run --user 不可用，跳过真沙箱探针（静态核对仍然有效）"
else
    # 反向对照：同一沙箱里写 /run 顶层**必须**被拒。如果这条通过了，说明下面那条
    # 正向探针真的在测沙箱，而不是在测"碰巧能写"。
    negative="$(systemd-run --user --wait --pipe -q -p ProtectSystem=strict \
        bash -c 'flock -n /run/dns-watchdog-negative.lock true && echo LOCK-OK' 2>&1 || true)"
    if grep -q 'Read-only file system' <<<"$negative"; then
        ok "反向对照：ProtectSystem=strict 下写 /run 顶层被拒（本测试有效）"
    else
        bad "反向对照失效：写 /run 顶层居然没被拒（输出：$negative）—— 正向探针失去意义"
    fi

    # 正向：用 RuntimeDirectory 定位锁，必须成功。这条就是修复后的真实路径。
    # 内层必须用单引号：$RUNTIME_DIRECTORY 要留给沙箱里那个 bash 展开。
    # shellcheck disable=SC2016
    positive="$(systemd-run --user --wait --pipe -q -p ProtectSystem=strict \
        -p RuntimeDirectory=dns-watchdog-test \
        bash -c 'flock -n "$RUNTIME_DIRECTORY/probe.lock" true && echo LOCK-OK' 2>&1 || true)"
    if grep -q 'LOCK-OK' <<<"$positive"; then
        ok "正向对照：RuntimeDirectory 里的锁在沙箱内可创建（修复有效）"
    else
        bad "RuntimeDirectory 里的锁仍创建失败：$positive"
    fi
fi

# ---------------------------------------------------------------- 3) 判据自测
if "$script" --self-test >/dev/null 2>&1; then
    ok "判据自测（$( "$script" --self-test 2>&1 | grep -c '^ok ' ) 个合成用例）全部通过"
else
    bad "判据自测 --self-test 失败"
fi

# --------------------------------------------------- 4) 存活自愈判据（离线，免 root）
# 2026-10-12 受控演练暴露的缺口：`systemctl stop sing-box` 之后，连判据一要用的 DoH
# 基准也一起不可达（本机出网走它的 eBPF 透明代理），三个域名全部「无法判断」，
# 于是判据一永远发现不了「代理挂了」。这一层把 SYSTEMCTL 覆盖成 `systemctl --user`
# 并指向一个临时 unit，离线验证接线。

# 先静态钉住设计里最要命的一条顺序：存活自愈必须排在探测循环之前。
# 字面匹配（pattern 里的 $ 就是源码字符，不能展开）
# shellcheck disable=SC2016
live_call="$(grep -nF '"$(liveness_verdict_now)" == "dead"' "$script" | head -n1 | cut -d: -f1)"
# 字面匹配（pattern 里的 $ 就是源码字符，不能展开）
# shellcheck disable=SC2016
loop_line="$(grep -nF 'for domain in $WATCH_DOMAINS; do' "$script" | head -n1 | cut -d: -f1)"
if [[ -n "$live_call" && -n "$loop_line" ]] && (( live_call < loop_line )); then
    ok "存活自愈排在探测循环之前（第 $live_call 行 < 第 $loop_line 行）—— 断网时也能救回来"
else
    bad "存活自愈没有排在探测循环之前（live=${live_call:-未找到} loop=${loop_line:-未找到}）"
fi

# 字面匹配（pattern 里的 $ 就是源码字符，不能展开）
# shellcheck disable=SC2016
starts="$(grep -cF '${SYSTEMCTL_CMD[@]}" start "$SERVICE"' "$script" || true)"
if [[ "${starts:-0}" -ge 2 ]]; then
    ok "两处启动调用点都在（存活自愈 + 缓存自愈）：$starts 处"
else
    bad "启动调用点只有 ${starts:-0} 处（期望 2：存活自愈与缓存自愈各一处）"
fi

user_ready=no
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    user_ready=yes
fi

if [[ "$user_ready" != "yes" ]]; then
    skip "systemctl --user 不可用，跳过存活判据的接线测试（--self-test 里的合成用例仍然有效）"
else
    probe_unit="sing-box-watchdog-probe-liveness.service"
    probe_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    probe_path="$probe_dir/$probe_unit"
    probe_tmp="$(mktemp -d)"

    probe_cleanup() {
        systemctl --user stop "$probe_unit" >/dev/null 2>&1 || true
        systemctl --user disable "$probe_unit" >/dev/null 2>&1 || true
        rm -f -- "$probe_path"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$probe_tmp"
    }
    trap probe_cleanup EXIT

    mkdir -p -- "$probe_dir"
    cat >"$probe_path" <<'EOF'
[Unit]
Description=看门狗自测用的临时 unit（不 active / active 两种状态都要能造出来）

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$probe_unit" >/dev/null 2>&1

    pre_active="$(systemctl --user show -p ActiveState --value "$probe_unit")"
    pre_unit="$(systemctl --user show -p UnitFileState --value "$probe_unit")"
    if [[ "$pre_active" == "inactive" && "$pre_unit" == "enabled" ]]; then
        ok "前置条件成立：$probe_unit 是 enabled 却 inactive"
    else
        bad "前置条件不成立（ActiveState=$pre_active UnitFileState=$pre_unit），下面三条结论无效"
    fi

    # <期望退出码> <输出里必须出现的字符串> [额外的 VAR=value ...]
    run_probe() {
        local want_rc="$1" want_text="$2" out rc
        shift 2
        out="$(env SYSTEMCTL='systemctl --user' SERVICE="$probe_unit" \
            STATE_FILE="$probe_tmp/state" LOCK_FILE="$probe_tmp/lock" \
            CACHE_DB="$probe_tmp/cache.db" WATCH_DOMAINS=' ' \
            "$@" "$script" --check 2>&1)" && rc=0 || rc=$?
        if [[ "$rc" -eq "$want_rc" ]] && grep -qF -- "$want_text" <<<"$out"; then
            ok "存活判据接线：rc=$rc 且输出含「$want_text」"
        else
            bad "存活判据接线失败：rc=$rc（期望 $want_rc）／$want_text｜输出：$(tr '\n' '|' <<<"$out")"
        fi
    }

    # 主用例：enabled 却不 active —— 就是受控演练里那条路径。
    run_probe 1 '却不活动' WATCH_SERVICE_LIVENESS=yes
    # 开关：关掉存活判据后，同一个人造故障不再被报出来。
    run_probe 0 '解析正常' WATCH_SERVICE_LIVENESS=no
    # 反向对照：让它真的在跑，就不该再出现「却不活动」。
    systemctl --user start "$probe_unit"
    run_probe 0 '解析正常' WATCH_SERVICE_LIVENESS=yes
fi

# ---------------------------------------------------------------------- 汇总
printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
(( fail == 0 )) || exit 1
