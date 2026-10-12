# systemd 加固提案（2026-10-12）

> ⚠️ **这些文件都还没安装到系统上。** 它们是从 `docs/11-配置审查与优化报告-2026-10-12.md`
> 与 `docs/12-开机网络不稳定排查-2026-10-12.md` 里摘出来的"可直接安装的 drop-in 提案"，
> 等你确认后再执行。每一项都给了验证命令与回滚命令。

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

核对包归属后：`/usr/share/sing-box/rule-set/`（2131 份）与 `/usr/share/sing-box-rule-sets/`
（9 份）**全部由 emoeem 仓库的包管理**，并由 `emoeem-repo-update.timer` 自动更新
（今天 08:45:57 跑过，下次 12:32:08）。真正"停在 10-01"的只有手工放进
`/etc/sing-box/rule-set/` 的 **2 份**（`AWAvenue-Ads-Rule.srs`、`geoip-telegram.srs`）。

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

## 一键回滚（A、B 都适用）

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
5. 每次只装一个，装完立刻看 `journalctl -u sing-box -p warning`。

---

*提案生成：2026-10-12 · 均未安装 · 审查者：DSH agent*
