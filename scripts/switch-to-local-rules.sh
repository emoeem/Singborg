#!/usr/bin/env bash
# ============================================================================
#  部署优化后的 sing-box 配置到 /etc/sing-box/
#
#  用法：
#    sudo ./switch-to-local-rules.sh            # 应用
#    sudo ./switch-to-local-rules.sh --dry-run  # 只打印，不改系统
#
#  部署内容（源文件 ~/.config/sing-box/config.tun-perf.json，已用 sing-box 1.14.2
#  真二进制 check 通过，exit=0 且无弃用告警），共 17 项改动：
#    1. 7 个规则集 remote -> local（发行版包提供 2119 个 .srs，启动零网络依赖、随 pacman 更新）
#       · geoip/telegram 不在发行版包内（该包只装国家码），随本脚本附带
#    2. log.level: info -> warn（消除逐条 DNS 交换日志）
#    3. cache_file.store_dns: true（DNS 缓存跨重启保留）
#    4. route.find_process: false（无进程分流规则，省掉每连接 /proc 查找）
#    5. 移除冗余入站 socks:7893（mixed:7892 已含 SOCKS5）
#    6. Proxy.interrupt_exist_connections: false（切节点不掐断下载中的连接）
#    7. Auto.interrupt_exist_connections: false（同上）
#    8. Proxy 选择器加入 Japan/HongKong/Singapore（否则面板里选不到这三个分组）
#    9. geosite/apple@cn -> 直连（Apple 服务走国内 CDN）+ DNS 同步用国内解析
#   10. experimental.clash_api -> services:[api + 内置 dashboard]：
#       sing-box 自动下载官方面板到 /var/lib/sing-box/dashboard 并自己伺服
#       （经 http_client proxy-rules 下载），浏览器开 http://127.0.0.1:9091 即是 GUI
#   11. 额外加回 experimental.clash_api（端口 9090，Clash REST）+ 自托管 metacubexd：
#       官方 dashboard 观感偏工程化，社区主流是 metacubexd/zashboard，它们只认 Clash API。
#       开 CORS(*) 与 access_control_allow_private_network（Chrome PNA），
#       面板地址 http://127.0.0.1:9090/ui/ ，与官方 dashboard 并存互不影响
#   12. 【修 bug】DNS 广告拦截规则从最后一条移到第 1 条：
#       原顺序 apple@cn/cn/google/!cn 在前，会把 pagead.l.google.com(google域)、
#       guanggaoad.youku.com(cn域) 这类广告域名先路由出去、照样解析成功；
#       路由规则里 reject 本来就在最前，两边不一致。详见 singbox-functional-test-report.md
#   13. 【修 bug】TUN 增加 IPv6 地址 fdfe:dcba:9876::1/126：
#       原来 TUN 只有 IPv4，sing-box 会用 `ip -6 rule 9000: from all unreachable` 主动黑洞
#       所有 IPv6 → v6-only 站点不可达（实测 ipv6.google.com：TUN 模式 000 / 代理口 7892 200，
#       说明节点本来能到 v6）。加上地址后 v6 也经代理走；LAN v6 由 ip_is_private 规则保持直连。
#       同时清理 daed 残留（实测 daens netns 仍在）。
#   14. 【修配错】地区分组自动选择：
#       Japan/HongKong/Singapore 三个 selector 的 default 原本都指向全局 urltest "Auto"
#       → 面板里选 "Japan" 可能拿到香港节点。改为新增 Auto-Japan/Auto-HongKong/Auto-Singapore
#       三个地区级 urltest（5m / 50ms），地区组默认指向各自的 urltest；
#       全局 Auto：探测间隔 10m -> 5m，容差 80ms -> 150ms（只在明显更快时才切换，减少节点抖动）。
#   15. 【加密】国内 DNS 升级为 DoH：
#       dns-direct-ali -> https://dns.alidns.com（223.5.5.5 + SNI），
#       dns-direct-tencent -> https://doh.pub（120.53.53.53 + SNI），
#       并加 hosts-bootstrap 预解析 DoH 域名打破自举循环。
#       效果：运营商再也看不到你查了哪些国内域名（原来明文 UDP 可见）。
#   16. 【增强拦截】新增本地规则集 Ads_AWAvenue（AdGuard 961 条 -> .srs，离线）
#       并加入路由/DNS 两处 reject。覆盖 geosite/category-ads-all 没有的域名。
#   17. 【易用】新增 Download 选择组（默认锁定 🇯🇵 日本Z05 | 下载专用），并加入 Proxy 成员。
#       大文件下载时在面板点一下即可，不影响日常自动选路。
#
#  注意：`sing-box check` 只做语法/字段校验，**不保证能启动**
#       （例：dns 服务器写 detour:"direct" 会 check 通过但 run 时 FATAL）。
#       因此脚本在本步失败时会**自动回滚**到备份配置并重启。
#
#  安全设计：
#    * 先放好规则集、再 sing-box check、**check 通过才 restart**
#    * 旧配置备份为 /etc/sing-box/config.json.bak.<时间戳>
#      （sing-box 的 -C 目录模式只读 *.json，.bak 结尾会被忽略，不会误加载）
#    * check 失败自动还原备份并中止，正在运行的服务不受影响
# ============================================================================
set -euo pipefail

DRY_RUN=0
CFG_SRC=""
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --config)  CFG_SRC="${2:?--config 需要一个路径}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

c_step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
c_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[1;33m[!]\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }
run()    { if [[ $DRY_RUN == 1 ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo $0"
[[ $DRY_RUN == 1 ]] && c_warn "dry-run 模式：只打印，不修改系统"

CONF=/etc/sing-box/config.json
SRS_DIR=/etc/sing-box/rule-set
SRS_FILES=("$SCRIPT_DIR/rule-set/geoip-telegram.srs" "$SCRIPT_DIR/rule-set/AWAvenue-Ads-Rule.srs")

# ---------------------------------------------------------------- 前置检查
c_step "1/6 前置检查"
[[ -f $CONF ]] || die "找不到 $CONF（你确定 sing-box 已部署？）"
systemctl is-active --quiet sing-box && c_ok "sing-box 服务正在运行" || c_warn "sing-box 服务当前未运行"
for f in "${SRS_FILES[@]}"; do
  [[ -f $f ]] || die "缺少 $f（这两个规则集不在发行版包里，必须随脚本提供）"
done
c_ok "附带规则集：$(for f in "${SRS_FILES[@]}"; do printf '%s(%sB) ' "$(basename "$f")" "$(stat -c%s "$f")"; done)"

TARGET_USER="${SUDO_USER:-}"
if [[ -n $TARGET_USER && $TARGET_USER != root ]]; then
  USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
else
  USER_HOME="$HOME"
fi
CFG_SRC="${CFG_SRC:-$USER_HOME/.config/sing-box/config.tun-perf.json}"
[[ -f $CFG_SRC ]] || die "找不到新配置：$CFG_SRC（用 --config 指定）"
c_ok "新配置来源：$CFG_SRC"

for f in geosite-category-ads-all geosite-cn "geosite-geolocation-!cn" geosite-google \
         "geosite-category-ai-!cn" geoip-cn; do
  [[ -f /usr/share/sing-box/rule-set/$f.srs ]] || die "发行版规则集缺失：/usr/share/sing-box/rule-set/$f.srs
  → 请先安装：sudo pacman -S sing-geosite-rule-set sing-geoip-rule-set"
done
c_ok "发行版规则集齐备（/usr/share/sing-box/rule-set/）"

# ------------------------------------------- 1b. 清理 dae/daed 残留（实测仍有 daens netns）
c_step "1b/6 清理 dae 残留"
if ip netns list 2>/dev/null | grep -qw daens; then
  run ip netns delete daens && c_ok "已删除残留的 daens 网络命名空间"
else
  c_ok "无 daens 残留"
fi
if ip -brief link show dae0 &>/dev/null; then
  run ip link del dae0 && c_ok "已删除残留的 dae0 设备"
else
  c_ok "无 dae0 残留"
fi
for dev in $(ls /sys/class/net); do
  if tc filter show dev "$dev" ingress 2>/dev/null | grep -q daed \
     || tc filter show dev "$dev" egress 2>/dev/null | grep -q daed; then
    c_warn "$dev 上发现 daed eBPF 钩子，清理 clsact"
    run tc qdisc del dev "$dev" clsact 2>/dev/null || true
  fi
done
c_ok "tc 钩子检查完成"

# --------------------------------------------------------- 2. 放好 telegram
c_step "2/6 安装 geoip-telegram 规则集"
run install -d -m 755 "$SRS_DIR"
for f in "${SRS_FILES[@]}"; do run install -m 644 "$f" "$SRS_DIR/$(basename "$f")"; done
c_ok "已装入 $SRS_DIR/：$(for f in "${SRS_FILES[@]}"; do printf '%s ' "$(basename "$f")"; done)"

# ------------------------------------------------------------- 3. 备份
c_step "3/6 备份当前配置"
BAK="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
run cp -a "$CONF" "$BAK"
c_ok "备份：$BAK（.bak 结尾，sing-box -C 目录模式会忽略它）"

# --------------------------------------------------------- 4. 写入新配置
c_step "4/6 写入本地规则集配置"
run install -m 644 "$CFG_SRC" "$CONF"
if [[ $DRY_RUN == 0 ]]; then
  sed -i 's#/home/[^/]*/\.cache/sing-box/cache\.db#/var/lib/sing-box/cache.db#' "$CONF"
fi
if [[ $DRY_RUN == 0 ]]; then
  python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for rs in d["route"]["rule_set"]:
    print(f"  {rs['type']:6} {str(rs['tag'])[:44]:46} {rs.get('path') or rs.get('url')}")
print("  cache_file:", d["experimental"]["cache_file"]["path"])
PY
fi

# --------------------------------------------------------- 5. 校验（关键）
c_step "5/6 校验配置（通过才会重启服务）"
if [[ $DRY_RUN == 1 ]]; then
  printf '  [dry-run] sing-box check -c %s\n' "$CONF"
else
  if sing-box check -c "$CONF"; then
    c_ok "sing-box check 通过（全部本地规则集可加载）"
  else
    c_err "校验失败，正在还原备份…"
    cp -a "$BAK" "$CONF"
    c_err "已还原 $CONF —— 服务未重启，当前运行状态不受影响"
    exit 1
  fi
fi

# --------------------------------------------------------- 6. 重启并验证
c_step "6/6 重启并验证"
run systemctl restart sing-box
if [[ $DRY_RUN == 0 ]]; then
  for _ in $(seq 1 20); do systemctl is-active --quiet sing-box && break; sleep 1; done
  if systemctl is-active --quiet sing-box; then
    c_ok "sing-box 已重启并运行"
  else
    c_err "服务未能启动（check 通过但 run 失败）—— 正在自动回滚到备份配置"
    journalctl -u sing-box --no-pager -n 20 || true
    cp -a "$BAK" "$CONF"
    systemctl restart sing-box
    sleep 4
    if systemctl is-active --quiet sing-box; then
      c_ok "已回滚，服务用原配置恢复运行（本次改动未生效）"
    else
      c_err "回滚后仍未起来，请手动排查：journalctl -u sing-box -n 50"
    fi
    exit 1
  fi

  for _ in $(seq 1 15); do ip link show tun0 &>/dev/null && break; sleep 1; done
  ip -brief link show tun0 &>/dev/null && c_ok "tun0 正常" || c_warn "未见 tun0"

  echo
  echo "  出口 IP："
  printf '    经 TUN   : %s\n' "$(curl -s -m 20 https://api.ipify.org 2>/dev/null || echo 失败)"
  printf '    经 :7892 : %s\n' "$(curl -s -m 20 -x http://127.0.0.1:7892 https://api.ipify.org 2>/dev/null || echo 失败)"
  echo
  echo "  连通性："
  for u in https://github.com https://www.google.com https://mirror.krfoss.org/; do
    printf '    %-30s -> %s\n' "$u" "$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$u" 2>/dev/null || echo ERR)"
  done

  echo
  echo "  启动阶段是否还有规则集下载："
  journalctl -u sing-box --no-pager -n 120 2>/dev/null | grep -ci 'rule-set\|download' | sed 's/^/    匹配行数: /'
fi

cat <<TAIL

────────────────────────────────────────────────────────────
完成。之后规则集随 pacman 更新：sudo pacman -Syu
回滚：sudo cp -a $BAK $CONF && sudo systemctl restart sing-box
日志：journalctl -u sing-box -f
注意：sing-box 用 -C /etc/sing-box（目录模式，只读 *.json），
      不要在 /etc/sing-box/ 里放多余的 .json，否则会被合并解析。
────────────────────────────────────────────────────────────
TAIL
