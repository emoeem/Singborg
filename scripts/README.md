# 运维脚本

这些脚本的共同点：**改配置一律走同一条安全管线** ——

```text
改配置（内存里）→ sing-box check（不过就什么都不做）→ 时间戳备份 → 原子替换
  → 重启 → 健康检查 → 任一环节失败就自动回滚 + 重启
```

所以它们可以放心重跑（幂等），也不怕"改一半失败"。这台机器上它已经自动救过一次
（`tc` 数据面试错那次）。

| 脚本 | 干什么 | 要 root |
| --- | --- | --- |
| `sing-box-why` | 查一个域名/IP：**为什么被拦 / 走哪条规则 / 从哪个出口出去**，被拦时直接给出放行片段 | ❌（只读） |
| `sing-box-status` | 一屏体检：模式 / 入站 / 出口 / 分流 / DNS / 规则集 / 备份 | ❌（只读） |
| `apply-audit-fixes.sh` | 审计修复：补 anti-AD 广告表、刷新 geoip/cn、清理冗余规则与 `dns-local`。**7 个**可选开关见下 | ✅ |
| `switch-to-ebpf.sh` | TUN → eBPF；已在 eBPF 时可原地调整数据面/共享/国内绕过。开关见下 | ✅ |
| `switch-to-tun.sh` | eBPF → TUN（TUN 用 `auto_route` 覆盖转发流量，**容器/虚拟机也能被代理**）。TUN 定义取自最近的 `pre-backup` | ✅ |
| `test-shared-interception.sh` | 验证 eBPF `shared` 到底有没有接管下游：临时 netns+veth 接到 shared 接口上发请求，看出口与 Clash 链路、顺带抓包。跑完自动清理。开关见下 | ✅ |
| `enable-container-proxy.sh` | 在网桥上开 eBPF `shared` 数据面；会**逐个数据面用 root 探测**（`packet_rewrite` / `socket_assign`）再决定用哪个，不再一刀切禁用；`--disable` 关闭 | ✅ |
| `refresh-rule-sets.sh` | 刷新自建规则集包（`~/pkgbuild-source`）的源文件与 `PKGBUILD` 校验和/SKIP 计数；计数是数据驱动的 | ❌（只有构建包时需要） |
| `install-singbox.sh` | 安装/迁移 sing-box 到本机（最早的引导脚本） | ✅ |
| `switch-to-local-rules.sh` | 早期方案：把规则集切成本地文件（不依赖运行期远程下载） | ✅ |
| `apply-emoeem-mirrors.sh` | 配置自建 Arch 仓库的镜像（`[emoeem]` 段） | ✅ |
| `generate-sanitized-config.py` | 生成 `config/config.sanitized.json` 脱敏快照：**结构化**脱敏（不是按键名替换）+ 拒写断言。源配置是 0600 root，所以要用 root 跑 | ✅ |
| `apply-hardening-2026-10-08.sh` | 2026-10-08 加固一键落地（备份 → `sing-box check` → 原子替换 → 健康检查 → 失败自动回滚）。开关见下 | ✅ |
| `test-singbox-2026-10-08.sh` | 第 5 步验收测试 T1–T7：服务面 / 国内直连（eBPF 路径）/ 显式代理链路 / TCP+UDP-QUIC / DNS 防泄漏 / 并发稳定性 / 可选的节点失效切换与回落 | ✅ |

## `switch-to-ebpf.sh` 的开关

```bash
sudo ./switch-to-ebpf.sh   --data-plane cgroup        # local 数据面（cgroup 可用；tc 在本机必失败，见文末）
  --shared virbr0            # 开共享接管（VM/桥接容器）；--no-shared 关闭
  --shared-plane packet_rewrite   # 共享数据面：packet_rewrite（默认）或 socket_assign
  --bypass-cn                # 让命中 CN IP 的流量绕过 eBPF（省 CPU，DNS 仍劫持）
  --no-bypass-cn             # 撤销上面这个
  --force                    # 越过预检守卫（别用来白试 tc）
```

`--bypass-cn` 只影响 `local`；它与 `shared.bypass_rule_set` **互相独立**。

## `test-shared-interception.sh` 的开关

```bash
sudo ./test-shared-interception.sh              # 默认：与当前配置一致的条件下测试
sudo ./test-shared-interception.sh --shared-only # ★ 验证 shared 请用这个
sudo ./test-shared-interception.sh --debug-log   # 临时开 debug 日志，跑完自动还原
sudo ./test-shared-interception.sh --keep        # 出问题保留 netns 现场
```

**为什么验证 shared 一定要 `--shared-only`**：脚本里的"下游客户端"是 netns 里的一个**宿主进程**，
它的 socket 仍在宿主 cgroup 里 → 开着 `local` 时会被 **local 钩子先截走**，于是表现得像
"shared 直连能通、走代理不通"（其实两条钩子都插了一脚）。临时关掉 `local` 后只剩 shared 钩子，
才等价于真实 VM/下游的路径 —— 这时实测**直连与代理都通过**。

## `apply-audit-fixes.sh` 的开关

```bash
sudo ./apply-audit-fixes.sh \
  --with-extra-ads       # 补 3 个国内广告端点（精确域名，不动 apex）
  --with-cncidr          # 加 mihomo 国内 IP 表（第三份来源）
  --with-direct-list     # STUN / 游戏主机 / LAN cache / NCSI 强制直连
  --with-dns-groups      # 把闲置的备用 DNS 编成故障转移组（fork 支持 type=group）
  --use-package-paths    # 规则集改指 /usr/share/sing-box-rule-sets（随 pacman 更新）
  --nxdomain-ads         # DNS 广告拦截从 reject(REFUSED) 改成 predefined(NXDOMAIN)
  --with-abf             # 接入 217heidai/adblockfilters（215k 条后缀，与 anti-AD 只重叠 35%）
```

不带开关 = 只做基础修复（补广告表 + 刷新 geoip/cn + 清理冗余规则）。

`--use-package-paths` 只认它**内置的 tag 表**（anti-AD / geoip/cn-fresh / cncidr-mihomo /
must-direct / ads-extra / **adblockfilters**）。表里漏掉的 tag 会被留在 `/etc/sing-box/rule-set/`，
于是 `pacman -Syu` 更新规则集包时它**不会跟着更新** —— `adblockfilters` 就这么漏过一次，已修。

## `apply-hardening-2026-10-08.sh` 的开关

```bash
sudo ./apply-hardening-2026-10-08.sh --dry-run     # 只生成候选 + check + 打印 diff，不落盘不重启（建议先跑这个）
sudo ./apply-hardening-2026-10-08.sh               # 正式执行（默认全做）
sudo ./apply-hardening-2026-10-08.sh --keep-cors   # 不动 CORS（保留 * 与 private-network 放行）
sudo ./apply-hardening-2026-10-08.sh --no-routing  # 不改 Download 默认节点与 Auto/Auto-Japan 候选
sudo ./apply-hardening-2026-10-08.sh --no-retention# 只加固备份权限，不做保留/归档
sudo ./apply-hardening-2026-10-08.sh --harden-cache-db  # 顺带 chmod 600 /var/lib/sing-box/cache.db（默认关）
```

它做六件事：① 轮换两个控制面密钥为各自独立的随机值 ② CORS 收紧到 `127.0.0.1:9096`/`localhost:9096`
并删掉 `access_control_allow_private_network` ③ 删除未被引用的 `block` 出站 ④ `Download` 默认节点改为
「🇯🇵 日本Z05｜下载专用」并从 `Auto`/`Auto-Japan` 剔除它 ⑤ 备份目录 700 / 文件 600 + 保留 10 份 + 7 天外归档
⑥ 写 `20-network-online.conf` drop-in。用 `flock` 保证单实例，进程被 `check` 拦下时按原配置起回服务。

## `test-singbox-2026-10-08.sh` 的开关

```bash
sudo ./test-singbox-2026-10-08.sh --load-seconds 120   # 第 6 项并发负载时长（默认 60）
sudo ./test-singbox-2026-10-08.sh --with-failover      # 追加 T7：临时 nft 屏蔽当前节点 IP，等 urltest 切换；撤销后等回落
```

T7 会临时建 `inet sbx_test` 表（**IPv4+IPv6 两条**都写，否则拦不住默认走 IPv6 的连接），
结束时无论成败都会删表；若被中断请手动 `sudo nft delete table inet sbx_test` 收尾。

## 健康判据（两种模式不一样）

| 模式 | 判据 |
| --- | --- |
| TUN | `tun0` 出现 + **不设代理的出口 == 经本地代理口的出口** + 国内直连 + DNS 广告被拦 |
| eBPF | **没有 `tun0`**，所以只看：`sing-box api ebpf` 有活动入站 + 不设代理的出口 == 代理出口 + 国内直连 + DNS 广告被拦 |

DNS 那项一律用**随机子域**（`<hex>.doubleclick.net`）并问一个对照域名 ——
否则 `systemd-resolved` 的缓存会把"没生效"伪造成"生效"（我第一次切 eBPF 就是这么被骗着回滚的）。

## 注意

### `sing-box-why` 是怎么工作的（值得记）

- 没被拦的域名：连一次真实连接，从 **Clash API 读实际命中的 `rule` / `rulePayload` / `chains`** —— 这是权威结果，不是猜的。
- 被 DNS 拦下的域名：**不会产生连接记录**，所以退一步逐个规则集判定命中哪一个；AdGuard 来源的 `.srs` 无法反编译，会**如实标注"无法判定"**而不是硬猜。
- 抽样踩到的坑：直连时 `metadata.host` 常为空、`dig` 默认只查 A 而系统可能走 IPv6、
  sniff 到的可能是 CNAME 目标（`www.baidu.com` → `www.a.shifen.com`）。
  所以最后是**先解析、再连指定 IP、但保留 SNI** —— 目的 IP 确定、分流仍按原域名判。

- 这套脚本在 [`emoeem/toolbox-hub`](https://github.com/emoeem/toolbox-hub) 里也有一份
  （多了注解头与自提权前导，用来当 TUI 动作）。两边的**业务逻辑应当保持一致**，改的时候一起改。
- `switch-to-ebpf.sh --data-plane tc` 在本机**一定会失败**：内核不支持 **local 的 tc 数据面**
  （`register TC eBPF TCP listener: operation not supported`）。脚本会在 `--mode all` 预检不通过时
  提前拦住，别加 `--force` 白试。
- **别把这条推广到 `shared`**：共享数据面走的是另一套（TCX），本机**实测可用**
  （`api ebpf` 里能看到 `role=shared mechanism=tcx`），直连与代理两条路都通过。早期文档把两者
  混为一谈过，已修。
