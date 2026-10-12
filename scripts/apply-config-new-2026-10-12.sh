#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-config-new-2026-10-12.sh   （v2，2026-10-12 改）
#
# 把 docs/11 里**仍然成立**的改动应用到真实 sing-box 配置：
#   [默认]  4 处 outbounds[type=urltest].interval: "5m" → "3m"   （P2-3）
#   [可选]  dns.servers += dns-local(<IP>:53) + dns.rules[0] 本地域直查（原 P2-1）
#           —— 默认**不做**：见 docs/11 §3.8。落地前先探测该解析器；探测不过就拒绝。
#
# 为什么默认只做 urltest：2026-10-12 的落地前实测发现，本网络的"本地 DNS"192.168.31.1:53
# 从本机多次 UDP/TCP 超时、CH TXT id.server 返回 Cloudflare 的 "hkg09"（说明它只是个
# Cloudflare 转发器、并不持有 .lan/.home 域），把 .lan/.home.arpa 指过去等于把"立刻 NXDOMAIN"
# 换成"等 dns.timeout(10s) 再失败"。故 P2-1 撤回；如需启用，必须显式 --with-dns-local。
#
# 安全设计：默认 dry-run；落地时 备份 → check → 原子替换 → 重启 → 健康检查 →
#           任一步失败自动回滚。幂等：已应用过的改动会被跳过。
#
# 用法：
#   bash scripts/apply-config-new-2026-10-12.sh --dry-run --config config/config.sanitized.json
#                                   # ↑ 不需要 root：拿脱敏快照预览脚本会改什么
#   sudo bash scripts/apply-config-new-2026-10-12.sh --dry-run     # 读真配置（root 0600，必须 sudo）
#   sudo bash scripts/apply-config-new-2026-10-12.sh --apply       # 真正落地
#   sudo bash scripts/apply-config-new-2026-10-12.sh --apply --with-dns-local 192.168.1.1
#                                   # ↑ 额外加本地域直查（先探测该 IP:53，3/3 成功才写）
#   sudo bash scripts/apply-config-new-2026-10-12.sh --apply --with-dns-local auto
#
# 退出码：0 = 成功/无需改动；1 = 失败（落地模式下已自动回滚）
# ---------------------------------------------------------------------------
set -euo pipefail

CONFIG="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backups"
SINGBOX="/usr/bin/sing-box"
PROXY="http://127.0.0.1:7892"
PORTS=(7892 9090 9091)
MODE="dry-run"
WITH_DNS_LOCAL=0
DNS_LOCAL=""
FORCE_DNS_LOCAL=0
PROBE_OK=0

die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*"; }
note() { printf '\033[35mnote\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --config) shift; CONFIG="${1:-}" ;;
    --with-dns-local|--dns-local)
      WITH_DNS_LOCAL=1
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then DNS_LOCAL="$2"; shift; else DNS_LOCAL="auto"; fi
      ;;
    --force-dns-local) FORCE_DNS_LOCAL=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
  shift
done

[ -n "$CONFIG" ] || die "--config 传了空路径"
[ -r "$CONFIG" ] || die "读不到配置：$CONFIG（现网配置是 root 0600，请用 sudo 运行；或 --config <可读快照> 预览）"
command -v python3 >/dev/null || die "缺少 python3"
[ -x "$SINGBOX" ] || die "找不到 $SINGBOX"

# --- 1. 可选：本地域直查（先探测，再决定要不要写） --------------------------
if [ "$WITH_DNS_LOCAL" = "1" ]; then
  command -v dig >/dev/null || die "启用 --with-dns-local 需要 dig"
  if [ "$DNS_LOCAL" = "auto" ]; then
    DNS_LOCAL="$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')"
  fi
  [ -n "$DNS_LOCAL" ] || die "探测不到默认网关，请用 --with-dns-local <IP> 指定"
  info "本地域直查：启用；候选解析器 ${DNS_LOCAL}:53 —— 先做可用性探测（3 次，每次 2s）"
  for _i in 1 2 3; do
    _out="$(dig +time=2 +tries=1 +short example.com "@${DNS_LOCAL}" 2>/dev/null || true)"
    if printf '%s\n' "$_out" | grep -qE '^[0-9a-fA-F:.]+$'; then PROBE_OK=$((PROBE_OK+1)); fi
  done
  if [ "$PROBE_OK" -eq 3 ]; then
    ok "本地解析器 ${DNS_LOCAL}:53 探测 3/3 成功"
  elif [ "$FORCE_DNS_LOCAL" = "1" ]; then
    warn "本地解析器 ${DNS_LOCAL}:53 探测仅 ${PROBE_OK}/3 成功，但指定了 --force-dns-local，继续"
  else
    warn "本地解析器 ${DNS_LOCAL}:53 探测仅 ${PROBE_OK}/3 成功 —— 拒绝把它写进配置。"
    warn "原因：.lan/.home.arpa 这类后缀会从'立刻 NXDOMAIN'变成'等 dns.timeout(10s) 才失败'。"
    warn "确需强制的：加 --force-dns-local；换解析器的：--with-dns-local <IP>（不写则不加这条规则）"
    exit 1
  fi
else
  note "本次不加本地域直查规则：P2-1 已撤回（本网络的本地解析器只是 Cloudflare 转发器、不持有"
  note "     .lan/.home 域；证据见 docs/11 §3.8）。确需启用：--with-dns-local <IP>"
fi

# --- 2. 在 JSON 对象层面计算改动（幂等） -----------------------------------
TMP="$(mktemp /tmp/sing-box-newcfg.XXXXXX.json)"
CHANGES="$(mktemp /tmp/sing-box-changes.XXXXXX.txt)"
trap 'rm -f "$TMP" "$CHANGES"' EXIT

python3 - "$CONFIG" "$TMP" "$WITH_DNS_LOCAL" "$DNS_LOCAL" >"$CHANGES" <<'PY'
import json, sys
src, dst, with_local, dns_local = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4]
cfg = json.load(open(src, encoding='utf-8'))
out = []
dns = cfg.setdefault('dns', {})
servers = dns.setdefault('servers', [])
rules = dns.setdefault('rules', [])

if with_local:
    if any(s.get('tag') == 'dns-local' for s in servers):
        out.append('skip   dns.servers[dns-local]           已存在')
    else:
        servers.append({"type": "udp", "tag": "dns-local",
                        "server": dns_local, "server_port": 53})
        out.append('add    dns.servers += dns-local(%s:53)' % dns_local)
    if any(isinstance(r, dict) and r.get('server') == 'dns-local' for r in rules):
        out.append('skip   dns.rules[0]                    已存在')
    else:
        rules.insert(0, {"domain_suffix": [".lan", ".home", ".home.arpa", ".internal"],
                         "server": "dns-local"})
        out.append('add    dns.rules[0] = 本地域 -> dns-local')
else:
    if any(s.get('tag') == 'dns-local' for s in servers) or \
       any(isinstance(r, dict) and r.get('server') == 'dns-local' for r in rules):
        out.append('keep   dns.servers/rules 里的 dns-local  已存在，本次不动它')

n = 0
for ob in cfg.get('outbounds', []):
    if isinstance(ob, dict) and ob.get('type') == 'urltest' and ob.get('interval') == '5m':
        ob['interval'] = '3m'
        n += 1
if n:
    out.append('edit   outbounds[urltest].interval   5m -> 3m  (x%d)' % n)
else:
    out.append('skip   outbounds[urltest].interval   已是 3m 或不存在')

with open(dst, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
print('\n'.join(out))
PY

info "计划改动："
sed 's/^/       /' "$CHANGES"

if grep -q '^add\|^edit' "$CHANGES"; then
  info "字段级差异（json.tool 规范化后）："
  diff -u <(python3 -m json.tool "$CONFIG") <(python3 -m json.tool "$TMP") \
    | sed -n '1,120p' | sed 's/^/       /' || true
else
  ok "配置已是最新，无需改动。"
  exit 0
fi

# --- 3. check（非 root 时自动跳过 eBPF 入站，只校验其余字段） ---------------
CHECK_NOTE=""
check_config() {
  local f="$1" out rc t
  if out="$("$SINGBOX" check -c "$f" 2>&1)"; then return 0; fi
  if [ "$(id -u)" != "0" ] && printf '%s' "$out" | grep -qE 'eBPF|MEMLOCK|operation not permitted'; then
    t="$(mktemp /tmp/sing-box-noebpf.XXXXXX.json)"
    if python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
eb = [x for x in c.get("inbounds", []) if x.get("type") == "ebpf"]
c["inbounds"] = [x for x in c.get("inbounds", []) if x.get("type") != "ebpf"]
json.dump(c, open(sys.argv[2], "w", encoding="utf-8"))
sys.exit(0 if eb else 3)
' "$f" "$t" && "$SINGBOX" check -c "$t" 2>/dev/null; then
      rm -f "$t"
      CHECK_NOTE="非 root：eBPF 入站需 BPF/MEMLOCK 权限，已摘掉后单独校验其余字段 → 通过"
      return 0
    fi
    rm -f "$t"
  fi
  printf '%s\n' "$out" | tail -5 >&2
  return 1
}

info "校验候选内容 ..."
if ! check_config "$TMP"; then
  die "候选配置未通过 sing-box check"
fi
if [ -n "$CHECK_NOTE" ]; then ok "sing-box check 通过（${CHECK_NOTE}）"; else ok "sing-box check 通过（root，含 eBPF 入站）"; fi

# --- 4. dry-run 到此为止 ----------------------------------------------------
if [ "$MODE" = "dry-run" ]; then
  info "dry-run：不写任何文件。要真正落地请加 --apply"
  exit 0
fi

# --- 5. 落地 ---------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "--apply 需要 root（sudo）"
[ -d "$BACKUP_DIR" ] || die "备份目录不存在：$BACKUP_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/config.json.bak.${TS}"

info "备份现网配置 → ${BACKUP}"
cp -p "$CONFIG" "$BACKUP"
chmod 600 "$BACKUP"

info "原子替换现网配置（保持 0600）"
install -o root -g root -m600 "$TMP" "${CONFIG}.new.${TS}"
mv -f "${CONFIG}.new.${TS}" "$CONFIG"

rollback() {
  warn "检测到失败，回滚到 ${BACKUP} ..."
  install -o root -g root -m600 "$BACKUP" "$CONFIG"
  systemctl restart sing-box || true
  warn "已回滚。请检查：journalctl -u sing-box -n 50 --no-pager"
}
trap 'rollback' ERR

info "重启 sing-box ..."
systemctl daemon-reload
systemctl restart sing-box

info "等待监听端口：${PORTS[*]}"
missing=1
for i in $(seq 1 20); do
  missing=0
  for p in "${PORTS[@]}"; do
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$" || missing=1
  done
  [ "$missing" = "0" ] && break
  sleep 1
done
[ "$missing" = "0" ] || die "20s 内端口未全部监听（${PORTS[*]}）"
ok "端口已监听"

info "健康检查：经代理请求 generate_204（最多 5 次）"
code="000"
for i in $(seq 1 5); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$PROXY" \
          https://www.gstatic.com/generate_204 || true)"
  [ "$code" = "204" ] || [ "$code" = "200" ] && break
  sleep 3
done
[ "$code" = "204" ] || [ "$code" = "200" ] || die "健康检查失败（HTTP ${code}）"
ok "代理链路正常（HTTP ${code}）"

if [ "$WITH_DNS_LOCAL" = "1" ]; then
  info "本地域解析抽查（非致命）"
  dig +short +time=2 +tries=1 test.lan @"${DNS_LOCAL}" || true
fi

trap - ERR
echo
ok "完成。已应用改动；备份在 ${BACKUP}"
echo "     回滚： sudo install -m600 ${BACKUP} ${CONFIG} && sudo systemctl restart sing-box"
echo "     体检： bash scripts/sing-box-status"
echo "     日志： journalctl -u sing-box --since '-5 min' -p warning"
