#!/bin/sh
# 编译 mccd 守护进程。零第三方依赖，只用系统自带的 Swift 工具链。
# Xcode Command Line Tools 即可：xcode-select --install
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin"
swiftc -O "$DIR/mccd.swift" -o "$DIR/bin/mccd"
chmod +x "$DIR/bin/mccd"
echo "built: $DIR/bin/mccd"
"$DIR/bin/mccd" --version 2>/dev/null || true
