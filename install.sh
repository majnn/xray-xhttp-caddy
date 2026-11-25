#!/usr/bin/env bash
# Xray (VLESS + XHTTP) + Caddy 一键安装并启动管理菜单

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/majnn/xray-xhttp-caddy/main"
TARGET_BIN="/usr/local/bin/xmenu"
ALIAS_BIN="/usr/local/bin/xh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "错误: 请使用 root 权限运行本脚本 (例如: sudo bash ...)" >&2
    exit 1
fi

echo "正在下载 xmenu 管理脚本..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${RAW_BASE}/xmenu.sh" -o "$TARGET_BIN"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TARGET_BIN" "${RAW_BASE}/xmenu.sh"
else
    echo "未检测到 curl 或 wget，正在尝试通过 apt 安装 curl..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl
    curl -fsSL "${RAW_BASE}/xmenu.sh" -o "$TARGET_BIN"
fi

# 防御性去除可能存在的 CRLF
sed -i 's/\r$//' "$TARGET_BIN"
chmod +x "$TARGET_BIN"
ln -sf "$TARGET_BIN" "$ALIAS_BIN"

echo "安装完成！日常可通过输入 xmenu 或 xh 打开管理菜单。"

if [[ -r /dev/tty && -w /dev/tty ]]; then
    exec "$TARGET_BIN" </dev/tty
fi
