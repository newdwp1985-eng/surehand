#!/bin/sh
# Surehand 安装脚本（macOS / Linux）
#
# 做四件事：把技能放到目标目录、把 `surehand` 接进 PATH、编译 macOS 引擎、跑一次体检。
#
# 用法：
#   ./install.sh                                   # 默认装到 ~/.workbuddy/skills/surehand
#   ./install.sh ~/.dsh/skills/surehand            # 装给 DeepSeek Harness
#   ./install.sh ~/.dsh/skills/surehand --link     # 用符号链接代替复制
#   ./install.sh ~/.dsh/skills/surehand --force    # 目标已存在也覆盖
#
# 默认用复制而不是符号链接：有些宿主的技能加载器会经过自己的文件服务，跨出允许根目录
# 的符号链接可能被拒；复制出来的真实目录不存在这个问题。想跟着 git pull 走的人用 --link。
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="${SUREHAND_TARGET:-$HOME/.workbuddy/skills/surehand}"
BINDIR="${SUREHAND_BIN_DIR:-$HOME/.local/bin}"
MODE=copy
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --link)  MODE=link ;;
        --copy)  MODE=copy ;;
        --force) FORCE=1 ;;
        -*)      echo "未知参数：$arg"; exit 2 ;;
        *)       TARGET="$arg" ;;
    esac
done

case "$TARGET" in
    /*) ;;
    *) echo "目标必须是绝对路径：$TARGET"; exit 2 ;;
esac

# 变量一律写成 ${VAR}：macOS 的 /bin/sh 是 bash 3.2，不是 UTF-8 感知的。
# 写成 $VAR 再接全角标点时，它会把该字符的首字节吃进变量名，结果变量展开为空、
# 标点也被削掉半个字节（实测：`$TARGET（` 输出成 `\xbc\x88`）。花括号能定住边界。
if [ "$MODE" = "link" ]; then MODE_LABEL="符号链接"; else MODE_LABEL="复制"; fi

echo "源目录：$SRC"
echo "目标：  ${TARGET}（${MODE_LABEL}）"

if [ "$SRC" = "$TARGET" ]; then
    echo "已经在目标目录里，跳过放置。"
elif [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    if [ "$FORCE" -ne 1 ]; then
        echo ""
        echo "目标已存在，没有动它。确认要覆盖就加 --force；想保留旧版就先自己挪走："
        echo "  mv \"$TARGET\" \"$TARGET.bak.\$(date +%s)\""
        [ -L "$TARGET" ] && echo "（它当前是个符号链接 → $(readlink "$TARGET")）"
        exit 1
    fi
    echo "目标已存在，--force：先挪走再重建。"
    if [ -L "$TARGET" ]; then
        rm -f "$TARGET"
    else
        mv "$TARGET" "$TARGET.bak.$(date +%s)"
    fi
elif [ "$MODE" = "link" ]; then
    mkdir -p "$(dirname "$TARGET")"
    ln -s "$SRC" "$TARGET"
    echo "已创建符号链接。"
fi

if [ "$MODE" = "copy" ] && [ "$SRC" != "$TARGET" ]; then
    mkdir -p "$TARGET"
    # 不带 .git 和已编译的二进制：目录干净，引擎留给首启动按需编译。
    ( cd "$SRC" && tar -cf - --exclude=.git --exclude=mccd --exclude=__pycache__ . ) \
        | ( cd "$TARGET" && tar -xf - )
    echo "已复制 $(find "$TARGET" -type f | wc -l | tr -d ' ') 个文件。"
fi

# 把 `surehand` 接进 PATH。指向目标目录里的那份壳，换机器、换宿主都不用改文档。
if mkdir -p "$BINDIR" 2>/dev/null; then
    chmod +x "$TARGET/bin/surehand" 2>/dev/null || true
    ln -sf "$TARGET/bin/surehand" "$BINDIR/surehand"
    echo "入口：  $BINDIR/surehand"
    case ":$PATH:" in
        *":$BINDIR:"*) ;;
        *) echo "  注意：$BINDIR 不在 PATH 里，需要自己加一行，或直接用完整路径。" ;;
    esac
else
    echo "没能写入 ${BINDIR}，跳过入口链接。"
fi

case "$(uname -s)" in
    Darwin)
        if ! command -v swiftc >/dev/null 2>&1; then
            echo ""
            echo "缺 Swift 工具链。先跑：xcode-select --install"
            echo "（不装也能用，只是首启动无法自动编译引擎。）"
            exit 1
        fi
        echo "编译 macOS 引擎……"
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
echo "  系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制，勾选真正运行命令的那个程序。"
echo "  在终端里跑就勾终端；由 DSH、WorkBuddy 之类的宿主代为执行，就勾宿主本身。"
echo ""
echo "自测：python3 $TARGET/scripts/selftest.py"
