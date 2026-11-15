# AGENTS.md — 给任何 coding agent 的接入说明

这个仓库不是某个宿主的插件，是一层可以独立运行的操作能力。三种接法，按你的宿主挑一种。

---

## 先搞清楚你在操作什么

Surehand 把「让 agent 操作电脑」拆成两段，中间用一份证据隔开：

- **观察**（`look`）：把窗口读成一棵带身份和几何的树，逐个判断该不该发令牌。
- **动作**（`do` / `tap`）：只用观察发出的令牌动手，返回「送达 / 未送达 / 不确定」。

关键约定，违反了就会出错：

1. **令牌不是编号，是凭证。** `d:e12` 只在它被发出的那次观察里成立。编号在本进程内单调递增、永不复用——拿旧令牌动手会得到 `REF_STALE`，而不是悄悄点到别的元素上。
2. **`delivery.state` 才是结论。** `delivered` 才算成；`uncertain` 表示事件已发出但没拿到确认，**必须再 `look` 复核**，不要直接重放写操作。
3. **判不准就报 `Unknown`，不猜。** 自绘界面（微信、抖音、Qt/CEF）读不到元素时，`look` 会明说走视觉面，此时用 `shot` + `tap`，不要硬找 role。

---

## 接法一：MCP（推荐，一次配置全宿主通用）

```bash
python3 /path/to/surehand/scripts/mcp_server.py
```

这是标准 stdio JSON-RPC server，无第三方依赖。暴露 12 个工具：

| 工具 | 什么时候用 |
|---|---|
| `surehand_doctor` | 会话开头；确认权限、引擎、浏览器端口 |
| `surehand_apps` | 不确定应用名怎么写时 |
| `surehand_activate` | 点击前把窗口切到前台 |
| `surehand_look` | 动手前观察，拿令牌 |
| `surehand_find` | 只找不动，确认唯不唯一 |
| `surehand_do` | 点击 / 填值 / 读文本 / 组合键 / 粘贴 / 滚动 |
| `surehand_tap` | 视觉通道按窗口内点数点击 |
| `surehand_shot` | 截图取几何 |
| `surehand_state` | 单个元素的当前状态，比重快照便宜 |
| `surehand_web` | 网页：打开 / 点 / 填 / 读 / 求值 / 等待 |
| `surehand_launch_browser` | 起一个带调试端口的浏览器 |
| `surehand_run` | 跑多步计划文件 |

配置位置（以各家官方文档为准）：

- **Claude Code**：`claude mcp add surehand -- python3 /path/to/surehand/scripts/mcp_server.py`
- **Cursor**：`~/.cursor/mcp.json` 的 `mcpServers` 里加一条 `{"command": "python3", "args": ["/path/.../mcp_server.py"]}`
- **Codex**：`~/.codex/config.toml` 里加一个 `mcp_servers.surehand`，同样是 command + args
- **WorkBuddy**：`~/.workbuddy/mcp.json` 的 `mcpServers`，格式同上
- **其他**：任何支持 stdio MCP 的客户端都行，只要它能执行 `python3` 并读写管道

---

## 接法二：命令行（最适合 shell 型 agent）

```bash
SH=/path/to/surehand/bin/surehand      # 或 python3 /path/to/surehand/scripts/cli.py

$SH up                       # 拉起引擎，报权限状态
$SH apps                     # 看应用名
$SH look --app 微信           # 观察：会告诉你走结构面还是视觉面
$SH do click --ref d:e12     # 动手
$SH do read --ref d:e41      # 读文本，直接给值
```

所有命令都支持 `--json`，输出一个对象。退出码即结论：

| 退出码 | 含义 |
|---|---|
| 0 | 送达（`delivered`） |
| 1 | 未送达（`not_delivered`） |
| 2 | 不确定（`uncertain`，必须复核） |

---

## 接法三：技能格式（WorkBuddy / DeepSeek Harness 等）

把整个目录复制到宿主的技能根：

```bash
./install.sh ~/.dsh/skills/surehand         # DeepSeek Harness
./install.sh ~/.workbuddy/skills/surehand   # WorkBuddy
```

宿主会读 `SKILL.md` 的 frontmatter（`name` + `description`）。细节见 `SKILL.md`。

---

## 一次典型的完整调用

目标：在计算器里算 7+2 并读出结果。

```bash
$SH activate --app Calculator
$SH look --app Calculator                 # 拿到令牌，例如 Seven=#Seven
$SH do click --app Calculator --id Seven  # 按机器标识定位，比按名字稳
$SH do click --app Calculator --id Add
$SH do click --app Calculator --id Two
$SH do click --app Calculator --id Equals
$SH look --app Calculator | grep StaticText   # 读显示屏
```

注意第三步用的是 `--id`（AXIdentifier / AutomationId）而不是名字：计算器按钮的 `AXTitle` 是空的，真标识在 `AXIdentifier` 里，而且会随状态变（空输入时是 `AllClear`，有输入时变 `Clear`）。

---

## 平台差异（会咬人的三处）

| | macOS | Windows |
|---|---|---|
| 结构接口 | 辅助功能（AX） | UIAutomation |
| 角色名 | `AXButton` | `button` |
| 通道 | AF_UNIX + `flock` 单实例 | 回环 TCP + 32 字节令牌 |
| 特殊坑 | — | 必须先设 DPI 感知，否则缩放屏上所有点击系统性偏移 |

角色名两套都收：`--role button` 与 `--role AXButton` 等价，客户端会归一化。

Windows 侧**尚未在实机验证**过。仓库里带了 `engine/windows/verify.ps1`，跑一遍就知道。在那之前，Windows 当 beta 用。

---

## 出问题先看哪

1. `surehand_doctor`：权限、引擎版本、浏览器端口、仓库完整性，一次看全。
2. `look` 的第一行：它说 `structure` 还是 `visual`。说 `visual` 就别再找 role 了。
3. 错误码：`FAIL <CODE>（<kind>）<hint>`。`kind` 里有 `stale` / `ambiguous` / `env` / `bad_input` / `web` 等，各自的下一步不同。完整表在 `references/contract.md`。

---

## 不要做的事

- 不要在没有 `look` 的情况下凭记忆用令牌。
- 不要在 `uncertain` 之后直接重放写操作。
- 不要把截图里的像素坐标直接传给 `tap`：截图可能是 2x，`tap` 吃的是窗口内点数。`shot` 返回里带 `scale`。
- 不要为了「能跑」在代码里默认加 `--no-sandbox`。真需要时用 `SUREHAND_CHROME_FLAGS` 显式声明。
