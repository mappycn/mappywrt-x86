# 2026-11-13 晚间优化过程记录

设备：N4200 软路由 / EzOpWrt(ImmortalWrt 24.10) / 旁路由 `192.168.36.3`
连接方式：SSH（root@192.168.36.3），全程只读诊断 + 一处服务开关操作
时间：19:51 - 19:54 CST

目标：① 停掉空配置的 frpc ② 处理「那几条 DoH 超时」

---

## 阶段 1：只读诊断（frpc）

```
$ uptime
 19:51:25 up 20 min,  load average: 0.00, 0.01, 0.00

$ ps w | grep -i frp | grep -v grep
(空 —— 当前没有进程)

$ /etc/init.d/frpc enabled; echo "enabled_rc=$?"
enabled_rc=0            ← 开机自启仍然开着

$ logread | grep -i frpc | tail -n 12
19:31:17 frpc[7826]: login to server failed: dial tcp 127.0.0.1:7000: connection refused
19:31:22 frpc[8059]: ... stopped
...（共 6 次）
19:31:33 procd: Instance frpc::instance1 s in a crash loop 6 crashes

$ cat /etc/config/frpc
config init
    option respawn '1'
config conf 'common'
    option server_addr '127.0.0.1'
    option server_port '7000'
config conf 'ssh'
    option local_port '22'
    option remote_port '6000'

$ ls -l /etc/rc.d/ | grep -i frp
S99frpc -> ../init.d/frpc
```

判断：frpc 是固件自带的**空配置模板**，服务端写死 `127.0.0.1:7000`（本机根本没 frps），还开了 `respawn`，所以开机就无限重连崩溃。19:31 连崩 6 次后 procd 把它按住了，但**下次重启还会再来一遍**。停用是安全的，不影响任何现有功能。

---

## 阶段 2：定位「DoH 超时」的真实含义

```
$ find /tmp /var /etc -iname '*sing-box*'
/tmp/run/homeproxy/sing-box-c.log
/tmp/run/homeproxy/sing-box-c.json
/etc/config/sing-box ...

$ tail -n 35 /tmp/run/homeproxy/sing-box-c.log
11:38:41 ERROR dns: exchange failed for dispatcher.is.autonavi.com. IN HTTPS: dial tcp ...: i/o timeout
11:38:43 ERROR dns: exchange failed for configuration.ls.apple.com. IN HTTPS: context deadline exceeded
11:45:23 ERROR dns: exchange failed for github.com. IN A: ... i/o timeout
11:45:26 ERROR connection: open connection to g.z321.cc.cd:443 using outbound/vless[main-out]: i/o timeout
11:47:17 ERROR connection: open connection to dns.google:443 ... context deadline exceeded
11:48:48 ERROR connection: open connection to wss.pandahead.net:443 ... context deadline exceeded

$ grep -n -A 45 '"dns"' /tmp/run/homeproxy/sing-box-c.json
"servers": [
  { "tag":"default-dns", "type":"udp", "server":"223.5.5.5", "detour":"direct-out" },
  { "tag":"system-dns",  "type":"local", "detour":"direct-out" },
  { "tag":"main-dns",    "type":"tcp",  "server":"8.8.8.8",
    "detour":"main-out", "domain_resolver":{"server":"default-dns"} },
  { "tag":"china-dns",   "type":"udp",  "server":"223.5.5.5", "detour":"direct-out" }
]
```

**关键纠正**：日志里的 `IN HTTPS` 不是 "DNS over HTTPS(DoH)"，而是 DNS 的 **HTTPS 记录类型**（RFC 9460 / HTTPS RR，客户端用来协商 HTTP/3）。配置里也根本没有 https 类型的 DNS 服务器 —— 境外解析用的是 `tcp://8.8.8.8` 走 `main-out` 代理。所以这不是 DoH 参数配错。

所有超时的目标都指向同一个地址 `172.64.229.66`，即节点出口：

```
$ uci show homeproxy | grep -E 'dns_server|main_node|address|port'
homeproxy.config.main_node='0fb33e261d564d43e30fa3f84046ba80'
homeproxy.config.dns_server='8.8.8.8'
homeproxy.config.china_dns_server='223.5.5.5'
homeproxy.0fb33e261d564d43e30fa3f84046ba80.address='api.gzcrtw.com'   (port 2096)
homeproxy.43befb19d5aca6d2ef8dd94c0ca3b7b7.address='cloudflare.idc.rocks' (port 8443)

$ grep -A18 '"tag": "main-out"' /tmp/run/homeproxy/sing-box-c.json
"type":"vless", "server":"api.gzcrtw.com", "server_port":2096,
"tls":{"server_name":"apve.ccwu.cc"}, "transport":{"type":"ws","path":"/"}
```

---

## 阶段 3：验证节点与外网是否真的坏了

```
$ ping -c 3 -W 2 172.64.229.66
3 packets transmitted, 3 received, 0% packet loss, avg 35ms    ← IP 层完全正常

$ curl -x http://127.0.0.1:5330 -m 12 -s -o /dev/null -w '%{http_code}' https://www.google.com
200
$ curl -x http://127.0.0.1:5330 ... https://github.com
200
$ curl -m 8 ... https://www.baidu.com
200
$ sing-box check -c /var/run/homeproxy/sing-box-c.json
(无输出 = 配置校验通过)

$ ps w | grep sing-box | grep -v grep
10232 sing-box  /usr/bin/sing-box run --config /var/run/homeproxy/sing-box-c.json
```

判断：核心链路正常，代理可用。那批 ERROR 是**节点/CDN 入口的间歇性抖动** + 客户端后台流量（Apple 推送、地图/腾讯域名、GitHub 类）在抖动窗口里排队超时，不是持续性故障。此阶段 `grep -c ERROR` = 10。

---

## 阶段 4：停用 frpc（本次唯一的配置变更）

```
$ cp /etc/config/frpc /etc/config/frpc.pre-stop-20261113.bak
backup: /etc/config/frpc.pre-stop-20261113.bak      ← 先备份

$ /etc/init.d/frpc stop
$ /etc/init.d/frpc disable

$ ls -l /etc/rc.d/ | grep -i frp; echo "rc.d_grep_rc=$?"
rc.d_grep_rc=1                  ← S99frpc 自启链接已移除
$ /etc/init.d/frpc enabled; echo "enabled_rc=$?"
enabled_rc=1                    ← 已禁用开机自启
$ ps w | grep -i frpc | grep -v grep
frpc process: none
$ grep -ri frpc /etc/crontabs
no frpc cron
```

配置文件本身**没有改动**，只改了服务开关；恢复方法：`/etc/init.d/frpc enable && /etc/init.d/frpc start`。

---

## 阶段 5：收尾复核（发现新情况，如实记录）

```
$ /etc/init.d/frpc enabled; echo "frpc_enabled_rc=$?"
frpc_enabled_rc=1               ← 保持禁用
$ curl -x http://127.0.0.1:5330 ... https://www.google.com
200
$ curl -m 8 ... https://www.baidu.com
200
$ echo "sing-box ERROR total: $(grep -c ERROR /tmp/run/homeproxy/sing-box-c.log)"
12                              ← 从 10 涨到 12

$ tail -n 2 /tmp/run/homeproxy/sing-box-c.log
11:53:11 ERROR connection: open connection to courier2.push.apple.com:443 ... deadline exceeded
11:53:41 ERROR dns: exchange failed for tencent.ingress.letvlb.com. IN AAAA: deadline exceeded
```

所以它不是"历史遗留"，19:53 仍在零星产生。分类统计：`dns: exchange failed` 7 条 / `connection: open connection` 5 条。

---

## 阶段 6：主备节点入口对比

```
$ nslookup api.gzcrtw.com 223.5.5.5
Address: 172.64.229.66   (CNAME 链: saas.sin.fan -> singgcdn.singgnetworkcdn.com)

$ nslookup cloudflare.idc.rocks 223.5.5.5
Address: 172.64.229.66   (同样 CNAME 到 singgcdn.singgnetworkcdn.com)

$ curl -m 8 -k ... https://api.gzcrtw.com:2096/
main_node_2096=302 remote=172.64.229.66     ← 2096 端口 TCP+TLS 通

$ curl -m 8 -k ... https://cloudflare.idc.rocks:8443/
curl: (6) Could not resolve host             ← 系统 DNS 解析失败（223.5.5.5 能解析）
```

两个"节点"其实是**同一个 CDN 的同一个 IP，只是端口不同**（2096 / 8443）。另外系统 DNS（dnsmasq -> 5333 -> sing-box）解析长 CNAME 链偶尔失败，与日志里的 DNS 超时相互印证。

---

## 结论

1. **已完成**：frpc 停止 + 禁用开机自启，配置已备份，无进程、无自启链接、无 cron，代理与外网复查均 200。开机不会再出现 6 次 crash loop 和无效外连。
2. **未擅自改 DNS/代理配置**，理由：
   - 那几条不是 DoH，是 HTTPS RR / AAAA 查询与代理连接超时；
   - 改 DNS 服务器（例如把境外解析换成国内 DNS）会造成解析污染，属功能退化；
   - 根因在节点/CDN 入口的间歇性抖动，改本地 DNS 参数治不了本；
   - 换节点需要重启 HomeProxy（会短暂断网），属于需要你点头的决定。
3. **当前状态可用**：google / github / baidu 均 200，`sing-box check` 通过，日志只是零星 ERROR，不影响正常使用。

## 可选方案（需要你一句话确认，都可一键回滚）

- **A. 换到 8443 端口**（同一服务，只是入口不同；标签显示备用入口延迟更低）
  ```
  cp /etc/config/homeproxy /etc/config/homeproxy.bak-20261113
  uci set homeproxy.config.main_node='43befb19d5aca6d2ef8dd94c0ca3b7b7'
  uci commit homeproxy
  /etc/init.d/homeproxy restart
  # 回滚：uci set homeproxy.config.main_node='0fb33e261d564d43e30fa3f84046ba80'; uci commit homeproxy; /etc/init.d/homeproxy restart
  ```
- **B. 保持现状**：这些超时只发生在后台长连接/冷门域名，网页与常用服务正常，不动最稳。
- **C. 只降日志噪音**：把 `homeproxy.config.log_level` 调到 `fatal` 可让 ERROR 不再刷屏，但会掩盖真实故障，不推荐。

## 仍未处理的安全项

- 默认密码仍是 `password`，建议尽快 `passwd` 修改。
- HomeProxy 与 OpenClash 不要同时开启，避免端口/防火墙规则打架。
