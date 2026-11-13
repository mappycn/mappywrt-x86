# EzOpWrt 兼容固件 · x86_64 BIOS 云编译工程

给 **N4200 软路由**用的 OpenWrt 固件云编译工程。基于 **ImmortalWrt 24.10** 源码 + **sirpdboy 插件体系**（KuCat 主题、网络向导、进阶设置、分区扩容、DDNS-GO、Lucky、限速管控、看门狗等），复刻 EzOpWrt 的功能集，但由你自己的 GitHub 仓库编译，不依赖任何第三方固件发布。

- 目标平台：`x86/64 → Generic`
- 引导方式：**Legacy BIOS**（产出 `combined.img.gz`，不是 `-efi`）
- 根分区：默认 **2048MB**，ext4 可写
- 编译耗时：约 **1.5 ~ 3 小时**（GitHub 免费额度内）

---

## 一、一次性准备（约 5 分钟）

### 1. 建一个空仓库

打开 https://github.com/new ，填仓库名（例如 `ezopwrt-x86`），选 **Public**（公开仓库的 Actions 时长不限额），**不要**勾选 README / .gitignore，直接创建。

### 2. 上传本工程

在 Windows 上打开 **Git Bash**（开始菜单搜索），把下面的命令整段粘进去，把最后一行的仓库地址换成你自己的：

```bash
cd "/c/Users/Administrator/WorkBuddy/Claw/ezopwrt-build"

git init
git add -A
git commit -m "init: EzOpWrt x86_64 BIOS build"
git branch -M main
git remote add origin https://github.com/你的用户名/ezopwrt-x86.git
git push -u origin main
```

> 首次 push 会弹浏览器让你登录 GitHub 授权，按提示点一下即可。
> 如果提示 `remote: Support for password authentication was removed`，说明用了密码而不是网页授权 —— 在弹窗里选 "Sign in with your browser"。

### 3. 启动编译

进入你仓库的 **Actions** 标签页 → 左侧选 **Build Firmware** → 右侧 **Run workflow**：

| 参数 | 建议值 | 说明 |
|---|---|---|
| `source_branch` | `openwrt-24.10` | 与 EzOpWrt 现役版本同源，插件兼容性最好 |
| `rootfs_size` | `2048` | 根分区 MB，够装 Docker + 一堆插件 |
| `publish_release` | ✅ 勾上 | 编译完自动建 Release，方便以后下载 |

点绿色 **Run workflow**，然后就可以放着不管了。

### 4. 取固件

编译完在 **Releases** 里下载：

```
EzOpWrt-x86_64-BIOS-2048M-YYYYMMDD.img.gz     ← 就是它
```

---

## 二、写盘（N4200 软路由）

### Windows

推荐 **balenaEtcher**（https://etcher.balena.io），选 `img.gz` 直接写，不用先解压。写入目标选你的硬盘/U盘/CF卡，**别选错成系统盘**。

也可以用 **Rufus**（需先解压出 `.img`）或 `physdiskwrite`：

```
physdiskwrite.exe -u EzOpWrt-x86_64-BIOS-2048M-YYYYMMDD.img
```

### Linux / 群晖 / PVE 里

```bash
gunzip -c EzOpWrt-x86_64-BIOS-2048M-YYYYMMDD.img.gz | dd of=/dev/sdX bs=4M status=progress
```

写完进 BIOS 把启动模式设为 **Legacy / CSM**（不要 UEFI，本固件不含 EFI 分区），启动顺序选那块盘。

---

## 三、首次使用

| 项目 | 值 |
|---|---|
| 管理地址 | http://192.168.8.1 |
| 用户名 | `root` |
| 密码 | `password` |
| 默认主题 | KuCat（酷猫） |
| WAN 口 | 除 `eth0` 外的网口自动绑 LAN，`eth0` 为 LAN/WAN 视向导而定 |

**进来第一件事：系统 → 管理权，把密码改掉。**

N4200 一般有 4 个网口（`eth0~eth3`，Intel i210/i211）。如果网口顺序和机箱丝印对不上，用固件自带的 **网络向导** 或 **进阶设置 → 网口绑定** 调整。

### 把 2G 根分区扩到全盘（强烈建议）

固件默认只占 2GB，剩下空间要手动扩：

**系统 → 分区扩容（partexp）** → 选中系统盘 → 执行扩容 → 自动重启。

扩完 `df -h /` 能看到整盘容量，Docker 和下载目录才有地方放。

---

## 四、和 EzOpWrt 原版的关系

| 项目 | 原版 EzOpWrt | 本工程 |
|---|---|---|
| 源码 | ImmortalWrt + 私有 lede 覆盖层 | ImmortalWrt 24.10 公开源码 |
| 插件 | sirpdboy 私有整合包 | 直接拉 sirpdboy 各插件公开仓库 |
| 主题 | KuCat 2.7.x | KuCat（跟随上游最新） |
| 在线升级 | 官方 OTA 服务器 | 重跑 Actions 出包，网页"备份/刷写固件"升级 |
| 默认 IP / 密码 | 192.168.8.1 / 无 | 192.168.8.1 / `password` |

功能对齐的是 **精简版（Mini）** 的路线：常用插件 + 多拨 + Docker，不含 iStore 应用商店。iStore 需要 iStoreOS 的 feed 与内核补丁配合，硬塞进 ImmortalWrt 容易出问题，本工程没有集成；装软件直接用 `opkg` 或 Docker 即可。

一处已知缺失：原版的 **网络测速（netspeedtest）** 插件仓库已被 DMCA 下架（2026-02），代码无法获取，所以没有集成。需要测速用 `iperf3` 或 OpenClash 自带的节点测速代替。

**升级方式**：以后想更新，重跑一次 Actions，下载新包 → 系统 → 备份/升级 → 刷写固件，**不保留配置**升级最稳（跨版本尤其如此）。

---

## 五、增删插件

改两个地方，然后重跑 Actions 即可：

1. **`configs/packages.config`** —— 决定哪些包编进固件
   - 不要某功能 → 把对应 `CONFIG_PACKAGE_xxx=y` 改成 `=n` 或直接注释
   - 加新功能 → 加一行 `CONFIG_PACKAGE_luci-app-xxx=y`（包名不存在会被自动忽略，不会中断编译）

2. **`diy-part1.sh`** —— 决定从哪些第三方仓库拉代码
   - 格式：`fetch_pkg "目录名" "https://github.com/用户/仓库.git" 分支`
   - 拉取失败只会跳过并打印 `[跳过]`，不会让整个编译挂掉

### 想加 PassWall？

`diy-part1.sh` 里加一行：

```bash
fetch_pkg "luci-app-passwall" "https://github.com/xiaorouji/openwrt-passwall.git" main
fetch_pkg "passwall-packages" "https://github.com/xiaorouji/openwrt-passwall-packages.git" main
```

`configs/packages.config` 里加：

```
CONFIG_PACKAGE_luci-app-passwall=y
```

### 想加 AdGuardHome？

ImmortalWrt 官方源只提供 `adguardhome` 内核，没有 LuCI 界面，所以默认没编进去。在 `diy-part1.sh` **末尾**加一行，把它作为独立 feed 引入：

```bash
echo 'src-git adguard https://github.com/kenzok8/openwrt-packages.git;master' >> feeds.conf.default
```

再在 `configs/packages.config` 里启用：

```
CONFIG_PACKAGE_adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome=y
```

> `diy-part1.sh` 在 `feeds update` 之前执行，所以追加 feed 是安全的；未选中的包不会被编译，也不会拖慢构建。

### 想加 Intel 核显硬解（Jellyfin）

`configs/packages.config` 末尾有两行被注释掉了，取消注释即可。

---

## 六、排错

| 现象 | 原因 / 处理 |
|---|---|
| Actions 编译失败，日志里有 `package/xxx: No such file` | 那个第三方插件还没适配 24.10，在 `diy-part1.sh` 里删掉对应行 |
| 编译成功但没有 `.img.gz` | 检查 `configs/packages.config` 里 `CONFIG_GRUB_IMAGES=y` 和 `CONFIG_TARGET_IMAGES_GZIP=y` 是否被误改 |
| 刷完进不去系统 / 卡在 GRUB | BIOS 启动模式没设成 Legacy，或写盘时选错了盘 |
| 刷完网口不通 | N4200 部分机型主网卡是 Realtek 8111/8168，确认 `kmod-r8168` 已编入（x86 目标默认带） |
| LuCI 打开是白屏/报错 | 主题或插件版本不匹配，把 KuCat 相关两行注释掉重编，验证是否主题问题 |
| 磁盘不够 `No space left on device` | 工作流里"腾出磁盘空间"步骤失败，重跑一次；仍失败就把 `rootfs_size` 改小到 1024 |

编译失败时，Actions 会自动把 `openwrt/logs/` 打包成 artifact，下载下来看最后一个报错的包名，基本能直接定位。

---

## 七、工程结构

```
.
├── .github/workflows/build-x86.yml   # 云编译流水线
├── configs/packages.config           # 机型 + 包选择（最常改的文件）
├── diy-part1.sh                      # 拉第三方插件 + 铺 rootfs 覆盖文件
├── diy-part2.sh                      # 把 packages.config 注入 .config
└── files/                            # 直接落到固件里的文件
    ├── etc/banner                    # 登录欢迎信息
    └── etc/uci-defaults/99-ezopwrt   # 首次启动的默认配置
```

默认设置（IP、密码、时区、DNS、主题、DHCP 范围）都在 `files/etc/uci-defaults/99-ezopwrt` 里，想改开箱即用的配置直接改这个文件。

关于源码分支：默认 `openwrt-24.10`（6.6 内核，与 EzOpWrt 现役版本同代，第三方插件适配最全）。`openwrt-25.12` 也能编，但 sirpdboy 那批插件在 25.12 上适配未必完整，可能出现插件被静默跳过的情况，建议先跑通 24.10 再折腾。

---

## 八、旁路由模式（只做旁路由时看这里）

旁路由 = 这台机器不拨号、不接触公网，只挂在主路由的局域网里，替指定设备做网关。好处有两个：**不占用主路由的 PPPoE 和多拨**，而且**WAN 口不暴露在公网**，扫描器根本扫不到它。

### 切换方法

刷完固件、能进 LuCI 之后，把 `extras/bypass-mode.sh` 传到路由器上执行（先把 IP 换成你实际的）：

```sh
scp extras/bypass-mode.sh root@192.168.8.1:/root/
ssh root@192.168.8.1 'sh /root/bypass-mode.sh 192.168.1.1 192.168.1.2'
```

脚本会自动完成：LAN 改静态 IP + 指网关/DNS 到主路由、关本机 DHCP（避免两台 DHCP 抢着分配）、关 WAN/WAN6、LAN 区域开 masquerade 与转发、关 UPnP、DNS 只对局域网服务。

执行完 SSH 会断开，用新 IP 重新连。

### 让它真正生效

旁路由装好后，内网设备的「网关」必须指向它，否则流量根本不过去。两种做法：

- **全屋生效**：主路由 → DHCP 设置 → 把「默认网关」和「DNS」都改成旁路由 IP。所有设备下次续租自动切换。
- **按设备生效**：只给需要的机器手动设网关和 DNS，其余照旧走主路由直连。

### 三个容易踩的坑

1. **DNS 环路**：主路由的 DNS 不能又指回旁路由，否则两边互指，解析变慢甚至全挂。
2. **插件要开 DNS 劫持**：OpenClash / HomeProxy 的「DNS 转发」或「劫持」必须打开，不然分流规则匹配不上，表现为「能上国内网站，国外站点不生效」。
3. **别开第二个 DHCP**：脚本已经关了 `dhcp.lan`，如果你后来手动又打开，内网会随机出现拿不到 IP 或网关指错的问题。

### 单臂的带宽

两个网口只用一个也够：网口是全双工，进和出各 1Gbps，不会减半。但如果内网互访（NAS 拷文件）和上网流量走同一根线，实际吞吐会互相挤占，这种情况把第二个网口也桥进 `br-lan` 分担即可。
