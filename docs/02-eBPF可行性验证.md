# sing-box 能不能用 eBPF（本机 CachyOS 现状实测）

结论时间：2026-10-02　方法：全部为本机真实二进制 / 真实内核实测，不是推断。
对象：你正在跑的 sing-box 1.14.2（`/etc/sing-box/config.json`，`mixed-in` + `tun-in`）。

## 0. 一句话结论

> **你现在装的 sing-box 用不了 eBPF；不是配置问题，是二进制里没有这个入站。**
> eBPF 入站是 **`reF1nd/sing-box` 分支的实验特性**（编译标签 `with_ebpf`，仅 Linux / Android），
> **上游 `SagerNet/sing-box` 没有这个功能**。Android 上的 NetProxy 模块正是内置了这个分支内核。
>
> 你这台机器的**内核完全够用**——我已经现场编译出带 `with_ebpf` 的 Linux 版二进制，
> 它能直接读你现有的 `/etc/sing-box` 配置（`check` exit=0），并对本机跑了内核能力预检。
>
> **而且不必用 alpha**：分支在 stable 基线 `v1.14.2-reF1nd`（与你现装的 1.14.2 同基线）上同样带
> eBPF，我也编好并验证过了（`check -C /etc/sing-box` exit=0，且没有 1.15 的 `tun.stack` 弃用告警）。

| 目标 | 能否用 eBPF | 依据 |
|---|---|---|
| 本机现装的 sing-box 1.14.2（Arch 包） | ❌ **不能** | 实测 `FATAL: unknown inbound type: ebpf`（exit=1） |
| 本机换用 reF1nd 分支二进制 | ✅ **可以**（内核已具备，二进制已为你编好） | 见第 4、5 节 |
| Android + NetProxy 模块 | ✅ 设计如此（eBPF 是**唯一**数据面） | 模块无 TPROXY / REDIRECT 回退，内核不行就起不来 |

## 1. 为什么现在的二进制不行（实测）

```console
$ cat > /tmp/ebpf-test.json   # 官方样例的 ebpf 入站
$ sing-box check -c /tmp/ebpf-test.json
FATAL[0000] decode config at /tmp/ebpf-test.json: inbounds[0]: unknown inbound type: ebpf
exit=1
```

现装二进制的编译标签里没有 `with_ebpf`：

```
Tags: with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,
      with_tailscale,with_ccm,with_ocm,with_cloudflared,with_naive_outbound,with_usbip,
      with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0
```

## 2. eBPF 入站到底是谁的功能

| 项目 | 情况 |
|---|---|
| 上游 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | ❌ 没有：`docs/configuration/inbound/` 下无 `ebpf.md`（404），入站列表只有 `tun / redirect / tproxy / mixed / socks / http …` |
| [`reF1nd/sing-box`](https://github.com/reF1nd/sing-box)（分支 `reF1nd-testing`） | ✅ 有：[eBPF 入站文档](https://raw.githubusercontent.com/reF1nd/sing-box/reF1nd-testing/docs/configuration/inbound/ebpf.zh.md)，标注"sing-box 1.15.0 中的更改 / 实验功能"，`//go:build with_ebpf && (linux \|\| android)` |
| eBPF 程序本体 | 在独立依赖 [`CHIZI-0618/sing-ebpf`](https://github.com/CHIZI-0618/sing-ebpf) 里（`internal/bpfgen/*_bpfel.o`、`*_bpfeb.o` 预编译内嵌）→ **普通构建不需要 NDK / clang，只要 Go** |
| [Fanju6/NetProxy-Magisk](https://github.com/Fanju6/NetProxy-Magisk)（Android） | 内置的"sing-box 内核"就是上面这个分支，构建标签含 `with_ebpf`（见其 `.github/resources.json`） |
| 分支发布产物 | GitHub Releases **为空**（只有 tag）→ Linux / Android 二进制都要**自己编**，Arch 仓库更没有 |

分支自述：*"本分支现已加入实验性的 eBPF 入站支持，可在 Linux 与 Root Android 上通过内核 eBPF 程序接管网络连接，
无需创建 TUN 设备，也不依赖传统的 iptables/nftables REDIRECT 或 TPROXY 规则"*。

### 2.1 "alpha 才有？有没有编好的二进制？"——逐条实测

| 问题 | 答案 | 证据 |
|---|---|---|
| eBPF 只在 alpha？ | ❌ **不是**。1.14 stable 基线的分支 tag 一样有 | `v1.14.0-reF1nd` / `v1.14.1-reF1nd` / `v1.14.2-reF1nd` 的 `include/ebpf.go` 全部 HTTP 200；`v1.14.2-reF1nd` 的 `option/ebpf.go` 里 `local`/`shared`/`cgroup`/`packet_rewrite`/`include_uid` 字段与新版一致，`protocol/ebpf/` 有 54 个文件 |
| 上游 alpha 有预编译二进制？ | ✅ 有，但**装了也没 eBPF** | 上游 `v1.15.0-alpha.9` 是 prerelease，带 **167 个资产**（linux/darwin/windows 各架构、`SFA-*.apk`、deb/rpm…）；但 eBPF 入站源码在上游根本不存在（`docs/configuration/inbound/ebpf.md` → 404） |
| 分支（reF1nd）有预编译二进制？ | ❌ **一个都没有** | `GET /repos/reF1nd/sing-box/releases?per_page=100` → `count: 0`。只有 tag，无任何 asset |
| NetProxy 模块的核是哪来的？ | 它自己编的 | 其 `.github/workflows/update-resources.yml` 用 `TAGS=${{ … }}` + `make -C .sing-box-source build`，然后 `go version -m .sing-box-source/sing-box \| grep -q 'with_ebpf'` 自检 |
| 分支自己的 Docker 镜像？ | ❌ 不能用 | `docker.yml` 用的标签集是 `release/DEFAULT_BUILD_TAGS*`（**不含 with_ebpf**），且只在 release 事件触发——而分支没有 release |
| 第三方 Docker Hub `eyaoyi/sing-box-ref1nd-stable` | ⚠️ 别用 | 最后更新 2026-08，停在 `v1.13.19`；非官方，且 eBPF 在容器里还要额外处理 cgroup/权限 |

**结论：想要 eBPF，二进制只能自己编（或自己打包）。** 幸运的是构建只要 Go（BPF 对象是
[`CHIZI-0618/sing-ebpf`](https://github.com/CHIZI-0618/sing-ebpf) 模块里预编译内嵌的 `*_bpfel.o`），
不需要 NDK / clang / CGO。**这正好适合你 `~/pkgbuild-source` 那套 CI。**

## 3. 你这台机器的内核体检（全部实测通过）

```
Linux 7.2.8-1-cachyos-bore-lto #1 SMP PREEMPT_DYNAMIC x86_64
```

| 要求（来自分支的 eBPF 内核要求文档） | 你的机器 | 结果 |
|---|---|---|
| `CONFIG_BPF` / `CONFIG_BPF_SYSCALL` / `CONFIG_BPF_JIT` | y / y / y | ✅ |
| `CONFIG_CGROUP_BPF`（local `cgroup` 数据面默认） | y | ✅ |
| `CONFIG_NET_CLS_BPF` / `CONFIG_NET_SCH_INGRESS` / `CONFIG_NET_CLS_ACT` | `=m` / `=m` / y | ✅（ko 在 `/lib/modules/…/net/sched/`，按需加载） |
| `CONFIG_VETH`（local `tc` 数据面才需要） | `=m` | ✅ |
| `CONFIG_BPF_STREAM_PARSER`（SOCKMAP 加速） | y | ✅ |
| cgroup v2 统一挂载 | `cgroup2 /sys/fs/cgroup cgroup2 rw,…` | ✅ |
| bpffs | `bpf /sys/fs/bpf bpf rw,…` | ✅ |
| LPM trie 内核缺陷（6.6.0–6.6.46） | 7.2.8，不在受影响区间 | ✅ |
| 现有 tc 钩子冲突 | `tc filter show` 所有网卡 **无任何 filter**（dae 残留早已清净） | ✅ |

### 3.1 root 预检正式结果：**全绿通过** ✅

```bash
sudo ~/.cache/sing-box-bin/sing-box-v1.14.2-reF1nd-with_ebpf \
     tools ebpf status --mode all --interface virbr0 --json
```

```
"result": "preflight_passed",
"preflight": true, "exact_object_load": true,
"summary": { "pass": 51, "warn": 0, "fail": 0, "unknown": 0,
             "required_failures": 0, "required_unknowns": 0, "required_issues": 0 }
```

含义（不是"参数看着对"，是**真的把对象喂给 verifier 并加载了**）：

| 关键 PASS 项 | 说明 |
|---|---|
| `selected cgroup eBPF object` | 真加载了 cgroup 程序与其 map 规格（未挂 hook）；coarse-time UDP 变体可用 |
| `selected packet-rewrite eBPF object` | 真加载了 shared 报文改写程序（未挂 classifier） |
| `BPF map type Array / Hash / LRUHash / LPMTrie / PerCPUArray` | 五类 map 全部可建 |
| `CGroupSockAddr` + `bpf_get_current_uid_gid` | **本机 UID 级（分应用）接管能力就位** |
| IPv4/IPv6 透明 TCP/UDP、original-dst、packet-info | 透明 socket 全套通过 |
| `BPF JIT` | `bpf_jit_enable=1` |
| `locked-memory limit` | RLIMIT_MEMLOCK 自动调成 unlimited |
| `TC interface framing virbr0` | `ether` 帧 ✅ → **虚拟机共享路径可用** |
| `LPM trie policy updates` | 7.2.8 不在缺陷区间，PASS |

> ⚠️ **一个必须注意的细节**：探测里那条 `cgroup path` 报的是
> `/sys/fs/cgroup/user.slice/…/kitty-30065-0.scope` —— 那是"**探测进程自己**"所在的 cgroup
> （我从你终端里跑的），**不是**接管范围。真正全局接管要么**省略 `local.cgroup_path`**（挂 cgroup v2 根层级），
> 要么显式写 `/sys/fs/cgroup`；写成上面那个 scope 就只会代理你终端里跑的程序。
> 官方也明说"**attach permission and exclusivity are still checked during startup**"——
> 挂载权限只在真实启动时校验，所以**第一次起服务才是真考验**（见 5.2 / 5.4 的兜底方案）。

> 之前非 root 探测时看到的 `UNKNOWN` / `FATAL: map create: operation not permitted` **不是内核不支持，是权限不够**：
> `/proc/sys/kernel/unprivileged_bpf_disabled = 2`，非 root 连一个 map 都建不了。
> 即 **eBPF 相关的 `check`、探测、启动都必须 root**。

## 3.2 A/B 试跑结果（2026-10-02 08:54，同一套判据）

用 `ebpf-trial/run-ebpf-trial.sh` 实测（脚本先停 TUN 服务、前台起 eBPF 核心、跑完恢复）：

| 判据 | TUN 基线 | **eBPF 阶段** | 结论 |
|---|---|---|---|
| `tun0_state` | present | **absent** | 真的没有 TUN 设备 |
| `proxy_exit_ip` | 103.151.172.73 | **<proxy-exit-ip>** | 无 TUN 仍在走代理 ✅ |
| `ipv6_http_code` | 200 | **200** | IPv6 正常 ✅ |
| `ipv6_blackhole` | 0 | **0** | 无黑洞规则 ✅ |
| `direct_isp_ip` | <home-ip> 电信 | <home-ip> 电信 | 国内仍直连 ✅ |
| `resolve_github` | ok | ok | DNS 通 ✅ |
| `ads_dns_answer` | `[]`（被拦） | ⚠️ `127.0.0.53 timed out`（瞬时） | 见下 |

**结论：eBPF 数据面在这台机器上完整可用。** 尤其重要的是，3.1 里唯一"没被预验证"的点
——**root 挂 cgroup v2 根层级的权限/独占性**——实际启动时通过了（日志 `sing-box started (0.13s)`，
且流量确实被接管）。分应用所需的 UID hook 也已在预检中确认就位。

**两处尚需一次干净重跑才能定论**：

1. `ads_dns_answer` 那次超时：切换瞬间 systemd-resolved 的上游（TUN 的 `172.19.0.2`）刚消失，
   属于瞬时；且该判据当时还受 **systemd-resolved 自身缓存**干扰（脚本 v2 已改为 `dig @1.1.1.1` +
   每轮 `flush-caches`）。
2. 第二轮 `SHARED_IFACE=virbr0` 的"基线"其实是**无代理直连**（因为第一轮恢复失败），
   所以那份 diff 无参考价值；**虚拟机共享路径仍未端到端验证**（当时 `virbr0` 是 DOWN，没有虚拟机在跑）。

## 4. 我现场编译出来的二进制（已放好）

用 podman 里的 Go 1.26.8 编的分支 `reF1nd-testing`（HEAD `bccceeb`）：

```bash
podman run --rm -v /tmp/sb-fork:/src -v gomodcache:/go/pkg/mod -w /src \
  -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 \
  docker.io/library/golang:1.26 sh -c "go build -trimpath -tags '$TAGS' \
  -ldflags \"-s -w -X 'github.com/sagernet/sing-box/constant.Version=v1.15.0-alpha.9-reF1nd'\" \
  -o /src/sing-box-ebpf ./cmd/sing-box"
```

产物（两个版本都编好并验证过，可任选；**推荐 stable 基线的那个**）：

| 路径 | 版本 | sha256 | 大小 |
|---|---|---|---|
| `~/.cache/sing-box-bin/sing-box-v1.14.2-reF1nd-with_ebpf` | `v1.14.2-reF1nd`（**与你现在同基线**） | `87583b8695369f6a340fb1a4fe27dc652b59e02ff59d3a50d658fc2e632164f3` | 86.8 MB |
| `~/.cache/sing-box-bin/sing-box-v1.15.0-alpha.9-reF1nd-with_ebpf` | `v1.15.0-alpha.9-reF1nd` | `8a55dfe9125164de26afb7a889bcf6458922fbfd76d34046f51a9695d2dee1e4` | 88.5 MB |

实测结果（都在你本机跑的）：

| 实测项 | `v1.14.2-reF1nd` | `v1.15.0-alpha.9-reF1nd` |
|---|---|---|
| `version` | `go1.26.8 linux/amd64` ✅ | `go1.26.8 linux/amd64` ✅ |
| 编译标签含 `with_ebpf` | ✅ | ✅ |
| `check -C /etc/sing-box`（**你现在的 TUN 配置**） | **exit=0，零告警** ✅ | **exit=0**，唯一告警：`tun.stack` 在 1.15 弃用 |
| `check -c <tun 换成 ebpf 入站的配置>` | 非 root 下 exit=1，原因是 `map create: operation not permitted` —— **权限门，不是配置错误**（官方样例配置在该权限下同样失败） | 同上 |
| `tools ebpf status` 内核预检 | 命令可用，能逐项报能力 | 同左 |

> 注意一个反直觉点：**这个分支的 `sing-box check` 遇到 ebpf 入站会真的去建 eBPF map**，
> 所以"非 root 时 `check` 失败"≠ 配置写错。字段名我已对齐 `option/ebpf.go`，无 unknown field。

### 4.1 用你自己的 `~/pkgbuild-source` 打包（**已完成**）

> ✅ **已落地**：`~/pkgbuild-source/packages/sing-box-ebpf/`（PKGBUILD + .SRCINFO）。
> 容器内真实 `makepkg` 构建通过（产物 25.5 MB，含二进制 + 两个 systemd 单元 + license），
> namcap 仅两条 Go 静态二进制常态告警（`lacks FULL RELRO` / `lacks PIE`，**退出码 0，不会中断 CI**）。
> 配套的管理界面见 `singbox-panel-guide.md`（`packages/sing-box-panel/`）。

你那个仓库（CI 从 `packages/<name>/{PKGBUILD,.SRCINFO}` 构建 → 发到 `repo` 分支 → pacman 直接装）
正好解决"没有预编译二进制"这件事：**一次打包，以后 pacman 升级，不用手工编。**
`packages/daed-emo/` 就是现成模板（同样是 Go 构建 + 自带 systemd 单元）。

建议新增 `packages/sing-box-ebpf/`，要点：

```bash
source=('git+https://github.com/reF1nd/sing-box.git#tag=v1.14.2-reF1nd')   # stable 基线；要 1.15 特性再换 tag
makedepends=('base-devel' 'git' 'go')
provides=('sing-box')          # 装的是 /usr/bin/sing-box，沿用发行版单元
conflicts=('sing-box' 'sing-box-git')
# 构建标签务必含 with_ebpf（否则就是普通的 sing-box，白装）：
#   with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,
#   with_tailscale,with_ccm,with_ocm,with_cloudflared,with_usbip,with_openvpn,
#   with_openconnect,badlinkname,tfogo_checklinkname0,with_ebpf
```

- `with_naive_outbound` **不要带**（Linux + `CGO_ENABLED=0` 编不过，见第 8 节）。
- `conflicts=('sing-box')` 是刻意的：两个透明代理不能共存，装这个就等于顶掉官方包。
- 打包时顺手把发行版单元的 capability 限制补上 `CAP_BPF CAP_PERFMON`（见 5.2），否则服务起不来。

> 我没有直接改你的仓库——你说一声我就按仓库约定加上 `PKGBUILD` + `.SRCINFO`（并用 `makepkg --printsrcinfo` 自检）。

## 5. 真要切到 eBPF，需要改什么

### 5.1 配置：`tun-in` → `ebpf-in`（`mixed-in` 保留）

```json
{
  "type": "ebpf",
  "tag": "ebpf-in",
  "network": ["tcp", "udp"],
  "local": {
    "enabled": true,
    "data_plane": "cgroup",
    "dns_mode": "respect_policy",
    "bypass_private_address": true,
    "ipv6": true,
    "exclude_uid": [ "<可选：不需要走代理的 UID>" ]
  },
  "shared": { "enabled": false }
}
```

- **端口 53**：由 `dns_mode` 在内核侧接管（`hijack` 先接管再筛 UID，`respect_policy` 先筛再接管），
  替代 TUN 时代的 `hijack-dns` 路由动作；原规则留着无害，可删。
- **IPv6**：由 `local.ipv6` 显式开关，不再需要为了 v6 去给 TUN 配地址，也不会再出现
  `ip -6 rule` 里那条 `unreachable` 黑洞（那是 TUN 模式的防泄露设计）。
- **分应用**（Linux 上 TUN 做不到的事）：`include_uid` / `exclude_uid` / `*_uid_range`；
  `include_package` / `exclude_package` 是 **Android 专用**，桌面别用。
- **局域网 / 虚拟机共享**：`shared` 填的是**下游接口**，不是上游！
  你这台机器上默认出口是 `wlan0`，所以**不要填 wlan0**；要让 libvirt 的虚拟机也走代理，应填 `virbr0`：

  ```json
  "shared": { "enabled": true, "data_plane": "packet_rewrite", "interface": ["virbr0"] }
  ```

  且 shared 模式自己**不做 NAT / DHCP / IPv6 RA**（那些仍由 libvirt dnsmasq 负责），
  只支持以太网帧接口（raw-IP / PPP / 隧道链路要换 `socket_assign`）。
- 一个实例**只能有一个** ebpf 入站做 local 接管；**绝对不要 TUN 与 eBPF 同时开**（等于两个透明代理）。

### 5.2 systemd：现在的单元跑不了 eBPF

发行版单元是 `User=sing-box` + `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH`
——**没有 `CAP_BPF`/`CAP_PERFMON`**，而且 local `cgroup` 数据面要挂到 cgroup v2 **根层级**（特权操作）。

建议照 daed 的老路：**用 root 跑**（`User=root` 或干脆去掉 `User=`），capability 限制放宽或至少补
`CAP_BPF CAP_PERFMON CAP_NET_ADMIN CAP_SYS_ADMIN`；`ExecStart` 的 `-D /var/lib/sing-box -C /etc/sing-box` 不用动。
若坚持非 root，`cgroup_path` 指到自己被 systemd 委派的子树，但那样**只能接管该子树内的进程**，不是全局透明。

**兜底（root 挂根 cgroup 被拒时）**：把 `local.data_plane` 从 `cgroup` 换成 **`tc`**
（跟随默认接口，预检里 veth / 策略路由 / socket lookup 能力都已 PASS），代价是依赖默认接口、需要建 veth。

### 5.3 预检（已跑过：`preflight_passed`，51 PASS / 0 fail）

```bash
sudo ~/.cache/sing-box-bin/sing-box-v1.14.2-reF1nd-with_ebpf \
     tools ebpf status --mode all --interface virbr0 --json
```

结果见 3.1。`FAIL` 才是真缺能力；`UNKNOWN` 表示探测被安全策略挡住，需要换权限重跑。
**注意删掉 `--interface virbr0` 就没探测虚拟机共享路径**，反之不想要共享路径可只测 `--mode local`。

### 5.4 切换顺序与回滚（**已于 2026-10-02 10:37 执行成功**，脚本：`switch-to-ebpf.sh`）

> ✅ 现成脚本（在 workspace 目录）：`sudo ./switch-to-ebpf.sh`（可选 `--shared virbr0`）。
> 它做完整安全管线：内核预检 → tun→ebpf 改配置 → `check` → 备份 → 原子替换 → 重启 →
> **eBPF 专属健康检查**（`api ebpf` 附件状态 + 不经代理的请求是否走代理 + 国内是否仍直连 + DNS 是否仍拦）
> → 任一失败自动回滚到 TUN。下面是不用脚本时的等价手工步骤。

```bash
sudo cp -a /etc/sing-box/config.json /etc/sing-box/config.json.pre-ebpf.$(date +%Y%m%d-%H%M%S)   # 1 备份
sudo ./switch-to-local-rules.sh --dry-run                                                         # 2 仍用旧的 TUN 脚本预览
sudo systemctl stop sing-box                                                                      # 3 停服务
#   4 用新二进制 + ebpf 配置在前台手跑，盯日志；出问题 Ctrl-C 即回到无代理状态
sudo ~/.cache/sing-box-bin/sing-box-v1.15.0-alpha.9-reF1nd-with_ebpf -D /var/lib/sing-box -C /etc/sing-box run
#   5 没问题再换 systemd 单元（第 5.2 节）并 systemctl start sing-box
```

验证四条（与现有审计报告同一套判据）：

```bash
curl -s https://myip.ipip.net                                            # 期望：你的电信 IP（直连）
curl -s https://api.ipify.org                                            # 期望：代理节点 IP
curl -6 -s -o /dev/null -w '%{http_code}\n' https://ipv6.google.com      # 期望 200
ip -6 rule show | grep -c unreachable                                    # 期望 0
```

回滚：`systemctl stop sing-box` → 把 `config.json.pre-ebpf.*` 覆盖回 `/etc/sing-box/config.json` →
换回 `/usr/bin/sing-box`（1.14.2 + TUN）与发行版单元 → `systemctl start sing-box`。

## 6. 代价 / 什么时候值得

| | 说明 |
|---|---|
| ⚠️ 版本 | 分支基线的 tag 可选 stable（`v1.14.2-reF1nd`，与你现装同基线）或 alpha（`v1.15.0-alpha.9-reF1nd`）；**eBPF 本身不是 alpha 专属** |
| ⚠️ 维护 | 无 Linux release 产物、无 Arch 包 → 每次升级都要自己 `podman`/Go 重编；**建议用 `~/pkgbuild-source` 打包解决**（见 4.1） |
| ⚠️ 覆盖面 | local `cgroup` 只管**本机 socket**（含 rootless podman，因为它在同一 cgroup 树里）；**转发流量（libvirt VM）不在内**，那要 shared + `virbr0`（预检已确认 virbr0 是 ether 帧 ✅）。而 TUN 的 `auto_route` 现在是一把全包住 |
| ⚠️ 首次启动 | root 挂根 cgroup 的权限/独占性只在真启动时校验（3.1）；被拒就换 `tc` 数据面 |
| ✅ 收益 1 | **分应用分流**（`include_uid`/`exclude_uid`）——这是 TUN 在 Linux 上给不了的，且预检确认 `bpf_get_current_uid_gid` 可用 |
| ✅ 收益 2 | 不建 TUN 设备、无 TUN 拷贝，理论上更省；不用 iptables/nftables REDIRECT/TPROXY |
| ✅ 收益 3 | alpha 那条基线（1.15）能让你评审里惦记的 DNS `type: "group"` 故障转移组用上 |
| ✅ 现状对比 | 你这套 TUN 已经过完整审计：DNS 劫持完整、v6 已修、podman 透明、并发/大文件都过。**没有刚需就别换**；当年 daed 的 eBPF 正是把 DNS 和 IPv6 TCP 弄坏才被换掉的 |

**建议（预检通过后的版本）**：
> 能力门已经过了（51 PASS / 0 fail，连 cgroup 与 packet_rewrite 对象都真加载过），所以剩下的是**行为风险**，不是"能不能跑"。
> 顺序：**先打包（4.1）→ 再备份/前台试跑/回滚（5.4）**；只在你要"分应用"或"去掉 TUN"时才真正切。
> 只是想尝鲜的话，成本最低的试法是：**不开机自启**，前台跑一次、跑完立刻 Ctrl-C，然后用审计报告里那套判据（DNS 四源一致、
> 国内直连 IP、`curl -6` 200、`ip -6 rule` 无 unreachable、podman 出口 IP）打一遍分。

## 7. Android（NetProxy 模块）怎么判断能不能用

- 模块**只提供 eBPF 透明代理入站，没有 TPROXY/REDIRECT 回退**：内核能力不足 → 透明代理根本起不来。
- 厂商内核可能关掉/回移部分 BPF 能力，**不能只看 Android 或内核版本号**，要用模块自带探测：

```sh
su -c '/data/adb/modules/netproxy/netproxyctl ebpf status configured'
su -c '/data/adb/modules/netproxy/netproxyctl ebpf status all --raw'
```

- 默认数据面：本机 `cgroup`（`EBPF_LOCAL_DATA_PLANE=cgroup`），共享网络 `packet_rewrite`（`EBPF_SHARED_ENABLED=0` 默认关）。
- 需要：Magisk / KernelSU / APatch + Root；内核支持 BPF、TC classifier、透明 socket、socket lookup；本机路径还要 veth 与策略路由。
- 它的"sing-box 配置"与你的 `/etc/sing-box/config.json` **不是一份东西**：它用 `runtime/` 现生成的 Provider + eBPF 配置，
  静态主配置在 `config/singbox/config.json`。你的 TUN 配置思路（规则集、DoH、selector）可以照搬，但 `tun` 入站整段要去掉。

## 8. 复现 / 清理

```bash
# 重编（缓存已在 podman 卷里，所以很快；需要 podman，不需要装 Go）
TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,with_ebpf"

# stable 基线（推荐；/tmp/sb-fork-1142 已存在，可直接复用）
git clone --depth 1 --branch v1.14.2-reF1nd https://github.com/reF1nd/sing-box.git /tmp/sb-fork-1142
# 或者最新分支：--branch reF1nd-testing
cd /tmp/sb-fork-1142 && podman run --rm -v "$PWD":/src -v gomodcache:/go/pkg/mod \
  -v gomodcache-build:/root/.cache/go-build -w /src \
  -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 -e GOTOOLCHAIN=local \
  docker.io/library/golang:1.26 sh -c "go build -trimpath -ldflags '-s -w' -tags '$TAGS' -o /src/sing-box-ebpf ./cmd/sing-box"

# 清理我留下的构建缓存（约 2 GB，放着你下次重编会快很多）
podman volume rm gomodcache gomodcache-build
podman rmi docker.io/library/golang:1.26
```

> 坑：`with_naive_outbound` 在 Linux 上 `CGO_ENABLED=0` **编不过**
> （`cronet-go/lib/linux_amd64: build constraints exclude all Go files`），所以标签里没带它——
> 你的订阅是 Shadowsocks，用不到 naive。

## 9. 踩坑记录：`cache.db` 属主（试跑时踩到，已修）

**症状**：`systemctl restart sing-box` 后服务 active 一秒即挂，无限重启循环，`tun0` 消失：

```
FATAL[0000] start service: initialize cache-file: open /var/lib/sing-box/cache.db: permission denied
```

**根因**：`/etc/sing-box/config.json` 里 `experimental.cache_file.path` 是绝对路径
`/var/lib/sing-box/cache.db`，而**非 root 身份跑 `sing-box check -c/-C <线上配置>` 也会真的初始化
cache-file**（这个 fork 的 `check` 会走到服务初始化）。于是该文件被**重建为 `emo:emo` 644**，
而服务用户是 `sing-box`（目录 755，只有属主可写）→ 服务再也写不了自己的缓存。
当时老进程还握着旧 inode，所以表面无恙，**直到重启才炸**。

**修复**（一条命令，缓存可丢弃）：

```bash
sudo chown sing-box:sing-box /var/lib/sing-box/cache.db && sudo systemctl restart sing-box
# 或者干脆：sudo rm -f /var/lib/sing-box/cache.db && sudo systemctl restart sing-box
```

**两条铁律**：

1. **不要用非 root 对线上配置跑 `sing-box check` / `run`**。要验证就先复制一份，并把
   `experimental.cache_file.path` 改到 `/tmp`（试跑脚本 v2 已内置这个隔离）。
2. **`systemctl` 报 `active` ≠ TUN 已就绪**：实测有 1 秒级竞态，`is-active` 为真时 `tun0`
   可能还没建出来。判断健康要 `is-active` + `ip link show tun0` 一起看（脚本 v2 已改成轮询 10s）。
