# 配置记录

## `config.sanitized.json` 是什么

本机 `/etc/sing-box/config.json` 的脱敏快照，作用是**看懂结构**。

> ✅ **2026-10-08 已按现役配置对齐线上**：17 份规则集（含 `adblockfilters` 与后加的 `lyc/cn`、
> `lyc/geolocation-!cn`）、`inbounds[ebpf].shared = {enabled: true, data_plane: packet_rewrite, interface: ["virbr0"]}`、
> `local.bypass_rule_set = ["geoip/cn", "geoip/cn-fresh", "cncidr-mihomo"]`、`clash_api` 的 CORS 收紧到本机面板源、
> 未引用的 `block` 出站已删除、`Download` 组默认节点已改。
> （配置一改就请重新生成，别让快照落后于线上。生成：`sudo scripts/generate-sanitized-config.py --source /etc/sing-box/config.json` ——
> 源配置是 0600 root，必须用 root 跑；脚本自身只读本地文件，不联网、不执行 git/上传。）

- 保留：`inbounds` / `outbounds` 的结构与协议字段 / `dns` / `route` / `experimental`，
  以及每个 `rule_set` 的 `path`（**路径本身是最有信息量的部分**：一眼看出哪几份是自建的）；
- 换掉：代理节点的 `server` → `<node-server>`、`server_port` → `0`、`password`/`uuid`/`sni`/`host`
  → 占位符；两处 `secret`（`clash_api` 与 `services[api]`）→ `<clash-api-secret>`
  （两处在线上是**各自独立**的 43 字符随机值，快照里共用一个占位符）；
- **没有**换掉：DNS 的公共 DoH 端点（`1.1.1.1` / `8.8.8.8` / `dns.alidns.com` / `doh.pub`）——
  那是公共设施，也是配置里最重要的思路之一。

> 生成脚本是「结构化脱敏」而不是「按键名替换」：`server` 这个键名同时出现在代理节点（要脱）
> 和 DNS 服务器（不该脱）里，按键名替换会把两者一起打掉。生成后有自检断言。
>
> ⚠️ **2026-10-08 修掉一个真实缺陷（W2）**：`dns.rules[*].server` 里放的是 **DNS 服务器 tag**
> （`dns-direct` / `dns-proxy`），而旧脚本只在「带 `type` 字段的 `dns.servers[*]`」里认 DNS 上下文，
> `dns.rules` 条目没有 `type` → 它的 `server` 被当成节点主机名，统统替换成 `<node-server>`，
> 于是公开快照里 DNS 分流引用失真（是**错误**，不是泄漏）。修法：新增
> `is_dns_rule()`（同时含 `action`、且 `server` 是字符串 → 视为 DNS 规则），并把递归上下文改为
> `context in {"dns", "dns_server"} or is_dns_server(obj) or is_dns_rule(obj)`，遇到 `dns` /
> `default_domain_resolver` 键把子树上下文标成 DNS；另加两条**拒写断言**：逐条比对源与输出的
> `dns.rules[*].server`（不一致直接退出），以及 `dns` 段里出现 `<node-server>` 也退出。
> 本次快照已按真实 tag 还原：`must-direct`/`apple@cn`/`cn`+`lyc/cn` → `dns-direct`；
> `google`+`category-ai-!cn`、`geolocation-!cn`+`lyc/geolocation-!cn` → `dns-proxy`。

## 整体结构

| 段 | 内容 |
| --- | --- |
| `inbounds` | **eBPF**：`local`（cgroup 本机接管 + `bypass_rule_set` 让 CN IP 绕过）+ `shared`（`packet_rewrite` on `virbr0`，下游/VM 接管，实测直连与代理均通过）；另有 `mixed`（`127.0.0.1:7892`，给面板/命令行当代理口）+ `ebpf`（本地 cgroup 数据面、`dns_mode: hijack`、`bypass_private_address`、IPv6 开） |
| `dns` | 7 个 server：1 个 `hosts` 引导 + 4 个 DoH（2 个走代理、2 个走直连）+ **2 个 `group` 故障转移组** |
| `route` | 17 份规则集 + **11 条规则**（顺序即优先级，见下） |
| `experimental` | `cache_file`（`store_dns: true`）、`clash_api`（`127.0.0.1:9090`） |
| `services` | `api`（`127.0.0.1:9091`，官方 dashboard 与 `sing-box api` 命令都走它） |

## DNS 设计（这是整套配置的关键）

```
hosts-bootstrap   → 本地 hosts（用于引导解析 DoH 服务器域名本身）
dns-proxy-cf      → https://1.1.1.1/dns-query        【走代理】
dns-proxy-google  → https://8.8.8.8/dns-query        【走代理】
dns-direct-ali    → https://dns.alidns.com/dns-query 【走直连】
dns-direct-tencent→ https://doh.pub/dns-query        【走直连】
dns-proxy  = group[cf, google]      ← dns.final 指这里（国外域名）
dns-direct = group[ali, tencent]    ← 国内域名走这里
```

**要点**：DNS 也走 `route` 规则，所以"解析国内域名用国内 DoH、解析国外域名用代理侧 DoH"；
53 端口被 `hijack-dns` 全部接管（实测 `@8.8.8.8` / `@路由器` / `@223.5.5.5` 查广告域名全部拿不到结果，
出口回显是 Cloudflare 的地址 → 证明解析发生在代理侧）。

`type: group` 是**这个 fork 支持、上游 1.14 不支持**的特性，用来把闲置的备用 DNS 编成故障转移组。

### `dns.rules`：6 条（顺序即优先级）

| # | 命中 | 动作 | server |
| --- | --- | --- | --- |
| 1 | `must-direct` | `route` | `dns-direct` |
| 2 | 广告五表（同 `route` 第 5 条） | `predefined` + `NXDOMAIN` | —（不对上游发查询） |
| 3 | `geosite/apple@cn` | `route` | `dns-direct` |
| 4 | `geosite/cn` + `lyc/cn` | `route` | `dns-direct` |
| 5 | `geosite/google` + `geosite/category-ai-!cn` | `route` | `dns-proxy` |
| 6 | `geosite/geolocation-!cn` + `lyc/geolocation-!cn` | `route` | `dns-proxy` |

未命中任何一条时走 `dns.final = dns-proxy`。第 1 条是 **2026-10-08 才补上的**：`must-direct` 里的域名
（STUN / 游戏主机 / LAN cache / Steam 国服 CDN）若拿代理侧 DNS 解析，会出现"连接判直连、解析却绕道境外"
的错配，补上后两条判定一致。

## 规则集清单（17 份）

| 来源 | tag | 路径 |
| --- | --- | --- |
| **自建包**（随 pacman 更新） | `anti-AD` | `/usr/share/sing-box-rule-sets/anti-ad.srs` |
| | `geoip/cn-fresh` | `/usr/share/sing-box-rule-sets/geoip-cn-fresh.srs` |
| | `cncidr-mihomo` | `/usr/share/sing-box-rule-sets/cncidr-mihomo.srs` |
| | `must-direct` | `/usr/share/sing-box-rule-sets/must-direct.srs` |
| | `ads-extra` | `/usr/share/sing-box-rule-sets/ads-extra.srs` |
| | `adblockfilters` | `/usr/share/sing-box-rule-sets/adblockfilters.srs`（215248 条域名后缀，`--with-abf` 启用） |
| | `lyc/cn` | `/usr/share/sing-box-rule-sets/lyc-geosite-cn.srs`（2026-10-08 新增） |
| | `lyc/geolocation-!cn` | `/usr/share/sing-box-rule-sets/lyc-geosite-geolocation-!cn.srs`（2026-10-08 新增） |
| 官方 `sing-geosite/sing-geoip` 包 | `geosite/category-ads-all` `geosite/cn` `geosite/geolocation-!cn` `geosite/google` `geosite/category-ai-!cn` `geoip/cn` `geosite/apple@cn` | `/usr/share/sing-box/rule-set/…` |
| 手工放在 `/etc`（早期方案遗留） | `Ads_AWAvenue` | `/etc/sing-box/rule-set/AWAvenue-Ads-Rule.srs` |
| | `geoip/telegram` | `/etc/sing-box/rule-set/geoip-telegram.srs` |

| 自建包的八份 | 是什么 |
| --- | --- |
| `anti-ad.srs` | anti-AD 广告/追踪表（AdGuard 语法，构建时用 `sing-box rule-set convert -t adguard` 转） |
| `geoip/cn-fresh` | MetaCubeX 最新 `geoip/cn`（官方包那份实测**偏旧**：8045 条 vs 9648 条） |
| `cncidr-mihomo` | mihomo_yamls 的国内 IP 表（第三份独立来源，17958 条） |
| `must-direct` | 自制两类：① STUN / 游戏主机 / LAN cache / NCSI（走代理会坏功能）② **Steam 国服 CDN** 18 条（`st.dl.eccdnx.com`、`dl.steam.clngaa.com`、`csgo.com.cn`…，直连明显更快）；**刻意不含** `steamcontent.com`/`steamusercontent.com`/`cm.steampowered.com` 等全球域名（强制直连有风险）。2026-10-02 用 `sing-box rule-set decompile` 实测：`domain_suffix` 24 条 + `domain` 9 条，其中 Steam 国服相关 **正好 18 条** ✅ |
| `ads-extra` | 自制：`ad.duowan.com` / `sdkmob.com` / `ads.wps.cn`（anti-AD 漏掉的国内广告端点，只用精确域名） |
| `adblockfilters` | `217heidai/adblockfilters` 聚合广告表（215,248 条 `domain_suffix`，与 anti-AD 只重叠 35%）—— 详见下节 |
| `lyc-geosite-cn.srs` | lyc8503 的国内域名表（2026-10-08 加入；`refresh-rule-sets.sh` 里有对应源） |
| `lyc-geosite-geolocation-!cn.srs` | 同一来源的「非中国」域名表（与官方 `geolocation-!cn` 并联使用） |

**许可**：`geoip/cn-fresh` ← MetaCubeX/meta-rules-dat（GPL-3.0-or-later）；
`cncidr-mihomo` ← HenryChiao/mihomo_yamls（AGPL-3.0-or-later）；
`anti-AD` ← prprpi/anti-AD（上游未附许可证文件，个人使用）；其余自制。

## 另一个规则仓库的评估：[lingqiqi5211/sing-box-rules](https://github.com/lingqiqi5211/sing-box-rules)

定位：MIT、自用、**以 MetaCubeX `geo/full` 为基底**、多源合并去重、每天构建、sing-box 与 mihomo 双格式。
看起来正好能补"官方包偏旧"的短板，但逐个量下来**只有一项值得考虑**：

| 它提供 | 对比结果 | 结论 |
| --- | --- | --- |
| `geoip-cn.srs` | 81,593 B —— 与我们已经装的 mihomo `cncidr` **完全同样大小**（同一上游） | 冗余 |
| `geosite-cn.srs` | 111,224 条 vs 官方 8,702 条（**+105,409**） | **看着诱人，实则陷阱**（见下） |
| `geolocation-!cn` | 27,214 vs 官方 23,899（+14%） | 冗余：`route.final = Proxy`，外部域名本来就走代理 |
| `google-domain` | 885 vs 官方 938 | 冗余：漏掉的 Google 域名也会经 !cn/final 走代理 |
| `ai` | 222 条 vs 官方 181 条 | 在我列的 34 个 AI 服务域名上，**两边漏的是同一批 10 个** → 没有实际覆盖优势 |
| `steam-cn` | 22 条：`st.dl.eccdnx.com`、`dl.steam.clngaa.com`、`steamchina.com`… **Steam 国服（完美世界）下载 CDN** | **唯一有价值的一项** → ✅ **2026-10-02 已采纳 18 条**（见下） |

### 为什么"12 倍大的 CN 域名表"是陷阱

抽了 24 个"只有它收录、官方没有"的域名，看它们解析到哪：

- **14 个是国内 IP** → 我们已有的 `geoip/cn`（按 IP 判）**早就让它们直连了**，加域名表**没有任何变化**；
- 5 个是国外 IP（阿里云国际、Shopify 等）→ 加域名表会把它们**强制直连**，反而可能更慢；
- 5 个解析失败（域名已废）→ MetaCubeX 不剔除失效域名，官方包剔除。

结论：**不加**。这也说明"表越大越好"是错觉 —— 得看它和已有规则**是否真的产生不同的判定**。

### Steam 国服值得考虑（✅ 2026-10-02 已采纳）

~~现在配置里 Steam 全部走代理（实测 `steamstatic.com` / `api.steampowered.com` → Proxy，只有 `lancache.steamcontent.com` 在必须直连清单里）。
如果玩国服，把上述 22 个国内 CDN 域名加进 `must-direct`（或单独一份直连清单）会明显加快下载。
涉及不到 1 KB，随时可以加。~~

**已执行**：当天把上游 `steam-cn`（22 条）里**剔掉 4 个全球域名**后，**18 条**并入了
`must-direct`（`sing-box rule-set decompile /usr/share/sing-box-rule-sets/must-direct.srs` 实测：
Steam 国服相关条目正好 18 条），已随 `sing-box-rule-sets` 包生效（见上表 `must-direct` 行）。
所以"Steam 全部走代理"这句已经**不再成立**。

## 广告表的第二层：adblockfilters（2026-10-02 评估）

[`217heidai/adblockfilters`](https://github.com/217heidai/adblockfilters)（7.6k stars，GPL-3.0，**每 8 小时**更新）
是个聚合器：EasyList / EasyPrivacy / AdGuard Base+Chinese+Mobile+DNS / AdRules / OISD /
DNS-Blocklists PRO / StevenBlack / AWAvenue… 合并去重后，还会**先用 3+3 组 DNS 验证上游域名是否还有效**，
去掉失效的；并且**直接提供 sing-box 1.12+ 的 `.srs`**（不用自己转）。

实测评估（拿它的 JSON 版做精确 `domain_suffix` 匹配，`anti-AD` 用线上 `dig` 实测）：

| | 域名规则数 |
| --- | --- |
| anti-AD | 99,395 |
| adblockfilters | 215,248 |
| 两边都有 | 75,383（**只重叠 35%**） |
| 只有 adblockfilters 有 | **139,865** |
| 只有 anti-AD 有 | 24,012 |
| 并集 | 239,260（相对现在 **+141%**） |

- **不替换 anti-AD**：它独有的 24,012 条里有一批国内广告 SDK 域名（`anti-AD` 在这块更强）。
- **误伤检查**：27 个常用域名（google / github / baidu / bilibili / qq / taobao / zhihu / 微信 /
  apple / microsoft / steam / cloudflare / wikipedia / youtube / x / telegram / jd / 美团 / 抖音 /
  小米 / 华为 / 阿里云 / 头条 / 爱奇艺 / 优酷 / raw.githubusercontent / api.github）**0 命中**。
- **Lite 版不要用**：只有 5306 条（仅国内域名），实测在 26 个广告端点上只覆盖 3 个。
- 兼容性：`.srs` 用 `sing-box check` 实测可直接加载（1.14.2-reF1nd），`decompile` 出 215,248 条 `domain_suffix`。
- 代价：规则集文件 1.76 MB（anti-AD 是 0.77 MB），内存会多占一些 —— 值不值得看你怎么用。

启用（包已带上，配置里加一段）：

```bash
sudo ./scripts/apply-audit-fixes.sh --with-abf      # 会把它加进 dns 与 route 两条 reject 规则
```

## 路由规则顺序（11 条，顺序就是优先级）

| # | 规则 | 为什么在这个位置 |
| --- | --- | --- |
| 1 | `sniff` | 必须先嗅探，后面才能按域名分流 |
| 2 | `hijack-dns` | 53 端口全部交给 sing-box |
| 3 | `ip_is_private` → direct | 局域网/内网地址不走代理 |
| 4 | `must-direct` → direct | **必须放在广告拦截之前**：这些域名既不该被拦也不该走代理 |
| 5 | 广告五表 → `reject` | 连接层拦广告（浏览器自带 DoH 绕过 DNS 规则时靠这层兜底）。**2026-10-02 实测是 5 份**：`geosite/category-ads-all` + `Ads_AWAvenue` + `anti-AD` + `ads-extra` + `adblockfilters` |
| 6 | `geosite/google` + `category-ai-!cn` → Proxy | 明确要走代理的服务 |
| 7 | `geosite/apple@cn` → direct | 苹果国内服务直连（否则 App Store 下载会很慢） |
| 8 | `geosite/cn` + `lyc/cn` → direct | 国内域名（两份并联，2026-10-08 起） |
| 9 | `geosite/geolocation-!cn` + `lyc/geolocation-!cn` → Proxy | 其余国外域名（同上） |
| 10 | `geoip/telegram` → Proxy | Telegram 的 IP 段 |
| 11 | `geoip/cn` + `geoip/cn-fresh` + `cncidr-mihomo` → direct | **三份一起匹配**：任何一份认出来就直连（补官方表偏旧的漏） |

`route.final = Proxy`（兜底走代理）。

## DNS 侧的广告规则

```jsonc
{ "rule_set": ["geosite/category-ads-all", "Ads_AWAvenue", "anti-AD", "ads-extra", "adblockfilters"],
  "action": "predefined", "rcode": "NXDOMAIN" }
```

用 `predefined` + `NXDOMAIN` 而不是 `reject`，原因见
[《踩坑与经验》第 3 条](../docs/09-踩坑与经验.md)：`reject` 回 REFUSED，而 `systemd-resolved`
不把它转告客户端，应用每个广告域名要等约 5 秒；`NXDOMAIN` 是正常应答，**11 ms** 就失败。

## 2026-10-08 加固（已上线）

一轮完整审计（[10-审计报告-2026-10-08](../docs/10-审计报告-2026-10-08.md)）之后的落地改动，
全部由 `scripts/apply-hardening-2026-10-08.sh` 执行（备份 → `sing-box check` → 原子替换 →
健康检查 → 任一环节失败自动回滚）：

| # | 改动 | 为什么 |
| --- | --- | --- |
| 1 | `experimental.clash_api.secret` 与 `services[api].secret` 轮换为**各自独立**的 43 字符随机值 | 旧值只有 11 字符、是**可猜的单词**，且两个控制面共用同一个密钥 |
| 2 | `access_control_allow_origin`：`["*"]` → `["http://127.0.0.1:9096","http://localhost:9096"]`，并删掉 `access_control_allow_private_network` | 实测 9090 对任意 Origin（含 `https://evil.example`）都回 `Access-Control-Allow-Origin: *`，配合 private-network 放行，任意网页都能跨域读写本机代理控制面 |
| 3 | 删除未被引用的出站 `{type: block, tag: block}` | 连接层拦截已由 `route` 第 5 条的 `action: reject` 承担；这个出站全文只出现在它自己的声明里 |
| 4 | `Download` 组默认节点由 `Auto` 改为「🇯🇵 日本Z05｜下载专用」，并把该节点从 `Auto`（11→10）与 `Auto-Japan`（5→4）的 urltest 候选里剔除 | 该节点标称"下载专用"，不该参与日常自动选优（它曾经死掉还占着默认位置） |
| 5 | 备份加固：`/etc/sing-box/backups/` → 700、`config.json.bak.*` → 600；每个目录保留最新 10 份 + 7 天内的不归档，超出部分 `tar.gz` 归档（**不直接删**） | 那 23 份备份是**完整配置副本**（含全部节点口令与控制面密钥），原来 644 → 本机任意用户可读 |
| 6 | 新增 drop-in `/etc/systemd/system/sing-box.service.d/20-network-online.conf`（`Wants=network-online.target`） | 原 unit 只有 `After=` 没有 `Wants=`，开机早期会报 `network: missing default interface` |

有意**不动**的：版本（与上游 v1.14.2 已持平）、`cache_file` 与双控制面（9090 Clash API + 9091 services api）、
`route.find_process`（保持 `false`，没有 process 匹配规则）、`dns.rules` 的结构。

> 待确认的一项：`chmod 600 /var/lib/sing-box/cache.db`（当前 644，本地可读 DNS 查询历史）。
> 加固脚本带开关 `--harden-cache-db`，默认关闭。

## 变更记录（都是脚本自动备份出来的）

备份在 `/etc/sing-box/backups/`，命名带语义：

```
config.<时间戳>.pre-audit.json       审计修复前
config.<时间戳>.pre-ebpf.json        切 eBPF 前（= TUN 配置，切回来时用它取 TUN 定义）
config.<时间戳>.pre-dataplane.json   改数据面前
config.<时间戳>.pre-tun.json         切回 TUN 前
config.json.bak.<时间戳>             2026-10-08 加固前的原样副本（install -m 600 生成）
```

2026-10-08 的回滚（一层就够，脚本健康检查失败时也是这么干的）：

```bash
sudo install -m 600 -o root -g root /etc/sing-box/config.json.bak.<时间戳> /etc/sing-box/config.json
sudo systemctl restart sing-box && systemctl is-active sing-box && ss -ltn | grep -E '7892|9090|9091'
# 只撤开机等待网络的 drop-in：
sudo rm /etc/systemd/system/sing-box.service.d/20-network-online.conf && sudo systemctl daemon-reload
```

回滚永远是一条命令：

```bash
sudo cp -a /etc/sing-box/backups/<选定的那份> /etc/sing-box/config.json
sudo systemctl restart sing-box
```
