# HomeProxy 排障记录 — 2026-11-18

设备：`192.168.36.3`（N4200 / Mappy-Wrt，旁路由）
现象：LuCI → HomeProxy → 状态 → **链接检查 Google = failed**，百度 = passed。

---

## 一、结论先说

**不是代理坏了，是这个「链接检查」本身测错了对象。**

插件的后端在 `/usr/share/rpcd/ucode/luci.homeproxy`：

```js
connection_check: {
    call: function(req) {
        // google -> https://www.google.com / baidu -> https://www.baidu.com
        return { result: (system(`/usr/bin/wget --spider -qT3 ${url} 2>"/dev/null"`, 3100) === 0) };
    }
}
```

它让**路由器本机直连**访问目标，`wget` 超时 3 秒、整体 3.1 秒硬超时。而这台机器是旁路由：

- `homeproxy.config.proxy_mode = redirect_tproxy`
- `homeproxy.control.lan_proxy_mode = disabled`
- 只接管 LAN 客户端的流量，**路由器自己发出的流量不走代理**
- rpcd 进程没有 `http_proxy` / `https_proxy` 环境变量

所以百度直连 3 秒内可达 → passed；谷歌直连必然不通 → failed。这个按钮在旁路由模式下永远是红的，跟节点好坏无关。

### 证据（实测回显）

```
$ /usr/bin/wget --spider -qT3 https://www.baidu.com    → baidu_rc=0
$ /usr/bin/wget --spider -qT3 https://www.google.com   → google_rc=4
$ ubus call luci.homeproxy connection_check '{"site":"google"}'  → {"result": false}
$ ubus call luci.homeproxy connection_check '{"site":"baidu"}'   → {"result": true}
$ curl -x http://127.0.0.1:5330 https://www.google.com → 302（代理正常）
$ curl -x http://127.0.0.1:5330 https://www.youtube.com → 200
```

---

## 二、顺带查出的另外两处报错

### 1. 三次 `failed to generate client configuration`（22:28 / 22:32 / 22:39）

```
Type error: attempt to set property on null value
In /etc/homeproxy/scripts/generate_client.uc, line 694:
  config.outbounds[length(config.outbounds)-1].tag = 'main-out';
Error: failed to generate client configuration.
```

脚本逻辑：`uci.get_all(uciconfig, main_node)` 取不到节点时返回空对象，`generate_outbound({})` 生成 `null`，给 `null` 打 tag 就报错。即**点保存那一刻 main_node 指向的节点 section 不存在**——典型发生在删旧节点 / 导入订阅 / 切换主节点的中间状态。

22:41:03 已自行恢复；当前配置只有 1 个节点，`main_node` 与它一致：

```
$ uci get homeproxy.config.main_node
f952145bd3b4cf78b37f005a4445276f     # 标签「JP 电信优选[saas.sin.fan 38ms]」
$ uci get homeproxy.f952145b...label → 正常返回
$ sing-box check -c /var/run/homeproxy/sing-box-c.json → 通过
```

**避免复发**：换节点时先导入/新增新节点 → 再到「主节点」下拉里选中它 → 最后删除旧节点；别先删正在用的节点。若已悬空，执行：

```sh
uci set homeproxy.config.main_node='<节点ID>' && uci commit homeproxy && /etc/init.d/homeproxy restart
```

### 2. `[CHINA_LIST] Update failed`（22:40、22:51 各一次）

官方脚本 `update_resources.sh` 用 `wget --timeout=10` **直连** `fastly.jsdelivr.net` 下载 `direct-list.txt`（约 1.4 MB）。实测直连 12 秒仍未完成、走代理只要 3.3 秒 → 10 秒超时必失败。其余三项（china_ip4 / china_ip6 / gfw_list）都已更新成功。

已按脚本同样的处理方式（`sed -e 's/full://g' -e '/:/d'`）走代理补齐：

```
china_ip4  20261118105033
china_ip6  20261117111724
china_list 202611172204  （110243 行，原 110239 行 / 202611142203）
gfw_list   202611172204
```

四项经 `ubus call luci.homeproxy resources_get_version` 全部返回 `error: null`。**服务未重启**，`sing-box` 进程号仍是 20477。

---

## 三、实际改动清单

| 文件 | 改动 | 备份 |
|---|---|---|
| `/usr/share/rpcd/ucode/luci.homeproxy` | `connection_check`：google 改走 `curl -x http://127.0.0.1:5330 -m 10`，超时 3.1s → 10.5s；baidu 保持原逻辑 | `.bak-20261118`（7185 字节，原版） |
| `/etc/homeproxy/resources/china_list.txt` / `.ver` | 走代理更新到 202611172204 | `china_list.txt.bak-20261118` / `china_list.ver.bak-20261118` |

修改后的判定代码：

```js
let cmd = (req.args?.site === 'google')
    ? `/usr/bin/curl -x http://127.0.0.1:5330 -m 10 -s -o /dev/null ${url}`
    : `/usr/bin/wget --spider -qT3 ${url} 2>"/dev/null"`;
return { result: (system(cmd, 10500) === 0) };
```

### 关键坑：rpcd 会缓存脚本

第一次替换文件后 `ubus call` 仍返回 `false`，因为 rpcd 常驻进程加载的是内存里的旧版本。**必须重启 rpcd**：

```sh
/etc/init.d/rpcd restart
```

重启后验证：`http://127.0.0.1/` = 200，`ubus call session list` = rc 0，LuCI 未受影响（`/cgi-bin/luci` 返回 403 是未登录的正常拒绝）。

---

## 四、验证结果

```
$ ubus call luci.homeproxy connection_check '{"site":"google"}' → {"result": true}  ×3
$ ubus call luci.homeproxy connection_check '{"site":"baidu"}'  → {"result": true}
$ curl -x 127.0.0.1:5330 https://www.google.com  → 302 / 302 / 302 / 302 / 302 / 302（6/6）
$ curl -x 127.0.0.1:5330 https://www.youtube.com → 200
$ sing-box check → 通过；homeproxy enabled_rc=0；无新增崩溃日志
```

**节点仍有间歇抖动**：日志里 22:46–22:53 有 `dial tcp 172.64.229.66:443: i/o timeout` / `context deadline exceeded`（节点 `saas.sin.fan` CNAME 到 `172.64.229.66`）。22:53 曾出现一次 `google=000`、检查变红，随后连续 6 次全通、3 次检查全绿。

这是**真实状态**：改完之后这个按钮会如实反映代理链路，节点抖的时候变红是正常的告警，不是配置坏了。当前只有一个节点，没有备用可切；建议导入更多节点并启用 urltest 自动选优，或订阅里保留备用入口。

---

## 五、回滚 / 重刷后复现

一键还原（回到插件原始行为，页面 Google 会重新变红）：

```sh
cp -p /usr/share/rpcd/ucode/luci.homeproxy.bak-20261118 /usr/share/rpcd/ucode/luci.homeproxy
/etc/init.d/rpcd restart
```

> **刷机或 `opkg upgrade luci-app-homeproxy` 会覆盖这个 ucode 文件**，页面检查会退回「直连测试」的原版行为。届时重新照第三节改一遍并重启 rpcd 即可。

手动重试大陆域名列表（直连超时可走代理）：

```sh
curl -x http://127.0.0.1:5330 -m 60 -sS \
  https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt \
  -o /tmp/direct-list.txt
sed -i -e 's/full://g' -e '/:/d' /tmp/direct-list.txt
mv /tmp/direct-list.txt /etc/homeproxy/resources/china_list.txt
```

---

## 六、常用的自查命令

```sh
# 页面检查到底在测什么（等价于后端调用）
ubus call luci.homeproxy connection_check '{"site":"google"}'

# 真正测代理链路
curl -x http://127.0.0.1:5330 -m 12 -s -o /dev/null -w '%{http_code} %{time_total}\n' https://www.google.com

# 主节点是否悬空
uci get homeproxy.config.main_node; grep 'config node' /etc/config/homeproxy

# 服务日志与配置校验
tail -n 30 /tmp/run/homeproxy/homeproxy.log
tail -n 20 /tmp/run/homeproxy/sing-box-c.log
sing-box check -c /var/run/homeproxy/sing-box-c.json
```

---

## 七、遗留提醒

- 系统日志 22:43:54 有 `passwd: password for root changed by root`，但本次用默认 `password` 仍可 SSH 登录成功。请确认 root 密码当前值；网盘准备映射公网，用弱口令风险很高。
- 网盘 `http://192.168.36.3:8080`（FileBrowser）已配置好，主路由 TCP 28080 → 192.168.36.3:8080 的映射及 DDNS/HTTPS 仍待确认 WAN IP 与域名。
- HomeProxy 与 OpenClash 不要同时启用。
