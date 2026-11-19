#!/bin/sh
# ============================================================
# bypass-mode.sh  把 x86 软路由一键切换成「旁路由（单臂）」模式
# 在路由器上以 root 执行：
#     sh bypass-mode.sh <主路由IP> <本机新IP>
# 例：
#     sh bypass-mode.sh 192.168.1.1 192.168.1.2
#
# 做四件事：
#   1. LAN 改成静态 IP，网关/DNS 指向主路由
#   2. 关掉本机 DHCP 服务（地址由主路由分配，避免两台 DHCP 打架）
#   3. 停用 WAN 拨号（旁路由不直接拨号；防火墙 WAN 区域保持出厂原样）
#   4. LAN 区域只开转发、不做 NAT；保留 WAN 区域的 masq/mtu_fix（与原厂旁路由一致）
#
# 执行后 SSH / LuCI 会立刻断开，请用新 IP 重新连接。
# 想改回主路由模式：把 LAN 改回 DHCP 客户端 + 重新开启 dhcp.lan 即可。
# ============================================================
set -e

MAIN_GW="$1"
SELF_IP="$2"

if [ -z "$MAIN_GW" ] || [ -z "$SELF_IP" ]; then
    echo "用法: sh bypass-mode.sh <主路由IP> <本机旁路由IP>"
    echo "例:   sh bypass-mode.sh 192.168.1.1 192.168.1.2"
    exit 1
fi

echo "$MAIN_GW" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "主路由 IP 格式不对: $MAIN_GW"; exit 1; }
echo "$SELF_IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "本机 IP 格式不对: $SELF_IP"; exit 1; }

GW_NET=$(echo "$MAIN_GW" | awk -F. '{print $1"."$2"."$3}')
MY_NET=$(echo "$SELF_IP" | awk -F. '{print $1"."$2"."$3}')
if [ "$GW_NET" != "$MY_NET" ]; then
    echo "两个 IP 不在同一网段：$MAIN_GW vs $SELF_IP"
    exit 1
fi

if [ "$MAIN_GW" = "$SELF_IP" ]; then
    echo "本机 IP 不能和主路由相同"
    exit 1
fi

# 找防火墙里 lan / wan 区域的序号（不同固件顺序可能不同，不能写死）
zone_idx() {
    uci -q show firewall | sed -n "s/^firewall\.@zone\[\([0-9]\+\)\]\.name='$1'\$/\1/p" | head -n 1
}

LAN_Z=$(zone_idx lan)
WAN_Z=$(zone_idx wan)

[ -n "$LAN_Z" ] || { echo "找不到 lan 防火墙区域"; exit 1; }

echo "==> 1/4 配置 LAN 静态地址"
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$SELF_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway="$MAIN_GW"
uci set network.lan.dns="$MAIN_GW"
uci -q delete network.lan.ip6assign || true
uci -q delete network.lan.delegate || true

echo "==> 2/4 关闭本机 DHCP 服务"
uci set dhcp.lan.ignore='1'
uci -q set dhcp.lan.dhcpv4='disabled' || true
uci -q set dhcp.lan.dhcpv6='disabled' || true
uci -q set dhcp.lan.ra='disabled' || true
uci -q set dhcp.lan.ndp='disabled' || true

# DNS 只对局域网提供服务，避免被当成开放解析器
uci -q set dhcp.@dnsmasq[0].localservice='1' || true
uci -q set dhcp.@dnsmasq[0].domainneeded='1' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='1' || true

echo "==> 3/4 停用 WAN 拨号（保留防火墙 WAN 区域，不要动它的 masq/mtu_fix）"
if uci -q get network.wan >/dev/null 2>&1; then
    uci set network.wan.proto='none'
    uci set network.wan.auto='0'
fi
# 关键修复：原厂旁路由的 WAN zone 保留 masq=1 + mtu_fix=1，LAN zone 无 masq。
# 旧版脚本把 wan6 摘掉、WAN masq 关掉，又把 masq/mtu_fix 挪到 LAN zone，
# 结果 fw4 不再为转发流量生成正确的 TCP MSS 钳制，且 LAN 源 IP 被伪装成旁路由，
# 造成「ping 不通 / 网页打不开」。这里与原厂配置保持一致。
WAN_Z="${WAN_Z:-}"   # 仅作占位，WAN 区域配置保持出厂原样

echo "==> 4/4 配置 LAN 区域转发（不做 NAT，与原厂旁路由一致）"
uci set firewall.@zone[$LAN_Z].input='ACCEPT'
uci set firewall.@zone[$LAN_Z].output='ACCEPT'
uci set firewall.@zone[$LAN_Z].forward='ACCEPT'
uci -q delete firewall.@zone[$LAN_Z].masq || true
uci -q delete firewall.@zone[$LAN_Z].mtu_fix || true

# 关掉 UPnP（存在才关）
if uci -q get upnpd.config >/dev/null 2>&1; then
    uci set upnpd.config.enabled='0'
    uci commit upnpd
    /etc/init.d/miniupnpd stop 2>/dev/null || true
    /etc/init.d/miniupnpd disable 2>/dev/null || true
fi

uci commit network
uci commit dhcp
uci commit firewall

echo "==> 应用配置"
/etc/init.d/network reload || true
/etc/init.d/firewall reload || true
/etc/init.d/dnsmasq restart || true

cat <<EOF

============================================================
旁路由配置完成
------------------------------------------------------------
  本机地址   http://$SELF_IP
  默认网关   $MAIN_GW
  DNS        $MAIN_GW
  DHCP 服务  已关闭（由主路由分配地址）
  WAN 口     已关闭（不接触公网，扫描器扫不到）
============================================================

下一步（在主路由上做，二选一）：
  A. 改主路由的 DHCP 下发参数，让「默认网关」和「DNS」都指向 $SELF_IP
     —— 全屋设备自动走旁路由，无需一台台改
  B. 只给需要的设备手动设：网关 = $SELF_IP，DNS = $SELF_IP

注意：
  * SSH 连接会立即断开，请用 $SELF_IP 重新连接
  * 主路由不要也指回本机，否则会形成 DNS 环路（解析变慢甚至失败）
  * 科学上网插件里记得开启「DNS 转发/劫持」，否则分流规则不生效
EOF
