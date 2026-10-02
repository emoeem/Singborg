# 配置记录

## `config.sanitized.json` 是什么

本机 `/etc/sing-box/config.json` 在 **2026-10-02 收尾时**的快照，作用是**看懂结构**：

- 保留：`inbounds` / `outbounds` 的结构与协议字段 / `dns` / `route` / `experimental`，
  以及每个 `rule_set` 的 `path`（**路径本身是最有信息量的部分**：一眼看出哪几份是自建的）；
- 换掉：代理节点的 `server` → `<node-server>`、`server_port` → `0`、`password`/`uuid`/`sni`/`host`
  → 占位符；两处 `secret`（`clash_api` 与 `services[api]`）→ `<clash-api-secret>`；
- **没有**换掉：DNS 的公共 DoH 端点（`1.1.1.1` / `8.8.8.8` / `dns.alidns.com` / `doh.pub`）——
  那是公共设施，也是配置里最重要的思路之一。

> 生成脚本是「结构化脱敏」而不是「按键名替换」：`server` 这个键名同时出现在代理节点（要脱）
> 和 DNS 服务器（不该脱）里，按键名替换会把两者一起打掉。生成后有自检断言。

## 整体结构

| 段 | 内容 |
| --- | --- |
| `inbounds` | `mixed`（`127.0.0.1:7892`，给面板/命令行当代理口）+ `ebpf`（本地 cgroup 数据面、`dns_mode: hijack`、`bypass_private_address`、IPv6 开） |
| `dns` | 7 个 server：1 个 `hosts` 引导 + 4 个 DoH（2 个走代理、2 个走直连）+ **2 个 `group` 故障转移组** |
| `route` | 14 份规则集 + **11 条规则**（顺序即优先级，见下） |
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

## 规则集清单（14 份）

| 来源 | tag | 路径 |
| --- | --- | --- |
| **自建包**（随 pacman 更新） | `anti-AD` | `/usr/share/sing-box-rule-sets/anti-ad.srs` |
| | `geoip/cn-fresh` | `/usr/share/sing-box-rule-sets/geoip-cn-fresh.srs` |
| | `cncidr-mihomo` | `/usr/share/sing-box-rule-sets/cncidr-mihomo.srs` |
| | `must-direct` | `/usr/share/sing-box-rule-sets/must-direct.srs` |
| | `ads-extra` | `/usr/share/sing-box-rule-sets/ads-extra.srs` |
| 官方 `sing-geosite/sing-geoip` 包 | `geosite/category-ads-all` `geosite/cn` `geosite/geolocation-!cn` `geosite/google` `geosite/category-ai-!cn` `geoip/cn` `geosite/apple@cn` | `/usr/share/sing-box/rule-set/…` |
| 手工放在 `/etc`（早期方案遗留） | `Ads_AWAvenue` | `/etc/sing-box/rule-set/AWAvenue-Ads-Rule.srs` |
| | `geoip/telegram` | `/etc/sing-box/rule-set/geoip-telegram.srs` |

| 自建的四份 | 是什么 |
| --- | --- |
| `anti-ad.srs` | anti-AD 广告/追踪表（AdGuard 语法，构建时用 `sing-box rule-set convert -t adguard` 转） |
| `geoip/cn-fresh` | MetaCubeX 最新 `geoip/cn`（官方包那份实测**偏旧**：8045 条 vs 9648 条） |
| `cncidr-mihomo` | mihomo_yamls 的国内 IP 表（第三份独立来源，17958 条） |
| `must-direct` | 自制：STUN / 游戏主机 / LAN cache / NCSI（**走代理会坏功能**：NAT 类型、Steam 局域网缓存） |
| `ads-extra` | 自制：`ad.duowan.com` / `sdkmob.com` / `ads.wps.cn`（anti-AD 漏掉的国内广告端点，只用精确域名） |

**许可**：`geoip/cn-fresh` ← MetaCubeX/meta-rules-dat（GPL-3.0-or-later）；
`cncidr-mihomo` ← HenryChiao/mihomo_yamls（AGPL-3.0-or-later）；
`anti-AD` ← prprpi/anti-AD（上游未附许可证文件，个人使用）；其余自制。

## 路由规则顺序（11 条，顺序就是优先级）

| # | 规则 | 为什么在这个位置 |
| --- | --- | --- |
| 1 | `sniff` | 必须先嗅探，后面才能按域名分流 |
| 2 | `hijack-dns` | 53 端口全部交给 sing-box |
| 3 | `ip_is_private` → direct | 局域网/内网地址不走代理 |
| 4 | `must-direct` → direct | **必须放在广告拦截之前**：这些域名既不该被拦也不该走代理 |
| 5 | 广告四表 → `reject` | 连接层拦广告（浏览器自带 DoH 绕过 DNS 规则时靠这层兜底） |
| 6 | `geosite/google` + `category-ai-!cn` → Proxy | 明确要走代理的服务 |
| 7 | `geosite/apple@cn` → direct | 苹果国内服务直连（否则 App Store 下载会很慢） |
| 8 | `geosite/cn` → direct | 国内域名 |
| 9 | `geosite/geolocation-!cn` → Proxy | 其余国外域名 |
| 10 | `geoip/telegram` → Proxy | Telegram 的 IP 段 |
| 11 | `geoip/cn` + `geoip/cn-fresh` + `cncidr-mihomo` → direct | **三份一起匹配**：任何一份认出来就直连（补官方表偏旧的漏） |

`route.final = Proxy`（兜底走代理）。

## DNS 侧的广告规则

```jsonc
{ "rule_set": ["geosite/category-ads-all", "Ads_AWAvenue", "anti-AD", "ads-extra"],
  "action": "predefined", "rcode": "NXDOMAIN" }
```

用 `predefined` + `NXDOMAIN` 而不是 `reject`，原因见
[《踩坑与经验》第 3 条](../docs/09-踩坑与经验.md)：`reject` 回 REFUSED，而 `systemd-resolved`
不把它转告客户端，应用每个广告域名要等约 5 秒；`NXDOMAIN` 是正常应答，**11 ms** 就失败。

## 变更记录（都是脚本自动备份出来的）

备份在 `/etc/sing-box/backups/`，命名带语义：

```
config.<时间戳>.pre-audit.json       审计修复前
config.<时间戳>.pre-ebpf.json        切 eBPF 前（= TUN 配置，切回来时用它取 TUN 定义）
config.<时间戳>.pre-dataplane.json   改数据面前
config.<时间戳>.pre-tun.json         切回 TUN 前
```

回滚永远是一条命令：

```bash
sudo cp -a /etc/sing-box/backups/<选定的那份> /etc/sing-box/config.json
sudo systemctl restart sing-box
```
