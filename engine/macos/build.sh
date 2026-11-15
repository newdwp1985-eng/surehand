#!/bin/sh
# 编译 mccd 守护进程。零第三方依赖，只用系统自带的 Swift 工具链。
# Xcode Command Line Tools 即可：xcode-select --install
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin"
swiftc -O "$DIR/mccd.swift" -o "$DIR/bin/mccd"
chmod +x "$DIR/bin/mccd"
echo "built: $DIR/bin/mccd"
# 这里不要顺手跑一次 mccd 验证版本：mccd 没有 --version 分支，
# 直接执行等于启动一个前台 daemon，会把调用方（首次 up 的自动编译）挂住。
