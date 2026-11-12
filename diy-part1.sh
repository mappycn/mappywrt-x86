#!/bin/bash
# ============================================================
# diy-part1.sh  第一段自定义：拉取第三方插件
# 运行位置：./openwrt
# 说明：第三方插件全部直接放进 package/ezopwrt/，不走 feeds，
#       任何一个仓库拉取失败都只跳过，不会导致整个编译中断。
# ============================================================
set -u

PKG_ROOT="package/ezopwrt"
mkdir -p "$PKG_ROOT"

# 国内网络如需加速，可填镜像前缀，例如：
#   CLONE_PREFIX="https://ghfast.top/"
CLONE_PREFIX="${CLONE_PREFIX:-}"

try_branch() {
    local url="$1" dest="$2" branch="$3"
    rm -rf "$dest"
    if git clone --depth=1 -b "$branch" "$url" "$dest" 2>/dev/null && [ -d "$dest/.git" ]; then
        return 0
    fi
    rm -rf "$dest"
    return 1
}

# 同一分支重试 3 次（GitHub 偶发 TLS 握手失败），再逐个回退其他分支
try_clone() {
    local url="$1" dest="$2" wanted="$3" b n
    for n in 1 2 3; do
        try_branch "$url" "$dest" "$wanted" && return 0
        sleep 3
    done
    for b in main master lua; do
        [ "$b" = "$wanted" ] && continue
        for n in 1 2; do
            try_branch "$url" "$dest" "$b" && return 0
            sleep 3
        done
    done
    return 1
}

# fetch_pkg <名字> <仓库地址> <首选分支>
fetch_pkg() {
    local name="$1" repo="$2" branch="${3:-main}"
    local tmp="/tmp/pkgsrc/$name"
    mkdir -p /tmp/pkgsrc
    rm -rf "$tmp" "$PKG_ROOT/$name"

    if ! try_clone "${CLONE_PREFIX}${repo}" "$tmp" "$branch"; then
        echo "  [跳过] $name 拉取失败（不影响其他插件）"
        return 0
    fi

    if [ -f "$tmp/Makefile" ]; then
        # 单包仓库：整个仓库就是一个 package
        mv "$tmp" "$PKG_ROOT/$name"
        echo "  [OK]   $name"
    else
        # 多包仓库：把含 Makefile 的子目录逐个搬出来（如 lucky + luci-app-lucky）
        local d moved=0
        for d in "$tmp"/*/; do
            [ -f "${d}Makefile" ] || continue
            mv "$d" "$PKG_ROOT/$(basename "$d")"
            echo "  [OK]   $(basename "$d")"
            moved=1
        done
        [ "$moved" = "0" ] && echo "  [跳过] $name 中没有找到 Makefile"
        rm -rf "$tmp"
    fi
}

echo "==> 拉取 sirpdboy 插件体系（EzOpWrt 的核心差异化功能）"
fetch_pkg "luci-theme-kucat"        "https://github.com/sirpdboy/luci-theme-kucat.git"        master
fetch_pkg "luci-app-kucat-config"   "https://github.com/sirpdboy/luci-app-kucat-config.git"   master
fetch_pkg "luci-app-advanced"       "https://github.com/sirpdboy/luci-app-advanced.git"       master
fetch_pkg "luci-app-advancedplus"   "https://github.com/sirpdboy/luci-app-advancedplus.git"   main
fetch_pkg "luci-app-netwizard"      "https://github.com/sirpdboy/luci-app-netwizard.git"      main
fetch_pkg "luci-app-partexp"        "https://github.com/sirpdboy/luci-app-partexp.git"        main
fetch_pkg "luci-app-ddns-go"        "https://github.com/sirpdboy/luci-app-ddns-go.git"        main
fetch_pkg "luci-app-lucky"          "https://github.com/sirpdboy/luci-app-lucky.git"          main
fetch_pkg "luci-app-taskplan"       "https://github.com/sirpdboy/luci-app-taskplan.git"       main
fetch_pkg "luci-app-poweroffdevice" "https://github.com/sirpdboy/luci-app-poweroffdevice.git" master
fetch_pkg "luci-app-eqosplus"       "https://github.com/sirpdboy/luci-app-eqosplus.git"       main
fetch_pkg "luci-app-timecontrol"    "https://github.com/sirpdboy/luci-app-timecontrol.git"    main
fetch_pkg "luci-app-watchdog"       "https://github.com/sirpdboy/luci-app-watchdog.git"       main

# 注意：sirpdboy/luci-app-netspeedtest 已于 2026-02 被 DMCA 下架，无法再拉取。
# 需要测速功能可以用 luci-app-openclash 自带的测速，或装 iperf3。

echo "==> 拉取科学上网插件"
fetch_pkg "luci-app-openclash" "https://github.com/vernesong/OpenClash.git" master

echo "==> 拉取结果"
find "$PKG_ROOT" -maxdepth 2 -name Makefile -printf '  - %h\n' 2>/dev/null | sed "s#$PKG_ROOT/##"

echo "==> 预置本地文件（作为 rootfs overlay）"
if [ -d "$GITHUB_WORKSPACE/files" ]; then
    cp -rf "$GITHUB_WORKSPACE/files" .
    echo "  已复制 files/ → openwrt/files/"
fi
