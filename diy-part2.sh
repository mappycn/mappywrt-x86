#!/bin/bash
# ============================================================
# diy-part2.sh  第二段自定义
# 运行位置：./openwrt
# 职责：只做 .config 注入，其余默认配置都在 files/ 里直接维护
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIZE="${ROOTFS_SIZE:-2048}"

echo "==> 注入 .config（根分区 ${SIZE}MB）"
sed "s/__ROOTFS_SIZE__/${SIZE}/" "$SCRIPT_DIR/configs/packages.config" >> .config

# files/ 里的默认配置（banner、uci-defaults）由 diy-part1.sh 已铺好，
# 这里只做兜底，避免目录缺失导致后续 cp 失败
mkdir -p files/etc/uci-defaults

echo "==> 自定义完成，等待 make defconfig 解析"
