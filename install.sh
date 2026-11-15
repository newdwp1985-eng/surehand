#!/bin/sh
# Surehand 安装脚本（macOS / Linux）
#
# 它做三件事：把仓库放到技能目录、编译 macOS 引擎、跑一次环境体检。
# 不覆盖任何已存在的东西——目标目录有内容就停下来说清楚，让人自己决定。
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.workbuddy/skills/surehand"

echo "源目录：$SRC"
echo "目标：  $TARGET"

if [ "$SRC" = "$TARGET" ]; then
    echo "已经在技能目录里，跳过复制。"
elif [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    echo ""
    echo "目标已存在，没有动它。想重装的话先自己处理："
    echo "  mv \"$TARGET\" \"$TARGET.bak.\$(date +%s)\""
    echo "然后重跑本脚本。"
    if [ -L "$TARGET" ]; then
        echo "（它当前是个符号链接 → $(readlink "$TARGET")）"
    fi
    exit 1
else
    mkdir -p "$(dirname "$TARGET")"
    # 用符号链接而不是复制：git pull 之后立即生效，不用再同步一次。
    ln -s "$SRC" "$TARGET"
    echo "已创建符号链接。"
fi

case "$(uname -s)" in
    Darwin)
        if ! command -v swiftc >/dev/null 2>&1; then
            echo ""
            echo "缺 Swift 工具链。先跑：xcode-select --install"
            exit 1
        fi
        echo "编译 macOS 引擎（约 20 秒）……"
        "$TARGET/engine/macos/build.sh"
        ;;
    *)
        echo "非 macOS 平台，跳过引擎编译。"
        ;;
esac

echo ""
python3 "$TARGET/scripts/cli.py" up || true
echo ""
echo "装完了。接下来要授权："
echo "  系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制，把运行本脚本的终端勾上。"
echo ""
echo "自测：python3 $TARGET/scripts/selftest.py"
