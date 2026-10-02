# 从 daed 迁移：选型结论 + 落地方案（CachyOS / 单 wlan0 / 机场订阅）

## 0. 一句话结论

> **功能最全 + 性能最强的活跃内核 = `sing-box`。**
> 你手上那份 436 行配置本来就是按它的最优实践写的（`.srs` 二进制规则集、DoH、`prefer_ipv4`），
> 我已用真二进制（sing-box 1.14.2，与 `cachyos-extra-v3` 版本一致）校验通过，并额外生成了一份
> 带 TUN 入站的性能取向版本，随时可用。

## 1. 内核对比（功能 + 性能）

| 维度 | **sing-box** | mihomo (Clash.Meta) | Xray-core (+v2rayA) |
|---|---|---|---|
| 协议原生度 | **最全**：SS2022 / VMess / VLESS / Trojan / **Hysteria2 / TUIC v5 / ShadowTLS / Reality / WireGuard** 均原生 | SS/VMess/VLESS/Trojan/Reality 稳；Hysteria2、TUIC、WireGuard 标注**实验性** | VLESS+Reality/XTLS 实现方，协议性能最强 |
| 吞吐（同协议基准） | **高约 10–20%** | 基准 | 极高（Reality 场景） |
| 内存占用 | **约 40–80 MB** | 约 80–150 MB | 约 60–120 MB |
| DNS 模块 | **最现代**：独立 `dns.rules`、原生 DoT/DoH/**DoQ**、FakeDNS | Fake-IP + Redir-Host，成熟但基于 Clash legacy（无 DoQ） | 依赖前端 |
| 规则生态 | `.srs` 二进制规则集，MetaCubeX 规则可直接用 | **最丰富**：ACL4SSR / Loyalsoldier / 数百 YAML rule-provider | geosite/geoip |
| 全局接管方式 | TUN / redirect / tproxy 三种 | TUN / tproxy / redir | 无内置，需 v2rayA |
| 面板生态 | 官方文档为主，中文教程偏少 | **最多**：metacubexd / zashboard / yacd | v2rayA Web UI |
| 订阅格式 | JSON（Clash YAML 不能直接用） | **Clash YAML 原生直用** | V2Ray/JSON |
| 上游状态 | 活跃，v1.14.x | 活跃，v1.19.x，另引入 **Smart 自适应选路** | 活跃 |

性能数据的来源是第三方内核对比评测（[sing-box vs Mihomo 内核对比](https://www.chonglangbiji.com/protocols/sing-box-vs-mihomo-kernel-performance-memory-protocol-may-2026/)、[Mihomo vs Sing-Box 选型](https://www.chonglangbiji.com/compare/mihomo-vs-sing-box/)），**外部数据、未经我复现**，仅供参考。
另外同一批资料里也自相矛盾（把 mihomo 的主语言写成 Python，实际是 Go），所以别把数字当精确值。

**关键判断**：你的 11 个节点全是 **Shadowsocks**，瓶颈在机场出口带宽，内核差异（<20%）在家用宽带上基本感知不到。
所以"性能最强"这件事上真正拉开差距的，是下面第 4 节的几项调优，而不是选谁。

### 为什么不是别的

- **mihomo**：如果你更看重生态（Clash YAML 订阅直接用、规则集最多、面板最多）就选它 —— 但要在内存、吞吐、
  以及 Hysteria2/TUIC 稳定性上让步。**它不是"功能/性能最强"，而是"生态最强"。**
- **Xray-core**：只有当你订阅是 VLESS+Reality 且要榨干协议性能时才值得，代价是路由/TUN 得靠 v2rayA 补。
- **dae（现状）**：eBPF 进内核分流，**性能天花板其实最高**（无 TUN 拷贝），但它正是被放弃的那个 ——
  而且我们已经实测到它把 DNS 和 IPv6 TCP 都弄坏了。

## 2. 现状盘点

| 项目 | 状态 |
|---|---|
| 当前代理 | `daed-emo 1.27.0.r19.gb3043aa-1`（emoeem 仓库，`Unknown Packager`） |
| 发行版官方包 | `archlinuxcn/daed **2.1.1-1**` —— 比你现在这个**新一个大版本** |
| 已装未用 | `flclash 0.8.96-1`（无配置目录、无 TUN 设备，从未启动） |
| 现成资产 | `~/.config/sing-box/config.json`（436 行）：18 出站（11 SS + 4 selector + 1 urltest）、DNS `prefer_ipv4`、route 11 规则 + 2 组 `.srs` 二进制规则集、DoH 上游 |
| 唯一缺口 | **没有 TUN 入站**，只有 `mixed:7892` / `socks:7893` → 只能当本地代理，不能全局接管 |
| TUN 可用性 | 宿主机内核 `7.2.8-1-cachyos-bore-lto`，`tun.ko.zst` 在 `/lib/modules/`，按需加载 ✅ |

### 一个更正（我先前说错了）

我最初以为 `config.json` 第 331/341 行的**尾随逗号**会让 sing-box 起不来 —— **这是错的**。
实测：sing-box 自带的宽松 JSON 解码器**容忍尾随逗号**（原始未修改的文件直接 `check` 通过）；
只有标准 JSON 工具（`jq`、Python `json`）会拒绝。所以：

- 尾随逗号**不是**它没被用起来的原因；真正原因是 **`sing-box` 二进制从来没装**（配置 9 月 21 日生成后原封未动）。
- 但仍建议清掉，否则编辑器、`jq`、订阅转换脚本会报错。

## 3. 迁移前必做：清掉 dae 的 eBPF 残留 ⚠️

dae 靠 `tc clsact` + eBPF 挂在网卡上（`wlan0` 上现有 `daed_wan_ingress_l2` / `daed_wan_egress_l2`）。
**只删包不停服务，钩子会残留，换任何客户端都会继续坏网。**

```bash
sudo systemctl stop daed && sudo systemctl disable daed
sudo pacman -Rns daed-emo

tc filter show dev wlan0 ingress | grep daed      # 确认残留
tc filter show dev wlan0 egress  | grep daed
sudo tc qdisc del dev wlan0 clsact                # 有残留才清（会移除 wlan0 上所有 clsact 规则）

ip -brief link show dae0 2>/dev/null && sudo ip link del dae0
ip netns list                                     # 看 daens 是否残留

sudo systemctl restart systemd-resolved
resolvectl query github.com                       # 应立刻返回
```

验证：连续 10 次 `curl -4 -s -o /dev/null -w '%{http_code}\n' https://mirror.krfoss.org/` 全绿。

## 4. 落地：sing-box（已为你准备好文件）

### 4.1 我已放好的东西

| 路径 | 说明 |
|---|---|
| `~/.config/sing-box/config.json` | **你的原文件，我没动**（md5 `2dfb01a9fc10f90135747f38b18c2f2b`） |
| `~/.config/sing-box/config.tun-perf.json` | 我生成的性能取向版本：**已加 TUN + `stack: system` + `tcp_fast_open: true`**，已用真二进制 `sing-box check` 通过 ✅ |
| `~/.cache/sing-box-bin/sing-box` | 校验用的 1.14.2 静态二进制，以后不装包也能 `check` 配置 |

### 4.2 装包与启用（需要你在终端跑 sudo）

```bash
sudo pacman -S sing-box
sudo mkdir -p /etc/sing-box /var/lib/sing-box
sudo cp ~/.config/sing-box/config.tun-perf.json /etc/sing-box/config.json
# cache_file 路径改到 /var/lib/sing-box/cache.db（服务以 root 跑）
sudo sed -i 's#/home/emo/.cache/sing-box/cache.db#/var/lib/sing-box/cache.db#' /etc/sing-box/config.json
~/.cache/sing-box-bin/sing-box check -c /etc/sing-box/config.json   # 复核
```

```ini
# /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
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
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now sing-box
resolvectl query github.com
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com
```

### 4.3 那几项真正影响性能的设置（我都已验证可用）

| 设置 | 取值 | 作用 |
|---|---|---|
| TUN `stack` | **`system`** | 走内核 TCP/IP 栈，吞吐最高；`gvisor` 最兼容但最慢，`mixed` 折中 |
| 出站 `tcp_fast_open` | `true` | 建连少一个 RTT（`sing-box check` 接受 ✅） |
| `rule_set.format` | **`binary`（你已在用）** | `.srs` 二进制匹配远快于文本 geosite |
| `experimental.cache_file` | 已启用 | 规则/节点缓存，启动快、内存稳 |
| 入站 | 只留 TUN | 全局接管后 `mixed`/`socks` 是多余暴露面 |
| `dns.strategy` | `prefer_ipv4`（你已有） | 你这条线路 IPv6 只有 ULA、无全局出口，必须偏 IPv4 |

### 4.4 最省事的过渡方案（不装 TUN、不要 root）

你配置里的 `mixed` 监听 `127.0.0.1:7892`，普通用户前台跑起来即可让 pacman 走它：

```ini
# /etc/pacman.conf
XferCommand = /usr/bin/curl -4 -x http://127.0.0.1:7892 --retry 3 --retry-delay 2 -L -C - -f -o %o %u
```

## 5. 三条铁律

1. **永远不要同时开两个透明代理**（daed + FlClash/sing-box 同时 TUN = 之前那种 DNS/TLS 全乱的局面）。
2. **换客户端前先确认 dae 的 `tc` 钩子已清干净**（第 3 节）。
3. **DNS 一律偏 IPv4**：这条线路 IPv6 只有 ULA、没有全局出口，任何 `prefer_ipv6` 都会拖垮体验。
