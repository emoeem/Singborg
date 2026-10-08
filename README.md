# Singborg

sing-box 在一台 Arch/CachyOS 笔记本上落地为「透明代理 + 规则分流 + 本地面板」的**完整过程记录**：
实测出来的结论、踩过的坑、以及为此写的脚本。

这不是教程，是**工作笔记**：每条结论后面都写了「怎么测出来的」；测错过的地方也留着（见
[《踩坑与经验》](docs/09-踩坑与经验.md)），因为**测错的方式**往往比结论更值得记。

> ## ⚠️ 关于脱敏
> 本仓库**公开**，所以所有地址与凭据都换成了占位符：
> `<clash-api-secret>`（Clash API / 面板密钥）、`<home-ip>`（自己的家宽 IP）、
> `<proxy-exit-ip>`（代理出口 IP）、`<node-server>` / `<password>`（节点地址与密码）、
> `<lan-gateway>`（家庭网关/路由器地址）。
> [`config/config.sanitized.json`](config/config.sanitized.json) 保留了**完整结构**（字段、规则、
> 分流顺序），只把值换掉 —— 可以照着学结构，但抄不走节点。

## 现在是什么状态（2026-10-08 加固后）

| 项 | 值 |
| --- | --- |
| 接管方式 | **eBPF**（`local.cgroup` 数据面；shared 两条数据面实测也通过 → 容器/VM 可接管） |
| 分流 | 国内直连 · 海外走代理（机场节点，`Proxy → Auto` URLTest 自动选优） |
| DNS | 53 端口全部劫持，无泄露；DoH 出口在代理侧；国内域名走阿里/腾讯 DoH |
| 广告拦截 | 24/26 个测试端点被拦（DNS `predefined/NXDOMAIN` + 连接层 `reject` 双保险） |
| 规则集 | 17 份（8 份来自自建包 `/usr/share/sing-box-rule-sets`，随 pacman 更新） |
| 控制面 | `clash_api`（127.0.0.1:9090）与 `services.api`（127.0.0.1:9091）**各自独立的随机密钥**；CORS 只放行本机面板源（不再是 `*`） |
| 备份 | `/etc/sing-box/backups/` 700、文件 600；保留「最新 10 份 + 7 天内不归档」，超出部分打包（不直接删） |
| 开机顺序 | drop-in `20-network-online.conf` 补 `Wants=network-online.target`（修 `missing default interface`） |
| 面板 | 自研 `sing-box-panel`（127.0.0.1:9096，内嵌 zashboard）+ 官方 dashboard（:9091） |
| 日志 | 当前进程 **零告警零错误**；`NRestarts=0`、无 OOM |
| 自建仓库 | `sing-box-ebpf`（reF1nd 分支 + `with_ebpf`）、`sing-box-panel`、`sing-box-rule-sets` |

## 怎么读

| 文档 | 讲什么 | 什么时候看 |
| --- | --- | --- |
| [01 审计报告](docs/01-审计报告-2026-10-02.md) | 一整轮实测审计：DNS 泄露、广告覆盖、geoip 误判、分流验证，以及**应用前后对比** | 想知道"这台机器上到底哪里不对" |
| [02 eBPF 可行性验证](docs/02-eBPF可行性验证.md) | 内核能力预检（51 项）、A/B 试跑、fork 与上游的差异、TUN→eBPF 的判据 | 想上 eBPF 之前 |
| [03 面板指南](docs/03-面板指南.md) | 面板怎么用、订阅/分应用策略、配置安全管线（check → 备份 → 原子替换 → 回滚） | 日常使用 |
| [04 功能测试报告](docs/04-功能测试报告.md) | 装完之后的功能验收：分流、DNS、DoH、下载、容器 | 换机器重装时照做 |
| [05 网络审计](docs/05-网络审计.md) | 更早一轮的网络层体检 | 对比 |
| [06 优化评审](docs/06-优化评审.md) | 前端面板选型、DNS 策略、规则结构的取舍 | 想改架构时 |
| [07 daed DNS 故障诊断](docs/07-daed-DNS故障诊断.md) | **历史（daed 时代，daed 已弃用）**：为什么最后没走 daed（DNS 故障的完整定位过程） | 想试 daed 之前 |
| [08 daed 迁移计划](docs/08-daed-迁移计划.md) | **历史（daed 时代）**：那份迁移方案 —— 已执行完毕，文首有待办核对表 | 同上 |
| [09 踩坑与经验](docs/09-踩坑与经验.md) | **工程向坑清单**：哪些是 sing-box 的、哪些是内核的、哪些是我自己测错的 | 最推荐先看这个 |
| [10 审计报告 2026-10-08](docs/10-审计报告-2026-10-08.md) | 第二轮完整审计：官方/社区核对、脚本审计、逐字段体检、**加固落地与验收测试（T1–T6 全过）** | 想知道"这轮到底改了什么、凭什么改" |
| [scripts/](scripts/) | 14 个脚本（含脱敏快照生成器与 10-08 加固/测试脚本） | 直接用 |
| [trial/](trial/) | eBPF A/B 试跑套件（独立状态目录，不动线上） | 想验证 eBPF 是否适合自己 |
| [config/](config/) | 脱敏后的配置快照 + 规则集清单 | 学配置结构 |

## 时间线

**10-01**：从 daed 开始（[07](docs/07-daed-DNS故障诊断.md)、[08](docs/08-daed-迁移计划.md)）→ DNS 故障定位后放弃 →
回到 sing-box，写 `install-singbox.sh` → [网络审计](docs/05-网络审计.md)、[功能测试](docs/04-功能测试报告.md)、
[优化评审](docs/06-优化评审.md) → `switch-to-local-rules.sh`（本地规则集方案）

**10-02 上午**
- eBPF 可行性：[内核预检 51 项全过、A/B 试跑](docs/02-eBPF可行性验证.md) → 确认 **eBPF 入站只存在于 reF1nd 分支**（上游没有），且该 fork **0 个 release** → 只能自建
- 建两个包：`sing-box-ebpf`（`with_ebpf`，替换官方 `sing-box`）、`sing-box-panel`（本地面板 + 内嵌 zashboard）
- [完整审计](docs/01-审计报告-2026-10-02.md)：DNS 无泄露 ✓、分流正确 ✓、但 **geoip/cn 偏旧**（`8.130.222.175` 被误判成国外）且广告表**只拦 apex 拦不到追踪子域**

**10-02 中午**（依次应用，每步都走"check → 备份 → 原子替换 → 重启 → 健康检查 → 失败回滚"）
- `10:12` 审计修复：+anti-AD 规则集、+最新 geoip/cn、删 2 条冗余规则、删 `dns-local`
- `10:35` 增强：DNS 故障转移组、mihomo 国内 IP 表、必须直连清单、国内广告端点补漏
- `10:37` **切到 eBPF**（`local.cgroup`）→ 实测接管成功（判据：不设代理的出口 == 代理出口）
- `10:45` 广告拦截从 `reject`(REFUSED) 改成 `predefined`(NXDOMAIN)：应用从**卡 5 秒**变成 **11 ms 失败**
- `11:01` 试 `tc` 数据面 → **内核不支持 TC eBPF**（`register TC eBPF TCP listener: operation not supported`）→ 自动回滚
- `11:0x` 新增 `sing-box-rule-sets` 包 + **每日自动比对上游 sha256** 的工作流
- `12:2x` 把这套脚本集成进 [`toolbox-hub`](https://github.com/emoeem/toolbox-hub) 的 TUI（5 个内置动作）
- `12:3x` 复查日志：当前进程零告警；发现一个**订阅节点已死**（`Download` 组钉在它上面，但没有规则引用它）
- `12:5x` 新增排查工具 `sing-box-why`（域名/IP → 为什么被拦 / 走哪条规则 / 出口在哪 / 怎么放行）
- `13:0x` **更正**：以 root 逐条探测四条数据面 → shared `packet_rewrite` / `socket_assign` **都通过**（此前「shared 不可用」是未经验证的推断）
- `13:0x` 量化 `bypass_rule_set`：抽样 150 个走代理的域名只有 **0.8%** 解析到 CN IP（会被改成直连）→ 近乎纯收益；顺手把 18 条 Steam 国服 CDN 加进必须直连清单
- `12:4x` 评估 [`217heidai/adblockfilters`](https://github.com/217heidai/adblockfilters)：与 anti-AD **只重叠 35%**、独有 13.9 万条域名，对照组 0 误伤 → 作为第二层广告表加进规则集包（`--with-abf` 启用）

**10-08**
- 完整审计（[10](docs/10-审计报告-2026-10-08.md)）→ **加固上线**：两个控制面密钥轮换为各自独立的随机值、CORS 由 `*` 收紧到本机面板源、删掉未被引用的 `block` 出站、`Download` 默认节点改为下载专用节点并把它从 `Auto`/`Auto-Japan` 的 urltest 候选里剔除、备份目录 700/文件 600 + 保留与归档策略、补 `Wants=network-online.target` drop-in
- 修掉脱敏脚本的真缺陷（W2）：`dns.rules[*].server`（DNS 服务器 tag）被误当成节点主机名替换成 `<node-server>`，公开快照的 DNS 分流引用因此失真 —— 现加了拒写断言
- 验收：T1–T6 全过（120 秒 227/0 失败，CPU 0.62s / RSS 108 MB），T7（节点失效自动切换与回落）**待补**

## 几条最值钱的结论

1. **eBPF 能用，硬限制只在 `local` 的 TC 数据面**（**2026-10-02 更正** —— 早先「TC / 共享两条都用不了」
   是未经验证的推断）：本机内核（`7.2.8-1-cachyos-bore-lto`）**不支持 `local.data_plane: tc`**
   （`register TC eBPF TCP listener: operation not supported`），**但 `shared` 是可用的** ——
   现役就是 `shared: packet_rewrite` 挂 `virbr0`，`sing-box api ebpf` 实测
   `role=shared mechanism=tcx` 已 attached。所以 **eBPF 模式下桥接进来的 VM 流量能接管**（VM 实测通过）；
   真正够不到的是 rootless pasta 容器（见第 5 条）。取舍：要分应用 UID 策略 → eBPF。
2. **`--mode local` 预检全绿 ≠ 能用**：它只覆盖 cgroup 路径；`tc`/`shared` 属于 `--mode all`
   （结果是 `inconclusive`，36 项 unknown）→ **只有实跑才知道**。
3. **DNS 广告拦截别用 `reject`**：sing-box 的 `reject` 回 REFUSED，而 `systemd-resolved` **不把它转告客户端**
   （当成"上游坏了"去重试），应用每个广告域名要等约 5 秒。改 `predefined` + `rcode: NXDOMAIN` 后秒失败。
4. **域名规则优先于 IP 规则**：一个 `geosite/cn` 域名解析到 Google 的 IP 时，它**照样走直连**（所以会超时）——
   这是设计，不是 bug。
5. **rootless 容器（pasta）在 eBPF 下走不了代理** —— 但原因**不是**「pasta 不创建宿主 socket」
   （实测 `ss -tnp` 能看到 `passt.avx2` 的 ESTAB socket，这句旧解释已被推翻）。现象是：
   容器内 DNS 拦截 ✅、国内直连 ✅、**境外失败** ❌。`shared` 能接管的是**桥接进来的包**（VM 实测通过），
   pasta 属用户态转发，不在覆盖范围内。处置：`--network=host`，或切回 TUN。详见 `docs/09` §6。

## 相关仓库

- [`emoeem/pkgbuild`](https://github.com/emoeem/pkgbuild) —— 这三个包的打包仓库（含每日规则集刷新工作流）
- [`emoeem/toolbox-hub`](https://github.com/emoeem/toolbox-hub) —— 把这套脚本集成成 TUI 动作（体检 / 审计 / 切模式 / 容器代理）

## 许可

个人的学习记录，随手取用；涉及第三方规则数据的部分（anti-AD / MetaCubeX / mihomo_yamls）遵循各自许可，
详见 [config/README.md](config/README.md)。
