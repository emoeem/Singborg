# eBPF 试跑（A/B，可回滚）

> **结果（2026-10-02 补记）**：试跑通过 —— eBPF 能接管本机流量（判据：不设代理的出口 == 代理出口），
> DNS 劫持与 IPv6 也正常。**但后来发现本机内核不支持 TC 路径**（`tc` 数据面与 `shared` 都不可用），
> 所以 eBPF 模式下容器/虚拟机覆盖不到；最终选择回到 TUN。过程与取舍见
> [`docs/09-踩坑与经验.md`](../docs/09-踩坑与经验.md) 与 [`docs/01-审计报告`](../docs/01-审计报告-2026-10-02.md) §11–§12。

预检已通过（`preflight_passed`，51 PASS / 0 fail，见 `../docs/02-eBPF可行性验证.md` §3.1）。
这一包东西用来回答最后一个问题：**换成 eBPF 后，你那套已经审计过的行为还在不在。**

## 怎么用

```bash
cd <本仓库>/trial
sudo ./run-ebpf-trial.sh                     # 只接管本机流量
sudo SHARED_IFACE=virbr0 ./run-ebpf-trial.sh # 顺带接管 libvirt 虚拟机
```

脚本做的事（**只停/起服务，不改任何配置文件和开机项**）：

1. 从 `/etc/sing-box/config.json` 现生成试跑配置到 `/tmp`：删掉 `tun-in`、加上 `ebpf-in`
   （`local: cgroup` + `dns_mode: hijack` + `bypass_private_address` + `ipv6`；给了 `SHARED_IFACE` 才开 shared）。
2. 用 root 跑 `sing-box check`（**eBPF 入站的 check 会真的建 map**，非 root 必定失败，这是权限不是配置）。
3. 在 **TUN 模式**下先打一遍分（基线）。
4. `systemctl stop sing-box` → 前台起 eBPF 核心（日志 `/tmp/sing-box-ebpf-trial.log`）→ 等 `sing-box started`.
5. 同一套判据再打一遍分，并 `diff` 两轮结果。
6. **无论成功、失败、Ctrl-C，退出时都会把系统 `sing-box`（TUN）拉回来**。

## 打分判据（沿用 `singbox-network-audit.md`）

| 判据 | 期望 |
|---|---|
| `direct_isp_ip` | 你的电信 IP（国内直连） |
| `proxy_exit_ip` | 代理节点出口 IP |
| `ipv6_http_code` | `200`（eBPF 下由 `local.ipv6` 接管） |
| `ipv6_blackhole` | `0`（不该再有 `unreachable` 黑洞规则） |
| `ads_dns_answer` | 空（DNS 层广告拦截仍生效） |
| `resolve_github` | `ok` |
| `tun0_state` | eBPF 模式下应为 `absent`（不再有 TUN 设备） |

结果落在 `/tmp/sing-box-ebpf-trial-result.<时间戳>.txt`。

## 试跑过了之后再谈什么

- **要长期用** → 先打包（`~/pkgbuild-source` 加 `packages/sing-box-ebpf/`），再改 systemd 单元
  （补 `CAP_BPF CAP_PERFMON`，或直接 root 跑；见报告 §5.2），并保留 pacman 级回滚（`pacman -S sing-box`）。
- **只是尝鲜** → 跑一次看完 diff 就结束，什么都不用改。

## v2 修复（第一次试跑踩的坑，已解决）

第一次试跑暴露出**脚本自身**两个问题，与 sing-box/你的配置无关：

1. **`-D /var/lib/sing-box` 与服务共用 `cache.db`**：试跑的 `cache_file.path` 指向服务自己的缓存文件；
   而该文件此前被**非 root 的 `sing-box check`**（我为了验证配置跑的）重建过，属主变成了 `emo:emo`。
   服务用户是 `sing-box` → 重新启动时 `FATAL: initialize cache-file: permission denied` → 崩溃重启循环。
   **v2 已改为独立状态目录 `/tmp/sing-box-ebpf-trial-state` 与独立 `cache.db`，并在开跑前自动纠正线上 cache.db 属主。**

   > 如果你在别的场合也踩到这个（服务起不来说 `permission denied`），一条命令修：
   > ```bash
   > sudo chown sing-box:sing-box /var/lib/sing-box/cache.db && sudo systemctl restart sing-box
   > ```
   > （`cache.db` 只是缓存，直接 `sudo rm -f` 掉也会自动重建。）

2. **恢复逻辑太急**：`systemctl start` 后只等 2s 就判定失败，撞上 `RestartSec=10s` 的重启退避窗口。
   **v2 改为**：先等端口 7892 释放 → `systemctl restart` → 轮询 `is-active` 最多 30s → 再验 `tun0` 是否回来。

另外打分函数也修了：广告 DNS 判据改为 `dig @1.1.1.1`（**绕开 systemd-resolved 自己的缓存**），
并在每轮打分前 `resolvectl flush-caches`——否则切换模式后可能读到上一轮的缓存答案，得出错误结论。

## 注意

- 试跑期间**只有一个**透明代理在跑（脚本先停旧的），不会两个同时开。
- 若 eBPF 核心起不来，脚本会打印日志尾部并立即恢复——**网络最多中断几秒**。
- 别把 `local.cgroup_path` 写成你终端所在的 scope（预检里那条 `kitty-…scope` 只是探测进程自己的位置）；
  留空 = 挂 cgroup v2 根层级 = 全局接管。
