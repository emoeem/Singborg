# `pacman -Syy` 大面积失败：诊断与修复

> 结论：**是 daed（`daed-emo` 1.27.0.r19.gb3043aa）的 DNS 劫持链路在失败**，不是镜像源、也不是 IPv6 单独造成的。
> 你新配的 emoeem 多代理**是好的** —— 本次 `emoeem 4.0 KiB 100%` 已成功下载。

## 1. 证据链

| 观测 | 数据 | 含义 |
|---|---|---|
| daed 服务 | `active (running)`，PID 1344，`/usr/bin/daed run -c /etc/daed/` | 透明代理在运行 |
| eBPF 钩子 | `wlan0 ingress/egress` 挂 `daed_wan_ingress_l2` / `daed_wan_egress_l2`；`dae0`（netkit L3，netns `daens`） | dae 在网络层拦截所有流量 |
| DNS 被劫持 | 日志中 `dst="192.168.31.1:53"` 19 次、`dst="[fd00:6868:6868::1]:53"` 17 次 | 连**路由器 DNS** 都被 dae 接管 |
| DNS 直接失败 | `DNS ingress fast path failed; sending SERVFAIL response`（36 次/约 1 分钟） | 客户端收到 SERVFAIL → `Could not resolve host` |
| 根因 | `bootstrap resolver returned no usable address for "<节点域名>"`（**183 次**） | dae 解析不了代理节点域名 |
| 节点不可达 | `[StickyIP] All proxy IPs failed`（95 次）、`dial ... i/o timeout` | 节点拨号超时 → 上游全挂 |
| 抖动实测 | 连续 10 次 `curl -4 https://mirror.krfoss.org/` → **7 成功 / 3 失败** | 间歇性失败，符合拦截层丢弃/回绝 |
| 本地立即失败 | `curl -6 ... total=0.000004s code=000` | 被本地组件瞬时回绝，而非网络慢 |
| 版本来源 | `daed-emo 1.27.0.r19.gb3043aa`，打包者 `Unknown Packager`，URL 指向 daeuniverse/daed | 这是**第三方打包**的变体（来自 emoeem 仓库），非官方二进制 |

### 为什么症状看起来是"TLS 错误"

1. pacman → DNS 查询被 dae 拦下；
2. dae 要把查询转发到 `tcp+udp://8.8.8.8:53`，但**经代理节点转发**（`outbound=proxy`）；
3. 节点域名的 bootstrap 解析失败 / 节点拨号超时；
4. dae 回 `SERVFAIL` → pacman 报 `Resolving timed out` / `Could not resolve host`；
5. 已建连的会话在等待上游时被打断 → OpenSSL 报 `unexpected eof while reading`。

`Group re-selects dialer ... min_moving_avg=1.94s→2.498s` 显示 daed 正在节点之间反复抖动，说明**当前订阅节点大面积不可用**。

## 2. 立刻验证（决定性实验）

```bash
sudo systemctl stop daed     # 临时停掉
sudo pacman -Syy             # 若全部变绿 → 100% 确认是 daed
sudo systemctl start daed    # 验证完再启回来
```

应急时也可以用这个办法先把系统更新做完。

## 3. 修复 daed 侧（根因）

在 daed 面板（`http://127.0.0.1:2023`）按顺序检查：

1. **DNS 上游不要走代理**：把 DNS upstream 从 `8.8.8.8`（当前经代理转发）改成国内可直连的
   `223.5.5.5` / `119.29.29.29`，并设为 **direct / 直连**；顺带配置 **bootstrap resolver 为直连 IP**，
   避免"解析节点域名又依赖节点"的循环。
2. **刷新/更换订阅**：183 次节点域名解析失败 + 95 次拨号超时说明节点大面积失效，更新订阅或换机场。
3. **换掉 `daed-emo`**：它是 emoeem 仓库里的第三方打包变体（`Unknown Packager`），
   与上游 `daed` 行为可能有差异。可换官方发布版对比，能立刻排除"打包/版本 bug"。
4. **让系统别用被劫持的 DNS**（减少影响面）：

   ```bash
   nmcli con mod ChinaNet-14D8_5G ipv4.ignore-auto-dns yes ipv4.dns 223.5.5.5
   nmcli con mod ChinaNet-14D8_5G ipv6.ignore-auto-dns yes
   nmcli con up ChinaNet-14D8_5G
   ```

## 4. 顺带修 IPv6（独立问题，会叠加放大故障）

`wlan0` 只有 ULA `fd00:6868:6868::/64` + 一条 RA 默认路由，**没有可用全局 IPv6**；
而 IPv6 DNS `fd00:6868:6868::1` 响应要 **1261 ms**（IPv4 路由器 DNS 仅 11 ms），
但 AAAA 记录让程序优先走 IPv6。二选一：

```bash
# 方案 A：全局让 glibc 优先 IPv4（推荐，最省事）
echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf

# 方案 B：直接关掉这张卡的 IPv6
nmcli con mod ChinaNet-14D8_5G ipv6.method disabled && nmcli con up ChinaNet-14D8_5G
```

## 5. pacman 侧加固（抗抖动，可选）

`/etc/pacman.conf` 里启用带重试的下载器：

```ini
XferCommand = /usr/bin/curl -4 --retry 3 --retry-delay 2 --connect-timeout 10 -L -C - -f -o %o %u
```

再配合已有的 emoeem 多代理段，单点故障就不会让 `-Syy` 整片报错。
