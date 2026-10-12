# systemd 加固提案（2026-10-12）

> **安装状态（2026-10-12）**：提案 **A、B、D 已装**（A/B：`ls /etc/systemd/system/sing-box.service.d/`；
> D：`systemctl list-timers sing-box-dns-watchdog.timer`），**C 复核后不做**。每一项都保留
> 验证命令与回滚命令。D 另记了一处首次装机踩到的沙箱陷阱（`ProtectSystem=strict` 把
> **`/run` 也**挂成只读），已修，并有回归测试 `scripts/test-dns-watchdog.sh` 钉住。
>
> 这些文件是从 `docs/11-配置审查与优化报告-2026-10-12.md` 与
> `docs/12-开机网络不稳定排查-2026-10-12.md` 里摘出来的"可直接安装的 drop-in 提案"。

## 现状快照（实测）

```
$ systemctl show sing-box -p After -p Wants -p UMask -p StateDirectoryMode -p Restart -p NRestarts
After=... basic.target network-online.target network.target nss-lookup.target systemd-journald.socket ...
Wants=network-online.target
UMask=0022
StateDirectoryMode=0755
Restart=on-failure          # RestartSec=10s
NRestarts=0

$ ls -ld /var/lib/sing-box /var/lib/sing-box/cache.db
drwxr-xr-x root root      /var/lib/sing-box
-rw-r--r-- root root 4194304 /var/lib/sing-box/cache.db      ← 0644（含 DNS 缓存）
```

已存在两个 drop-in（**不要动**）：

| 文件 | 作用 |
| --- | --- |
| `10-config-check.conf` | `ExecStartPre=/usr/bin/sing-box check -c /etc/sing-box/config.json`（挡住坏配置） |
| `20-network-online.conf` | `[Unit] Wants=network-online.target`（10-08 修复"抢跑"的关键，见 `docs/12`） |

## 提案 A · `40-libvirtd-order.conf`（P2-4 / R1，建议装）

把 sing-box 的启动点排到 `libvirtd.service` 之后，消除 `shared.interface = ["virbr0"]`
就绪前的那段 **VM 流量空窗**（今天实测裕量只有 4 秒）。

```bash
sudo install -D -m644 systemd/40-libvirtd-order.conf \
  /etc/systemd/system/sing-box.service.d/40-libvirtd-order.conf
sudo systemctl daemon-reload && sudo systemctl restart sing-box
systemctl show sing-box -p After | tr ' ' '\n' | grep -i libvirtd     # 期望：libvirtd.service
```

注意：`After=`/`Wants=` 在 drop-in 中是**追加**语义（不是覆盖），不会破坏原有依赖。

## 提案 B · `30-umask-hardening.conf`（P2-2，建议装）

`cache_file.store_dns = true` ⇒ DNS 缓存落盘，而 `cache.db` 现在是 **0644**（同机任何用户可读）。
装上后新建文件为 `0600`、`StateDirectory` 为 `0750`；**已有的 cache.db 要手工改一次权限**。

```bash
sudo install -D -m644 systemd/30-umask-hardening.conf \
  /etc/systemd/system/sing-box.service.d/30-umask-hardening.conf
sudo chmod 600 /var/lib/sing-box/cache.db
sudo systemctl daemon-reload && sudo systemctl restart sing-box
systemctl show sing-box -p UMask -p StateDirectoryMode     # 期望 0077 / 0750
ls -l /var/lib/sing-box/cache.db                          # 期望 -rw------- root root
```

> 为什么不是 `UMask=0027`：该组也是 `root`，所以 `0027`（0640）与 `0077` 对"其他用户"的效果相同；
> 取 `0077` 更直白。若你希望面板或其他 root 组进程以外的东西能读，再用 `0027`。

## 提案 C · 规则集刷新 timer —— **本次不建议做**（结论已修正）

> ⚠️ **更正（2026-10-12 晚 · 实测）**：本节原先写"由 `emoeem-repo-update.timer` 自动更新
> （今天 08:45:57 跑过，下次 12:32:08）"——**这个前提是错的**。journal 里那个 service
> **4 次触发、4 次失败、0 次成功**，每次都是 `Git repository not found: /var/lib/emoeem-repo`
> （该目录不存在），而且它当时是 `systemctl --failed` 里**唯一**一项，把真正的开机问题盖住了。
> 规则集包实际由 `pacman` 安装（`/var/log/pacman.log`：
> `[ALPM] upgraded sing-box-rule-sets (20261010-1 -> 20261011-1)` @2026-10-11T14:56:07），
> 即**手动 `pacman -Syu` 时随 `[emoeem]` 滚动 release 更新**。那套 timer 的安装器已在
> `11d8cde` 删除，机器上这套是残留 —— 清理见
> `~/pkgbuild-source/scripts/remove-legacy-repo-update.sh`（默认 dry-run，`--apply` 才删）。

核对包归属后：`/usr/share/sing-box/rule-set/`（2131 份）与 `/usr/share/sing-box-rule-sets/`
（9 份）**全部由 emoeem 仓库的包管理** —— 但更新时机是 `pacman -Syu`，**不是自动的**。
真正"停在 10-01"的只有手工放进 `/etc/sing-box/rule-set/` 的 **2 份**
（`AWAvenue-Ads-Rule.srs`、`geoip-telegram.srs`）。也就是说那 2139 份的新鲜度取决于你是否
记得跑 `pacman -Syu`（`ffmpeg-full` 2.7→2.8 卡在本地索引上就是这个原因）。

结论：**不为这 2 份建 timer**（收益低、多一个写 `/etc` 的定时任务）。
需要更新时手工做，并保留旧文件：

```bash
# 例：替换 AWAvenue 广告表（下载 → 抽查 → 原子替换 → HUP 重载，不断现有连接）
curl -x http://127.0.0.1:7892 -sL -o /tmp/AWAvenue-Ads-Rule.srs <来源URL>
/usr/bin/sing-box rule-set decompile /tmp/AWAvenue-Ads-Rule.srs | head -20      # 抽查内容
sudo install -m644 /etc/sing-box/rule-set/AWAvenue-Ads-Rule.srs \
  /etc/sing-box/rule-set/AWAvenue-Ads-Rule.srs.$(date +%Y%m%d)                  # 留底
sudo install -m644 /tmp/AWAvenue-Ads-Rule.srs /etc/sing-box/rule-set/AWAvenue-Ads-Rule.srs
sudo /usr/bin/sing-box check -c /etc/sing-box/config.json && sudo systemctl reload sing-box
```

同时建议把 `scripts/refresh-rule-sets.sh` 头部那句指向**不存在的 `~/pkgbuild-source`** 的路径
修掉，或在脚本里显式标注"已废弃，改用 emoeem 仓库包更新"——现在它会误导人。

## 提案 D · `sing-box-dns-watchdog.{service,timer}`（DNS 错误缓存自愈）—— **已安装（2026-10-12）**

**要解决的问题**（2026-10-12 实测）：eBPF 入站的 `dns_mode: hijack` 把所有 UDP/53 查询截到
sing-box 自己的 DNS 缓存，而 `experimental.cache_file.store_dns = true` 把它落了盘
（`/var/lib/sing-box/cache.db`）。缓存里一旦存下一条**错误的否定应答（NODATA）**，命中它的
查询会"0 条答案、0 ms"返回，而带 EDNS0 的查询因缓存键不同会绕过它 —— 症状是「某些网站
打不开、别的都正常」，而且**重启不消失**（缓存落了盘）。当时表现为 Firefox 打不开 `emoe.eu.cc`。

**判据一（缓存故障）**：拿 DoH 的真实答案当基准（`curl --resolve` 直连 `1.1.1.1`/`8.8.8.8`，既不经过 53
劫持、也不依赖域名解析），只有「DoH 有 A 记录、本机说没有」才算故障；**拿不到 DoH 基准时
一律判为"无法判断"，绝不动手**（网络本身坏了不该被当成缓存故障去重启代理）。

**判据二（服务存活）**：unit 是 `enabled`（管理员要求它开机就跑）却不 `active` → 直接
`systemctl start` 它（若已被钉在 `failed` —— 崩溃循环撞上 `StartLimitBurst` 后 `start`
会被 systemd 拒绝 —— 先 `reset-failed`）。**这条不是锦上添花**：本机出网走 sing-box 的
eBPF 透明代理（`ip route` 里没有 tun 设备），它一停，连判据一要用的 DoH 基准都不可达 ——
2026-10-12 受控演练实测，这种情况下判据一**永远只会说"无法判断"**（见下一节）。判据二
完全不依赖网络，所以不受这个死循环影响。注意它补的是 systemd 自带 `Restart=on-failure`
覆盖不到的那部分：单次崩溃 systemd 自己会拉，撞了启动频率上限就只剩 reset-failed 一条路。
想长期停用请 `systemctl disable --now sing-box`：`disabled` 的 unit 看门狗不碰。

```bash
# 安装（需要 root）
sudo install -m755 ~/code/Singborg/scripts/sing-box-dns-watchdog.sh /usr/local/bin/sing-box-dns-watchdog
sudo install -m644 ~/code/Singborg/systemd/sing-box-dns-watchdog.service \
                    ~/code/Singborg/systemd/sing-box-dns-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sing-box-dns-watchdog.timer
```

### ⚠️ 沙箱陷阱：`ProtectSystem=strict` 连 `/run` 也挂只读（首次装机的真实故障）

第一次装上去 service 立刻失败，从 `systemctl --failed` 里露出来：

```
sing-box-dns-watchdog[...]: /usr/local/bin/sing-box-dns-watchdog: line 180:
  /run/sing-box-dns-watchdog.lock: Read-only file system
```

原因：`ProtectSystem=strict` 会把**整个文件层次**挂成只读，`ReadWritePaths=` /
`RuntimeDirectory=` 之外的路径一律不可写 —— **`/run` 本身也在内**，而脚本的 flock 锁
当时写死在 `/run/sing-box-dns-watchdog.lock`。`/var/lib/sing-box`（`cache.db` 与冷却
状态文件）本来就在 `ReadWritePaths=` 里，没受影响；`systemctl` / `resolvectl` 走 D-Bus
（连的是 socket，不受只读挂载影响），实测在沙箱内可用。

修法：unit 加 `RuntimeDirectory=sing-box-dns-watchdog`（systemd 建好该目录并**隐含加入
可写集**，unit 停止后清掉），脚本改用 `$RUNTIME_DIRECTORY` 定位锁；手跑（sudo）时该变量
为空，退回 `/run`，与修复前行为一致。

```bash
# 重新装一次（修复后，需要 root）
sudo install -m755 ~/code/Singborg/scripts/sing-box-dns-watchdog.sh /usr/local/bin/sing-box-dns-watchdog
sudo install -m644 ~/code/Singborg/systemd/sing-box-dns-watchdog.service \
                    ~/code/Singborg/systemd/sing-box-dns-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl reset-failed sing-box-dns-watchdog.service
sudo systemctl start sing-box-dns-watchdog.service       # 立刻走一次真实自愈路径
```

### 2026-10-12 受控演练：判据一发现不了「代理挂了」（判据二就是为它补的）

按"停掉 sing-box，看它能不能自己把 sing-box 拉起来"做的演练，**第一次是失败的**：

```
$ sudo systemctl stop sing-box && sudo systemctl start sing-box-dns-watchdog.service
[dns-watchdog] emoe.eu.cc:    无法判断（DoH 基准拿不到；本机 2 条）
[dns-watchdog] www.baidu.com: 无法判断（DoH 基准拿不到；本机 1 条）
[dns-watchdog] github.com:    无法判断（DoH 基准拿不到；本机 1 条）
[dns-watchdog] 解析正常（3 个域名无法判断）     ← sing-box 其实还是 inactive，服务没被拉起来
```

根因是设计里的一个盲点，不是偶发：**判据一的基准自己依赖被监控的对象**。`ip route` 里没有
tun 设备，出网由 eBPF 钩子改道到 sing-box；它一停，`curl --resolve … https://1.1.1.1` 也
跟着不通 → 三个域名全部「无法判断」→ 按"绝不动手"的规则什么都不做。也就是说**单靠判据一，
`sing-box` 崩溃是一个永远看不见的故障**——而那是整机断网，比缓存脏严重得多。

修法：加判据二（见上），并把它的执行**排在探测循环之前**（systemctl 走 D-Bus，不需要网络）；
存活自愈只 `start`、不删缓存不碰配置，冷却 300s（比缓存自愈的 900s 短，因为后果是断网）。
另外把"全部无法判断"时的日志从"解析正常"改掉——那句话在演练里正是误导来源。

正确的演练姿势（先把含判据二的新脚本装上去，命令见上一节的 `sudo install …`）：

```bash
sudo systemctl stop sing-box
sudo systemctl start sing-box-dns-watchdog.service
journalctl -u sing-box-dns-watchdog.service -n 20    # 期望：不活动 → 存活自愈成功
systemctl is-active sing-box                          # 期望：active（不再需要人工兜底）
```

回归测试（免 root；静态核对 `ReadWritePaths`/`RuntimeDirectory` 是否覆盖脚本要写的每个
路径 + `systemd-run --user` 真沙箱正/反向探针 + 判据自测）：

```bash
~/code/Singborg/scripts/test-dns-watchdog.sh
```

验收：

```bash
/usr/local/bin/sing-box-dns-watchdog --check       # 免 root，三个域名应当都 ok，且不报「却不活动」
/usr/local/bin/sing-box-dns-watchdog --self-test   # 免 root，两条判据的 12 个合成用例
~/code/Singborg/scripts/test-dns-watchdog.sh       # 免 root，14 项（沙箱放行核对 + 真沙箱正/反向探针 + 存活判据接线）
systemctl list-timers sing-box-dns-watchdog.timer  # 期望 5 分钟一次
journalctl -u sing-box-dns-watchdog.service -n 20  # 每次运行一行
systemctl is-failed sing-box-dns-watchdog.service  # 期望 inactive（不是 failed）
```

回滚（D 独立于 A/B，可单独卸）：

```bash
sudo systemctl disable --now sing-box-dns-watchdog.timer
sudo rm -f /etc/systemd/system/sing-box-dns-watchdog.{service,timer} \
           /usr/local/bin/sing-box-dns-watchdog
sudo systemctl daemon-reload
```

自愈动作**只动缓存、不碰配置**：`stop sing-box → 删 cache.db → start → resolvectl
flush-caches → 复测`；修不好就以非 0 退出（这样 `systemctl --failed` 看得见），不安静重试。
冷却 900s，避免在"清缓存也没用"的故障上反复重启代理。存活自愈是另一条路径：只 `start`，
冷却 300s（见上一节）。定时任务每 5 分钟跑一次 `--heal`。
可调项写 `/etc/sing-box/dns-watchdog.conf`（`WATCH_DOMAINS` / `WATCH_SERVICE_LIVENESS` /
`HEAL_COOLDOWN` / `START_COOLDOWN` / `RECHECK_DELAY`）。

## 一键回滚（A、B 适用；D 见上）

```bash
sudo rm -f /etc/systemd/system/sing-box.service.d/30-umask-hardening.conf \
           /etc/systemd/system/sing-box.service.d/40-libvirtd-order.conf
sudo systemctl daemon-reload && sudo systemctl restart sing-box
# 权限如需复原：
sudo chmod 755 /var/lib/sing-box; sudo chmod 644 /var/lib/sing-box/cache.db
```

## 安装顺序与验收

1. 先做 `docs/11` §8 第 0 步：留底 `/etc/sing-box/config.json`。
2. 应用配置改动（`scripts/apply-config-new-2026-10-12.sh`，默认只改 urltest 探测间隔）→ 验收
   （见 `config/config.new.diff.md` §6）。
3. 装提案 B（纯权限，风险最低）→ `systemctl show` 验收。
4. 装提案 A（时序）→ `systemctl show -p After` 验收，可选重启一次做真实开机验收（`docs/12` §6）。
5. 装提案 D（DNS 看门狗，与 A/B 无依赖，可最先装）→ `--check` + `--self-test` + `list-timers` 验收。
6. 清理残留 `emoeem-repo-update`（`~/pkgbuild-source/scripts/remove-legacy-repo-update.sh`，
   先跑默认的 dry-run，确认输出的 4 个路径无误再 `sudo ... --apply`）。
7. 每次只装一个，装完立刻看 `journalctl -u sing-box -p warning`。

---

*提案生成：2026-10-12 · A/B/D 已装（D：沙箱陷阱 + 存活判据两处修正，均有回归测试钉住）· 审查者：DSH agent*
