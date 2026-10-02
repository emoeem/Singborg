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
| `apply-audit-fixes.sh` | 审计修复：补 anti-AD 广告表、刷新 geoip/cn、清理冗余规则与 `dns-local`。6 个可选开关见下 | ✅ |
| `switch-to-ebpf.sh` | TUN → eBPF。可选 `--data-plane cgroup\|tc`、`--shared <接口>`；`--force` 越过 TC 守卫 | ✅ |
| `switch-to-tun.sh` | eBPF → TUN（TUN 用 `auto_route` 覆盖转发流量，**容器/虚拟机也能被代理**）。TUN 定义取自最近的 `pre-backup` | ✅ |
| `enable-container-proxy.sh` | 在 podman 网桥上开 eBPF `shared` 数据面，让 rootful 容器也走代理；`--disable` 关闭 | ✅ |
| `install-singbox.sh` | 安装/迁移 sing-box 到本机（最早的引导脚本） | ✅ |
| `switch-to-local-rules.sh` | 早期方案：把规则集切成本地文件（不依赖运行期远程下载） | ✅ |
| `apply-emoeem-mirrors.sh` | 配置自建 Arch 仓库的镜像（`[emoeem]` 段） | ✅ |

## `apply-audit-fixes.sh` 的开关

```bash
sudo ./apply-audit-fixes.sh \
  --with-extra-ads       # 补 3 个国内广告端点（精确域名，不动 apex）
  --with-cncidr          # 加 mihomo 国内 IP 表（第三份来源）
  --with-direct-list     # STUN / 游戏主机 / LAN cache / NCSI 强制直连
  --with-dns-groups      # 把闲置的备用 DNS 编成故障转移组（fork 支持 type=group）
  --use-package-paths    # 规则集改指 /usr/share/sing-box-rule-sets（随 pacman 更新）
  --nxdomain-ads         # DNS 广告拦截从 reject(REFUSED) 改成 predefined(NXDOMAIN)
```

不带开关 = 只做基础修复（补广告表 + 刷新 geoip/cn + 清理冗余规则）。

## 健康判据（两种模式不一样）

| 模式 | 判据 |
| --- | --- |
| TUN | `tun0` 出现 + **不设代理的出口 == 经本地代理口的出口** + 国内直连 + DNS 广告被拦 |
| eBPF | **没有 `tun0`**，所以只看：`sing-box api ebpf` 有活动入站 + 不设代理的出口 == 代理出口 + 国内直连 + DNS 广告被拦 |

DNS 那项一律用**随机子域**（`<hex>.doubleclick.net`）并问一个对照域名 ——
否则 `systemd-resolved` 的缓存会把"没生效"伪造成"生效"（我第一次切 eBPF 就是这么被骗着回滚的）。

## 注意

- 这套脚本在 [`emoeem/toolbox-hub`](https://github.com/emoeem/toolbox-hub) 里也有一份
  （多了注解头与自提权前导，用来当 TUI 动作）。两边的**业务逻辑应当保持一致**，改的时候一起改。
- `switch-to-ebpf.sh --data-plane tc` 在本机**一定会失败**：内核不支持 TC 路径的 eBPF
  （`register TC eBPF TCP listener: operation not supported`）。脚本会在 `--mode all` 预检不通过时
  提前拦住，别加 `--force` 白试。
