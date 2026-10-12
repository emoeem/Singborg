# 候选配置改动清单（2026-10-12 · v2）

> 本文件说明 `config/config.new.json` 相对现役配置的**逐字段差异**，以及如何安全地把它落到
> `/etc/sing-box/config.json`。
> **重要：`config/config.new.json` 是从脱敏快照派生的**，节点域名是 `<node-server>`、端口是 `0`，
> **不能直接当生产配置用**。它是"审查样本"；落地方案是**只把下面这 1 处改动应用到真实配置**。
>
> **v2 相对 v1 的变化**：v1 曾包含两项 DNS 改动（新增 `dns-local` server + `dns.rules[0]` 本地域直查）。
> 按"先测试后更新"实测后**已撤回**（现网根本没有本地域名空间，且那个解析器从本机时通时不通），
> 理由与原始数据见 [`docs/11`](../docs/11-配置审查与优化报告-2026-10-12.md) §3.8。
> `config.new.json` 里这两项已删除，落地脚本改为**显式 opt-in**。

---

## 1. 差异总览（1 处 / 4 个字段）

| # | JSON 路径 | before | after | 级别 | 理由（证据见 `docs/11`） |
| --- | --- | --- | --- | --- | --- |
| 1 | `outbounds[type=urltest].interval` × 4 | `"5m"` | `"3m"` | P2-3 | 回到官方默认（3m），缩短节点故障后的选路盲区 |

> 这 4 处是：`Auto`、`Auto-Japan`、`Auto-HongKong`、`Auto-Singapore`。`tolerance`（Auto 150ms /
> 子组 50ms）与 `idle_timeout: 30m` 都是官方默认值，**不动**；`Proxy.interrupt_exist_connections: false`
> 也不动（避免动现有连接）。
>
> 除这 4 个字段外，`config.new.json` 与 `config/config.sanitized.json` **逐字段完全一致**
> （可复现校验见 §7）。

### 已撤回的改动（记录在此，不应用）

原 v1 的改动 1/2 是"新增 `{"type":"udp","tag":"dns-local","server":"192.168.31.1","server_port":53}`
+ 在 `dns.rules[0]` 插入 `{"domain_suffix":[".lan",".home",".home.arpa",".internal"],"server":"dns-local"}`"。
撤回理由（实测）：

1. **收益≈0**：`nmcli -f IP4.DOMAIN device show wlan0` 为空（无 DHCP 搜索域）、`/etc/hosts` 无内网名，
   网络上根本没有"本地域名空间"；本地解析器对 `test.lan`/`nas.lan`/`router.lan` 一律 `NXDOMAIN`。
2. **风险>0**：`dig +short CH TXT id.server @fd00:6868:6868::1` → `"hkg09"`（Cloudflare 香港 PoP）说明
   它只是个**转发器**；而 `192.168.31.1:53` 从本机**时通时不通**（`+time=2` 批次 5/5 超时，TCP/53 超时）。
   指过去会把这些后缀从"立刻 NXDOMAIN"变成"卡到 `dns.timeout: 10s`"。
3. **原证据笔误**：`dns.servers` 现有 7 项里**没有** `dns-local`（原写"已有却无人引用"有误）。

**如果你确认局域网里真的有按主机名访问的设备**（NAS/打印机等），请先自己确认那个解析器持有这些名字：

```bash
dig +short nas.lan @192.168.31.1     # 期望：返回内网 IP（而不是 NXDOMAIN / 超时）
```

确认后再用 opt-in 方式落地（脚本会先探测 3 次，3/3 成功才写）：

```bash
sudo bash scripts/apply-config-new-2026-10-12.sh --apply --with-dns-local 192.168.31.1
```

> **写 `dns-local` 的坑（opt-in 时才相关，保留备查）**：**不要**写 `"detour": "direct"`。
> `sing-box check` 对它是**放行**的，但 `sing-box run` 会 FATAL：
> `start dns/udp[dns-local]: detour to an empty direct outbound makes no sense`。
> 省略 `detour` 即默认直连，行为一致且安全。

---

## 2. 具体 before / after

### 2.1 改动 1：urltest 探测间隔

```jsonc
// before
{ "type": "urltest", "tag": "Auto",           "interval": "5m", "tolerance": 150, "idle_timeout": "30m", ... }
{ "type": "urltest", "tag": "Auto-Japan",     "interval": "5m", "tolerance": 50,  ... }
{ "type": "urltest", "tag": "Auto-HongKong",  "interval": "5m", "tolerance": 50,  ... }
{ "type": "urltest", "tag": "Auto-Singapore", "interval": "5m", "tolerance": 50,  ... }

// after
{ "type": "urltest", "tag": "Auto",           "interval": "3m", "tolerance": 150, "idle_timeout": "30m", ... }
{ "type": "urltest", "tag": "Auto-Japan",     "interval": "3m", "tolerance": 50,  ... }
{ "type": "urltest", "tag": "Auto-HongKong",  "interval": "3m", "tolerance": 50,  ... }
{ "type": "urltest", "tag": "Auto-Singapore", "interval": "3m", "tolerance": 50,  ... }
```

依据：官方文档 `urltest.interval` 默认 **3m**（当前配置放宽到 5m 是唯一的"背离默认"之处）；把
`Proxy` 的 `interrupt_exist_connections` 保持 `false` 意味着这 5 分钟里**新连接**仍会撞死节点，
所以缩短到 3m 是"用可忽略的探测流量换更短的盲区"。

---

## 3. 落地方式（推荐：脚本）

```bash
# 0) 不需要 root 的预览：拿脱敏快照看脚本会改什么（推荐先跑这个）
bash scripts/apply-config-new-2026-10-12.sh --dry-run --config config/config.sanitized.json

# 1) 读真配置的 dry-run（现网配置 root 0600，必须 sudo）
sudo bash scripts/apply-config-new-2026-10-12.sh --dry-run

# 2) 正式落地：备份 → check → 原子替换 → 重启 → 健康检查；任一步失败自动回滚
sudo bash scripts/apply-config-new-2026-10-12.sh --apply

# 备用：默认不改 DNS；只有显式指定才加本地域直查（先探测 3/3）
sudo bash scripts/apply-config-new-2026-10-12.sh --apply --with-dns-local 192.168.31.1
```

脚本做的事：

1. `cp -p` 现网配置到 `/etc/sing-box/backups/config.json.bak.<时间戳>`（0600 root）；
2. 用 python3 在 **JSON 对象层面**做上面的改动（幂等：已改过的字段会跳过，第二次运行报"已是最新"）；
3. 写临时文件 → `/usr/bin/sing-box check -c <临时文件>`（**唯一能拦住未知字段/语法错误的关卡**）；
   非 root 时若报 `eBPF self-bypass … MEMLOCK may be too low`，会自动摘掉 `ebpf` 入站再校验其余字段
   （这是权限问题，不是配置问题）；
4. `install -m600` 原子替换现网配置；
5. `systemctl restart sing-box` → 等监听端口 `7892/9090/9091` 出现 → 经代理打
   `https://www.gstatic.com/generate_204`（重试至多约 30s）；
6. 任何一步失败：还原备份 + 重启 + 打印原因，退出码非 0。

> `--apply` 需要 root（写 `/etc`、重启服务）；非 root 跑 `--apply` 会被明确拒绝，不会留下半成品。

## 4. 手工落地（不用脚本时）

```bash
sudo install -m600 /etc/sing-box/config.json "/etc/sing-box/backups/config.json.bak.$(date +%Y%m%d-%H%M%S)"
sudo cp /etc/sing-box/config.json /tmp/cfg.json
sudo python3 - <<'PY'
import json
p = '/tmp/cfg.json'
c = json.load(open(p, encoding='utf-8'))
for o in c.get('outbounds', []):
    if o.get('type') == 'urltest' and o.get('interval') == '5m':
        o['interval'] = '3m'
json.dump(c, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
sudo /usr/bin/sing-box check -c /tmp/cfg.json \
  && sudo install -m600 /tmp/cfg.json /etc/sing-box/config.json \
  && sudo systemctl restart sing-box
```

## 5. 回滚

```bash
ls -lt /etc/sing-box/backups/ | head
sudo install -m600 /etc/sing-box/backups/config.json.bak.<时间戳> /etc/sing-box/config.json
sudo systemctl restart sing-box
```

## 6. 改完之后必须验收

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -x http://127.0.0.1:7892 https://www.google.com/generate_204  # 204
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -x http://127.0.0.1:7892 https://www.baidu.com                # 200（直连）
bash scripts/sing-box-status                                                          # 一屏体检
journalctl -u sing-box --since '-5 min' -p warning                                    # 期望：无新 ERROR
```

本次**没有** DNS 改动，所以不需要验"本地域解析"。若你以后用 `--with-dns-local` opt-in，再加一条：

```bash
dig +short <你的内网主机名> @<本地DNS>    # 期望：内网 IP
```

## 7. 候选文件是怎么生成与校验的（可复现）

生成逻辑（等价于实际执行的那几行）：

```python
import json
c = json.load(open('config/config.sanitized.json', encoding='utf-8'))
for o in c['outbounds']:
    if o.get('type') == 'urltest' and o.get('interval') == '5m':
        o['interval'] = '3m'
json.dump(c, open('config/config.new.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
```

本次已跑的校验：

```bash
# (a) JSON 合法
python3 -m json.tool config/config.new.json >/dev/null && echo "json ok"

# (b) 与脱敏快照的差异只有那 4 个 interval 字段
python3 - <<'PY'
import json, copy
a = json.load(open('config/config.sanitized.json', encoding='utf-8'))
b = json.load(open('config/config.new.json', encoding='utf-8'))
d = copy.deepcopy(b); tags = []
for o in d['outbounds']:
    if o.get('interval') == '3m':
        tags.append(o['tag']); o['interval'] = '5m'
print('唯一差异 =', tags, '| 其余:', 'IDENTICAL' if d == a else 'DIFFERS')
PY
# 实测输出：唯一差异 = ['Auto', 'Auto-Japan', 'Auto-HongKong', 'Auto-Singapore'] | 其余: IDENTICAL

# (c) 字段合法性（非 root 下摘掉 ebpf 入站 → exit 0；root 下可直接全量 check）
python3 -c "
import json;c=json.load(open('config/config.new.json',encoding='utf-8'))
c['inbounds']=[i for i in c['inbounds'] if i.get('type')!='ebpf']
json.dump(c,open('/tmp/new-noebpf.json','w',encoding='utf-8'))"
/usr/bin/sing-box check -c /tmp/new-noebpf.json; echo "exit=$?"

# (d) 脚本自身：非 root 预览 + opt-in 闸门 + --apply 拒绝
bash scripts/apply-config-new-2026-10-12.sh --dry-run --config config/config.sanitized.json
bash scripts/apply-config-new-2026-10-12.sh --dry-run --config config/config.sanitized.json --with-dns-local 192.168.31.1
bash scripts/apply-config-new-2026-10-12.sh --apply --config config/config.sanitized.json   # 期望：ERROR --apply 需要 root
```

---

## 8. 关于"规则集陈旧"（本条不改配置，只记录结论）

核对包归属后，**原先怀疑的"规则集 11 天未刷新"比想象的小得多**：

| 目录 | 文件数 | 时间 | 归属 | 是否需要动作 |
| --- | --- | --- | --- | --- |
| `/usr/share/sing-box/rule-set/` | 2131 | 1893 个 @10-10 13:22、238 个 @09-12 21:10 | 包 `sing-geosite-rule-set 20261009101206-1` + `sing-geoip-rule-set 20260912-1` | ❌ 由 `emoeem-repo-update.timer`（10-12 08:45 刚跑过，下次 12:32）随包升级自动刷新（⚠️ 此句是错的，见文末更正） |
| `/usr/share/sing-box-rule-sets/` | 9 | 全部 @10-11 13:17 | 包 `sing-box-rule-sets 20261011-1` | ❌ 同上，包更新即刷新 |
| `/etc/sing-box/rule-set/` | **2** | 全部 @**10-01 21:20** | **手工资产**（无包归属） | ⚠️ 只有这 2 个需要你决定 |

即：**2139/2141 份规则集都在自动更新链路上**，只有手工放在 `/etc/sing-box/rule-set/` 的两份
（`AWAvenue-Ads-Rule.srs` 9093 B 广告表、`geoip-telegram.srs` 127 B）是"11 天前手工放进去"的。
`scripts/refresh-rule-sets.sh` 指向不存在的 `~/pkgbuild-source`，所以它**不会**刷新这两份——
但因为影响面只有 2 个小集合，**本次不建议为它建 timer**；建议改为：

- 记录这 2 份的来源与更新方式（写入 `config/README.md` 或本节即可）；
- 需要时手工替换：下载 → `sing-box rule-set decompile <新文件> | head` 抽查 →
  `install -m644` 覆盖 → `systemctl reload sing-box`（`ExecReload=kill -HUP`，不会断现有连接）。

---

*生成：2026-10-12 · v2 · 本文档未修改任何线上文件；唯一落地改动 `urltest.interval` 5m→3m（4 处）
已于 2026-10-12 10:11:40 由用户确认后应用（备份 `/etc/sing-box/backups/config.json.bak.20261012-101140`，
验收见 docs/11 §7.1）*

---

*更正（2026-10-12 晚 · 实测）：上面表格里"由 `emoeem-repo-update.timer`（10-12 08:45 刚跑过）
随包升级自动刷新"不成立 —— 那个 service 4 次触发、4 次失败、0 次成功
（`Git repository not found: /var/lib/emoeem-repo`），08:45:57 那次正是失败的。规则集包实际是
`pacman -Syu` 时随 `[emoeem]` 滚动 release 更新的（手动，非自动）。详见
`docs/11-配置审查与优化报告-2026-10-12.md` 末尾的「更正」段。*
