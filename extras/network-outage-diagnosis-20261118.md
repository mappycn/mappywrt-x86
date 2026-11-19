# 「无法联网」排障记录 — 2026-11-18 23:00

设备：`192.168.36.3`（N4200 旁路由）；主路由 `192.168.36.1`
截图线索：客户端 `ipconfig` 显示 **默认网关 192.168.36.3 / DNS 192.168.36.3**，应用提示「连接到互联网 — 你没有联网」。

---

## 一、实测结论（先说人话）

| 检查项 | 结果 |
|---|---|
| 设备自身访问百度 / ping 223.5.5.5 | ✅ 200 / 0% 丢包 |
| LuCI、FileBrowser(8080)、dnsmasq | ✅ 全正常 |
| 客户端把 DNS 指向 36.3 解析百度/Google/NCSI 域名 | ✅ 全部有 A 记录 |
| **客户端经 36.3 访问国内 IP** | ✅ 可达（180.101.49.44:80、23.56.0.222:80） |
| **客户端经 36.3 访问境外 IP** | ❌ 超时（1.1.1.1:443、142.251.154.119:443） |
| HomeProxy 代理链路 `curl -x 127.0.0.1:5330` | ❌ 连续多次 `000`，全部超时 |

**所以不是「全家断网」，而是「境外走不通」**。Windows/应用的联网探测或需要访问境外服务的程序会因此报「你没有联网」。

---

## 二、三个叠加的根因

### ① 唯一的代理节点已经失效（最直接）

当前配置只有一个节点：

```
config node 'f952145bd3b4cf78b37f005a4445276f'
  label   'JP 电信优选[saas.sin.fan 38ms]'
  address 'saas.sin.fan'  port 443  vless + ws + tls
  CNAME -> singgcdn.singgnetworkcdn.com -> 172.64.229.66
```

实测 `172.64.229.66` 的 **443 / 8443 / 2096 / 80 全部连不上**；`sing-box-c.log` 从 23:08 起刷满：

```
connection: open connection to www.youtube.com:443 using outbound/vless[main-out]:
            dial tcp 172.64.229.66:443: i/o timeout
dns: exchange failed for init.push.apple.com / gateway.icloud.com ... i/o timeout
```

`ubus call luci.homeproxy connection_check '{"site":"google"}'` 也退回 `false`。22:44 时还能 6/6 通，23:08 之后 6/6 全挂 —— **节点/CDN 入口在这一小时里挂了**，且没有备用节点可切。

### ② 固件防火墙配置有 bug，透明代理规则从来没生效（隐藏更深）

`fw4 reload` 一直报：

```
/dev/stdin:76:9-22: Error: redefinition of symbol 'docker_devices'
```

原因是 `/etc/config/firewall` 里有**两个 name 都是 `docker` 的 zone**：

```
config zone 'docker'        -> network 'docker' (docker0)
config zone                 -> subnet '172.16.0.0/12'，name 'docker'
```

fw4 为每个 zone 生成 `define <name>_devices`，重名 → 整张规则集加载失败 → **`table inet fw4` 根本不存在**（`nft list table inet fw4` 报 No such file）。连带后果：

- HomeProxy 的 44 条 tproxy/redirect 规则（`/var/run/homeproxy/fw4_post.nft`）**一条都没进内核**；
- 客户端流量只是被裸转发，境外 IP 直连被墙；
- 页面「链接检查 Google」、各种分流规则都不作用于 LAN 客户端。

验证：给第二个 zone 改名 `dockersub` 后 `fw4 reload` 成功，`table inet fw4` 出现、`homeproxy rules = 44`、境外 TCP 立刻被 `redirect to :5331` 接管（计数器开始增长）。**这个 bug 确实存在且可修**。

### ③ mwan3 在旁路由上是纯干扰

固件预置并启用了多 WAN 组件 mwan3，但 WAN/WAN6 已关，`mwan3 status` 里所有策略都是 `unreachable`。它会给转发包打 `0x3E00` mark；手动重启它时会加入两条致命策略路由：

```
2061: from all fwmark 0x3d00/0x3f00 blackhole
2062: from all fwmark 0x3e00/0x3f00 unreachable   ← 设备自己都 ping 不通外网
```

`conntrack` 里被卡的转发连接正是 `mark=15872 (0x3E00)`、`SYN_RECV`、`packets=0`。

---

## 三、我这轮做过什么 / 为什么全部回滚

1. 修 `docker` zone 重名 → fw4 成功、HomeProxy 规则加载 ✅（技术上成功）
2. 但此时节点已全挂，且我本机用「临时加 /32 路由」模拟客户端时国内转发出现超时，无法确认真实客户端状态；
3. 又试过 `forward=ACCEPT`、`fullcone=0`、关 flow offloading、停 mwan3，均未能让模拟测试完全正常；
4. 回滚过程中 `mwan3 start` 反而注入了上面两条 `unreachable` 规则，导致**设备自己也断网**（`baidu=000`、`ping 223.5.5.5: Network unreachable`）；
5. 已立即 `mwan3 stop` + 删除那两条 rule，设备恢复。

**最终状态 = 报障前状态 + 一处保留改动**：

| 项 | 状态 |
|---|---|
| `/etc/config/firewall` | 已还原为 `firewall.bak-20261118`，两个 docker zone 原样保留 |
| `table inet fw4` | 不存在（与开机时一致） |
| HomeProxy 透明代理规则 | 未加载（与开机时一致） |
| **mwan3** | **已 `stop` + `disable`**（唯一保留改动，防止重启后再注入 unreachable 规则） |
| 设备自身 / LuCI / 网盘 / DNS / 客户端国内访问 | ✅ 全部正常 |

> 之前两轮的改动不受影响：`luci.homeproxy` 的链接检查修复、`china_list` 资源更新都还在。

---

## 四、你现在可以做的两件事

### A. 先让全家恢复上网（1 分钟）

把**主路由 DHCP 下发**的「默认网关 / DNS」改回 `192.168.36.1`，或只在出问题的那台设备上把网关/DNS 改成 `192.168.36.1`。国内网站立刻正常；境外网站仍按运营商原样（本来也走不通）。

### B. 要让旁路由真正翻墙，需要按顺序做两件事

1. **换一个可用节点**：当前 `saas.sin.fan` 的 CDN 入口已整体不可达。请提供订阅链接或节点参数（至少留 2 个以上，配 urltest 自动选优）。没有可用节点，下面所有调整都无意义。
2. **修 fw4 配置 bug**（节点到位后我一次性做完并验证）：

```sh
cp /etc/config/firewall /etc/config/firewall.bak
uci set firewall.@zone[2].name='dockersub'
uci commit firewall
fw4 reload
nft list table inet fw4 >/dev/null && echo "fw4 OK"
nft list ruleset | grep -c homeproxy        # 应 > 0
```

然后需要确认 LAN 客户端的国内/境外分流都正常（这一步我这次没能验证完成，需要在你的设备上实测）。

### 临时替代方案

如果不想等 fw4 调整，可在客户端**手动设置 HTTP/SOCKS 代理 `192.168.36.3:5330`**（mixed 端口监听所有地址），网关仍用主路由。但同样依赖节点可用。

---

## 五、命令速查 / 回滚

```sh
# 看 fw4 是否真的加载了
fw4 reload 2>&1 | grep -i error
nft list table inet fw4 >/dev/null && echo OK || echo MISSING

# 看透明代理规则是否生效
nft list ruleset | grep -c homeproxy

# 看节点是否活着
curl -x http://127.0.0.1:5330 -m 10 -s -o /dev/null -w '%{http_code}\n' https://www.google.com
tail -n 20 /tmp/run/homeproxy/sing-box-c.log

# 看 mwan3 有没有加致死 rule
ip rule | grep -E 'blackhole|unreachable'

# 恢复 mwan3（如需）
/etc/init.d/mwan3 enable && /etc/init.d/mwan3 start

# 恢复防火墙原始配置
cp /etc/config/firewall.bak-20261118 /etc/config/firewall && fw4 reload
```

---

## 六、遗留提醒

- root 默认密码 `password` 目前仍可 SSH 登录；网盘准备映射公网，务必改掉。
- HomeProxy 与 OpenClash 不要同时启用。
- 网盘外网收尾仍待确认：主路由 WAN IP 是否 `116.226.121.11`、是否有域名（用于 DDNS + HTTPS）。
