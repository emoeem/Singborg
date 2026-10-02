#!/usr/bin/env bash
# ============================================================================
#  从 daed 迁移到 sing-box（CachyOS / Arch 系）
#
#  用法：
#    sudo ./install-singbox.sh                 # 完整迁移
#    sudo ./install-singbox.sh --dry-run       # 只打印将要做的操作，不改系统
#    sudo ./install-singbox.sh --keep-daed     # 保留 daed-emo 包（只停服务 + 清 eBPF 钩子）
#    sudo ./install-singbox.sh --config /path/to/config.json
#
#  做四件事：
#    1) 停掉并清理 daed（含 wlan0 上的 tc/eBPF 钩子 —— 不清理换谁都会继续坏网）
#    2) 装 sing-box + 发行版规则集包，并把配置/规则集本地化（启动零网络依赖）
#    3) 写入 systemd 服务并启动
#    4) 逐项验证，失败时打印回滚命令
# ============================================================================
set -euo pipefail

DRY_RUN=0
KEEP_DAED=0
CFG_SRC=""
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --keep-daed) KEEP_DAED=1 ;;
    --config)    CFG_SRC="${2:?--config 需要一个路径}"; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
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

# ---------------------------------------------------------------- 0. 前置检查
c_step "0/7 前置检查"

TARGET_USER="${SUDO_USER:-}"
if [[ -n $TARGET_USER && $TARGET_USER != root ]]; then
  USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
else
  USER_HOME="$HOME"
fi
CFG_SRC="${CFG_SRC:-$USER_HOME/.config/sing-box/config.tun-perf.json}"
[[ -f $CFG_SRC ]] || die "找不到配置：$CFG_SRC（用 --config 指定）"
c_ok "配置来源：$CFG_SRC"

SRS_TELEGRAM="$SCRIPT_DIR/rule-set/geoip-telegram.srs"
[[ -f $SRS_TELEGRAM ]] || c_warn "未找到 $SRS_TELEGRAM（geoip/telegram 规则集将不会被安装）"

# 校验配置（如果本地已有 sing-box 二进制）
PRE_SB=""
for cand in /usr/bin/sing-box "$USER_HOME/.cache/sing-box-bin/sing-box"; do
  [[ -x $cand ]] && { PRE_SB=$cand; break; }
done
if [[ -n $PRE_SB ]]; then
  # 未装规则集包前 check 会因缺 .srs 而失败，这里只做 JSON 语法预检
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CFG_SRC" \
    && c_ok "配置 JSON 语法正常" || die "配置不是合法 JSON：$CFG_SRC"
else
  c_warn "未见 sing-box 二进制，跳过预检"
fi

# 检测是否已有其它 TUN 客户端在跑（双透明代理 = 灾难）
if ip -brief link show 2>/dev/null | grep -qE '^(tun|utun|FlClashMeta)'; then
  c_warn "检测到已存在的 TUN 设备：$(ip -brief link | awk '/^(tun|utun)/{print $1}' | tr '\n' ' ')"
  c_warn "请确认没有其它代理客户端（FlClash 等）在运行，否则会互相打架"
fi

# ------------------------------------------------------- 1. 停 daed + 清钩子
c_step "1/7 停用 daed 并清理 eBPF 钩子"
if systemctl list-unit-files daed.service &>/dev/null | grep -q daed.service; then
  run systemctl disable --now daed.service || true
  c_ok "daed.service 已停止并禁用"
fi
if pgrep -x daed &>/dev/null; then
  run pkill -x daed && c_ok "已结束残留的 daed 进程" || true
fi
sleep 1
pgrep -x daed &>/dev/null && c_warn "daed 进程仍在运行！请手动确认" || c_ok "无 daed 进程残留"

# dae 的 eBPF 程序挂在网卡的 clsact qdisc 上，只删包不清钩子会继续坏网
for dev in $(ls /sys/class/net); do
  if tc filter show dev "$dev" ingress 2>/dev/null | grep -q daed \
     || tc filter show dev "$dev" egress 2>/dev/null | grep -q daed; then
    c_warn "$dev 上发现 daed 钩子，清理 clsact"
    run tc qdisc del dev "$dev" clsact 2>/dev/null || true
  fi
done
c_ok "tc 钩子清理完成"

if ip -brief link show dae0 &>/dev/null; then
  run ip link del dae0 || true
  c_ok "已删除 dae0 设备"
fi
if ip netns list 2>/dev/null | grep -qw daens; then
  run ip netns delete daens || true
  c_ok "已删除 daens 命名空间"
fi
run resolvectl flush-caches 2>/dev/null || true

# ------------------------------------------------------------ 2. 移除旧包
c_step "2/7 处理 daed-emo 包"
if pacman -Q daed-emo &>/dev/null; then
  if [[ $KEEP_DAED == 1 ]]; then
    c_warn "--keep-daed：保留 daed-emo（已停用，可随时回滚；确认无误后可 pacman -Rns daed-emo 删除）"
  else
    run pacman -Rns --noconfirm daed-emo
    c_ok "daed-emo 已卸载"
  fi
else
  c_ok "daed-emo 未安装，跳过"
fi

# -------------------------------------------------------------- 3. 装新包
c_step "3/7 安装 sing-box 与发行版规则集包"
run pacman -S --needed --noconfirm sing-box sing-geosite-rule-set sing-geoip-rule-set
c_ok "安装完成"

# ----------------------------------------------------------- 4. 部署文件
c_step "4/7 部署配置与规则集"
run install -d -m 755 /etc/sing-box /etc/sing-box/rule-set /var/lib/sing-box
run install -m 644 "$CFG_SRC" /etc/sing-box/config.json
if [[ $DRY_RUN == 0 ]]; then
  sed -i 's#/home/[^/]*/\.cache/sing-box/cache\.db#/var/lib/sing-box/cache.db#' /etc/sing-box/config.json
fi
c_ok "配置已写入 /etc/sing-box/config.json（cache 路径已改到 /var/lib/sing-box）"

if [[ -f $SRS_TELEGRAM ]]; then
  run install -m 644 "$SRS_TELEGRAM" /etc/sing-box/rule-set/geoip-telegram.srs
  c_ok "geoip-telegram.srs 已就位（该分类不在发行版包里，随脚本附带）"
fi

c_step "校验配置（此时规则集文件已齐备）"
if [[ $DRY_RUN == 1 ]]; then
  printf '  [dry-run] sing-box check -c /etc/sing-box/config.json\n'
else
  sing-box check -c /etc/sing-box/config.json || die "配置校验失败，已中止（未启动服务）"
  c_ok "sing-box check 通过"
fi

# ----------------------------------------------------------- 5. 写服务
c_step "5/7 准备 systemd 服务"
if [[ -f /usr/lib/systemd/system/sing-box.service ]]; then
  c_ok "使用发行版自带单元 /usr/lib/systemd/system/sing-box.service（更安全：User=sing-box）"
  c_warn "它按 -D /var/lib/sing-box -C /etc/sing-box 运行（目录模式只读 *.json，勿放多余 .json）"
  if [[ -f /etc/systemd/system/sing-box.service ]]; then
    c_warn "检测到 /etc/systemd/system/sing-box.service 会覆盖发行版单元，请确认是否保留"
  fi
  run systemctl daemon-reload
elif [[ $DRY_RUN == 1 ]]; then
  printf '  [dry-run] 写入 /etc/systemd/system/sing-box.service\n'
else
  cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/sing-box.service
fi
run systemctl daemon-reload
c_ok "服务文件就绪"

# ----------------------------------------------------------- 6. 启动
c_step "6/7 启动 sing-box"
run systemctl enable --now sing-box.service
if [[ $DRY_RUN == 0 ]]; then
  for _ in $(seq 1 20); do systemctl is-active --quiet sing-box && break; sleep 1; done
  if systemctl is-active --quiet sing-box; then
    c_ok "sing-box 正在运行"
  else
    c_err "sing-box 启动失败，最近日志："
    journalctl -u sing-box --no-pager -n 25 || true
    c_err "回滚见脚本末尾输出"
  fi
fi

# ----------------------------------------------------------- 7. 验证
c_step "7/7 验证"
if [[ $DRY_RUN == 1 ]]; then
  printf '  [dry-run] 跳过验证\n'
else
  for _ in $(seq 1 15); do ip link show tun0 &>/dev/null && break; sleep 1; done
  ip -brief link show tun0 &>/dev/null && c_ok "tun0 已创建" || c_warn "未见 tun0（配置里的 interface_name 可能不同）"

  if resolvectl query github.com >/dev/null 2>&1; then c_ok "DNS 解析正常"; else c_warn "DNS 解析失败"; fi

  for url in https://github.com https://www.google.com https://mirror.krfoss.org; do
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || echo ERR)
    printf '  %-32s -> %s\n' "$url" "$code"
  done

  echo
  echo "  出口 IP（应为代理节点）："
  curl -s -m 20 https://api.ipify.org 2>/dev/null | sed 's/^/    /' || c_warn "取不到出口 IP"
  echo
  resolvectl status 2>/dev/null | grep -A2 'Current DNS Server' | sed 's/^/  /' || true
fi

# ----------------------------------------------------------- 收尾
cat <<'TAIL'

────────────────────────────────────────────────────────────
回滚到 daed（如需）：
  sudo systemctl disable --now sing-box
  sudo rm -f /etc/systemd/system/sing-box.service && sudo systemctl daemon-reload
  sudo systemctl enable --now daed          # 若已卸载 daed-emo：
                                            #   sudo pacman -S daed-emo
后续可选：
  - 确认稳定后再删旧包：sudo pacman -Rns daed-emo
  - 规则集随 pacman 更新：sudo pacman -Syu
  - 查看实时日志：journalctl -u sing-box -f
────────────────────────────────────────────────────────────
TAIL
