# 旁路由联网修复记录（2026-11-18 最终版）

> 设备：N4200 软路由，OpenWrt 旁路由 `192.168.36.3`
> 本文所有节点信息均已脱敏，只以「节点1～节点8」代称。

## 一、结论

新节点导入后，**旁路由已恢复完整联网能力**：

- fw4 防火墙规则集从"开机即加载失败"修复为**正常建立**
- HomeProxy 的 **44 条透明代理规则已真正进入内核**
- 8 个节点就绪，主节点为节点1；代理链路连续 8 次全部成功
- 真实内网客户端（`.11`）已通过旁路由建立外网连接，回包路径正确（masquerade 生效）
- 设备自身：国内 200、代理 200、LuCI 200、网盘 8080 200

## 二、根本原因（已修复）

`/etc/config/firewall` 里有**两个都叫 `docker` 的 zone**（一个绑 `docker0`，一个绑 `172.16.0.0/12`），fw4 生成规则时报：

```
Error: redefinition of symbol 'docker_devices'
```

导致整张 `table inet fw4` 从开机起就不存在 —— HomeProxy 的透明代理规则一条都没进内核，客户端流量只是被裸转发，境外网站自然打不开。

**修复**：把第二个 zone 从 `docker` 改名为 `dockersub`，`fw4 reload` 后规则集立即建立成功。

## 三、本轮全部改动（均在设备上，已持久化）

| # | 改动 | 目的 | 性质 |
|---|---|---|---|
| 1 | 第二个 docker zone 改名 `dockersub` | 修复 fw4 加载失败（**核心修复**） | 必须保留 |
| 2 | `firewall.@defaults[0].forward=ACCEPT` | 旁路由无 WAN，放行 LAN 转发出站 | 旁路由推荐 |
| 3 | `flow_offloading=0` / `flow_offloading_hw=0` | 软件转发，避免 flowtable 与透明代理冲突 | 旁路由推荐 |
| 4 | `fullcone=0` | 回到标准 masquerade，回包路径更规范 | 旁路由推荐 |
| 5 | `mwan3` 停用（上一轮保留） | 旁路由无多 WAN，避免注入 unreachable 策略路由 | 必须保留 |

> 第 2～4 项是在排查"国内转发超时"时加入的。后来确认那是我用桌面 /32 路由和网络命名空间模拟客户端时的假象（路径不对称 / 桥内 ARP 隔离），真实客户端转发一直正常。这几项对旁路由无害且属常见推荐，故保留。若想恢复原厂转发参数，见第五节回滚。

## 四、验证结果（脱敏）

```
fw4 表:                 EXISTS
HomeProxy 规则:         44
HomeProxy 需代理集合:    2 组（境外网段）  / 大陆集合 1435 条
节点数:                 8
主节点:                 节点1（vless / ws）
sing-box:               运行中
代理链路 8 次:          302 × 8（全部成功）
页面链接检查:           google=true / baidu=true
设备直连国内:           200
LAN masquerade:         开启（真实客户端回包路径正确）
活跃真实客户端:         .11 已建立多条外网 ESTABLISHED 连接
mwan3 自启:             关闭
```

## 五、客户端使用（重要）

旁路由已就绪，但要让**其他设备**真正走它，需满足以下之一：

- **方式 A（推荐）**：主路由 DHCP 把下发的「默认网关」和「DNS」都改成 `192.168.36.3`
- **方式 B**：在单台设备上手动把网关/DNS 设为 `192.168.36.3`

设置后，客户端访问国内网站走主路由直连、访问境外网站经旁路由透明代理，无需在客户端安装任何软件。

## 六、回滚命令（如需恢复）

```sh
# 1) 只回滚本轮的转发参数（保留核心的 docker zone 修复，推荐）
cp /etc/config/firewall.bak-20261118c /etc/config/firewall
fw4 reload

# 2) 彻底回滚到本轮开始前（ fw4 会再次加载失败，不建议 ）
cp /etc/config/firewall.bak-20261118b /etc/config/firewall
fw4 reload

# 3) 恢复 mwan3 自启（旁路由不建议）
/etc/init.d/mwan3 enable && /etc/init.d/mwan3 start
```

备份文件说明：
- `firewall.bak-20261118b` — 改 docker zone 之前（含重复 zone 的原始状态）
- `firewall.bak-20261118c` — 只完成 docker zone 改名后的状态（最小修复）

## 七、注意事项

- **重刷固件会丢失**：本轮的 fw4 修复、`luci.homeproxy` 链接检查修复、CHINA_LIST 资源更新都在运行时分区。重刷后需按本文第二节和此前 `homeproxy-fix-20261118.md` 重做。
- **节点安全**：不要在公开文档、截图或聊天中暴露节点地址、端口、UUID 或订阅链接；本文已全部脱敏。
- **弱口令**：root 默认密码 `password` 目前仍可登录 SSH，映射网盘到公网前务必修改。
- **代理策略**：当前为 `bypass_mainland_china`（大陆直连、境外代理），8 个节点已就绪；如某节点不稳定，可在 HomeProxy 里切换主节点或用 urltest 自动选优。
