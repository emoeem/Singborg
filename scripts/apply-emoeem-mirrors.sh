#!/usr/bin/env bash
# 给 /etc/pacman.conf 的 [emoeem] 段追加多个 GitHub 加速镜像（含直连兜底）。
#
# 用法：
#   sudo ./apply-emoeem-mirrors.sh            # 改 /etc/pacman.conf
#   ./apply-emoeem-mirrors.sh <文件>          # 改指定文件（无需 root）
#
# 行为：
#   * 优先按 "# BEGIN emoeem pacman repository" / "# END ..." 标记整段重写，
#     顺带清掉重复安装留下的多余 BEGIN 标记；
#   * 没有标记时按 [emoeem] 小节重写；
#   * 两者都没有时追加到文件末尾；
#   * 改前备份为 <文件>.bak.<时间戳>，只动 emoeem 相关行，其余内容逐字节不变。
set -euo pipefail

CONF="${1:-/etc/pacman.conf}"
[[ -f "$CONF" ]] || { echo "找不到配置文件: $CONF" >&2; exit 1; }

BAK="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a -- "$CONF" "$BAK"
echo "已备份: $BAK"

CONF="$CONF" python3 - <<'PY'
import os, re

conf = os.environ["CONF"]
repo = "https://github.com/emoeem/pkgbuild/releases/download/repo"
proxies = [
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
    "https://gh.llkk.cc/",
    "https://ghfile.geekertao.top/",
]
BEGIN = "# BEGIN emoeem pacman repository（由 client/install.sh 管理，重复运行会更新此段）"
END = "# END emoeem pacman repository"

block = [BEGIN, "[emoeem]", "SigLevel = Never"]
block += [f"Server = {p}{repo}" for p in proxies]
block += [f"Server = {repo}", END]

with open(conf, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

def find(pat, start=0):
    rx = re.compile(pat)
    for i in range(start, len(lines)):
        if rx.match(lines[i]):
            return i
    return None

b = find(r"^\s*#\s*BEGIN emoeem pacman repository")
e = find(r"^\s*#\s*END emoeem pacman repository", (b or 0) + 1)
h = find(r"^\s*\[emoeem\]\s*$")

if b is not None and e is not None and e > b:
    out = lines[:b] + [l + "\n" for l in block] + lines[e + 1:]
    action = "按 BEGIN/END 标记重写整段"
elif h is not None:
    stop = len(lines)
    for j in range(h + 1, len(lines)):
        if re.match(r"^\s*\[.+\]\s*$", lines[j]) or lines[j].strip() == END:
            stop = j + 1 if lines[j].strip() == END else j
            break
    out = lines[:h] + [l + "\n" for l in block[1:]] + lines[stop:]
    action = "按 [emoeem] 小节重写"
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    out = lines + ["\n"] + [l + "\n" for l in block]
    action = "追加新段"

with open(conf, "w", encoding="utf-8") as fh:
    fh.writelines(out)

print(f"{action}: {conf} -> {len(proxies)} 个加速代理 + 1 个直连兜底")
PY

echo
echo "--- 结果 ---"
awk '/# BEGIN emoeem pacman repository/{f=1} f{print} /# END emoeem pacman repository/{f=0}' "$CONF"
echo
echo "接着刷新数据库：sudo pacman -Syy"
