#!/usr/bin/env bash
# 每天检查 sing-box-rule-sets 的三个远程源是否有变化，有变化就更新 PKGBUILD（pkgver 用日期 + 新 sha256）
# 并生成 .SRCINFO，供 CI 提交后自动重建包。没有变化则什么都不做（退出码 0）。
#
# 用法：scripts/refresh-rule-sets.sh [--check]
#   --check  只报告是否有变化，不写文件（供本地预览）
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly repo_root
readonly pkg_dir="${repo_root}/packages/sing-box-rule-sets"
readonly pkgbuild="${pkg_dir}/PKGBUILD"
readonly srcinfo="${pkg_dir}/.SRCINFO"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

readonly -a urls=(
    "https://anti-ad.net/adguard.txt"
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs"
    "https://raw.githubusercontent.com/HenryChiao/mihomo_yamls/ruleset/singbox/version4/cncidr.srs"
    "https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblocksingbox.srs"
)

[[ -f "$pkgbuild" ]] || { printf 'missing %s\n' "$pkgbuild" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf 'Downloading %d rule-set source(s)...\n' "${#urls[@]}"
new_sums=()
for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    out="${work}/src${i}"
    if ! curl --fail --silent --show-error --location \
            --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 \
            --max-time 600 -o "$out" "$url"; then
        printf 'download failed: %s\n' "$url" >&2
        exit 1
    fi
    [[ -s "$out" ]] || { printf 'empty download: %s\n' "$url" >&2; exit 1; }
    new_sums+=("$(sha256sum "$out" | cut -d' ' -f1)")
    printf '  %s  %s\n' "${new_sums[$i]:0:12}" "$url"
done

# 取出 PKGBUILD 里当前的远程源 sha256sums（个数 = urls 的个数，别写死）
mapfile -t old_sums < <(awk -F"'" '/^sha256sums=\(/{f=1;next} f&&/^\)/{exit} f&&/\x27[0-9a-f]{64}\x27/{gsub(/[^0-9a-f]/,"");print}' "$pkgbuild" | head -n "${#urls[@]}")
old_sums=("${old_sums[@]:0:${#urls[@]}}")

changed=0
for ((i = 0; i < ${#urls[@]}; i++)); do
    if [[ "${old_sums[$i]:-}" != "${new_sums[$i]}" ]]; then
        printf 'changed: source %d\n  old %s\n  new %s\n' "$i" "${old_sums[$i]:-<none>}" "${new_sums[$i]}"
        changed=1
    fi
done

if (( ! changed )); then
    printf 'No rule-set source changed; nothing to do.\n'
    exit 0
fi
if (( CHECK_ONLY )); then
    printf 'Changes detected (--check: not modifying anything).\n'
    exit 0
fi

new_date="$(date -u +%Y%m%d)"
python3 - "$pkgbuild" "$new_date" "${new_sums[@]}" <<'PY'
import re, sys, pathlib
path, date_, *sums = sys.argv[1:]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
s = re.sub(r"^pkgver=.*$", f"pkgver={date_}", s, count=1, flags=re.M)
s = re.sub(r"^pkgrel=\d+$", "pkgrel=1", s, count=1, flags=re.M)
body = "".join(f"    '{v}'\n" for v in sums)
# SKIP 的个数 = 本地源个数：从原文件里数出来，别写死（增减本地源时会错位，
# 后果是 makepkg 报「完整性校验缺失」而构建失败）
skip_count = len(re.findall(r"^\s*'SKIP'", s, flags=re.M))
s = re.sub(
    r"sha256sums=\(\n(?:.*\n)*?\)",
    lambda _m: "sha256sums=(\n" + body + "    'SKIP'\n" * skip_count + ")",
    s,
    count=1,
)
p.write_text(s, encoding="utf-8")
print(f"PKGBUILD updated: pkgver={date_}")
PY

( cd "$pkg_dir" && BUILDDIR="$(mktemp -d)" SRCDEST="$work" PKGDEST="$work" LOGDEST="$work" makepkg --printsrcinfo > "$srcinfo" )
printf 'Regenerated %s\n' "${srcinfo#"$repo_root"/}"
