---
name: surehand
display_name: Surehand 稳手
display_name_en: Surehand
slug: surehand
description: "操作本机电脑与浏览器的统一入口：先观察、再判断通道、再动手，每一步都带回执。原生控件走可访问性树（macOS AX / Windows UIA），读到的是结构与唯一令牌；自绘界面（微信、抖音、Qt/CEF）结构为空时自动判定为视觉通道，用窗口相对坐标 + 剪贴板；网页走 CDP。凡是需要点按钮、填表、读界面、发消息、点赞、转发、翻列表、跑多步流程的任务都先用本技能。触发词：操作电脑、帮我点一下、在微信里发消息、朋友圈点赞、转发抖音、填表、读界面、桌面自动化、浏览器操作、computer use。"
description_zh: "操作本机电脑与浏览器的统一入口：先观察、再判断通道、再动手，每一步都带回执。原生控件走可访问性树（macOS AX / Windows UIA），读到的是结构与唯一令牌；自绘界面（微信、抖音、Qt/CEF）结构为空时自动判定为视觉通道，用窗口相对坐标 + 剪贴板；网页走 CDP。凡是需要点按钮、填表、读界面、发消息、点赞、转发、翻列表、跑多步流程的任务都先用本技能。"
description_en: "One entry point for driving a real desktop and a real browser: observe, decide which channel, then act — and every action comes back with a receipt. Native controls go through the accessibility tree (AX on macOS, UIA on Windows) yielding structure and unique tokens; self-drawn UIs (WeChat, Douyin, Qt/CEF) collapse to a visual channel using window-relative points and the clipboard; pages go through CDP. Use it for clicking buttons, filling forms, reading UIs, sending messages, liking posts, scrolling lists, and any multi-step routine."
version: 1.0.0
author: 波弟
category: 系统与桌面自动化
tags: [macos, windows, desktop, browser, accessibility, uia, cdp, automation, evidence, agent, computer-use]
platforms:
  - macos
  - windows
permission:
  - 辅助功能 / UI 自动化（读取界面结构、模拟点击）
  - 屏幕录制（视觉通道截图）
  - 本机进程与窗口枚举
  - 浏览器远程调试端口（CDP）
dependency:
  - "Python 3.8+（两端都要）"
  - "macOS：Swift 工具链（xcode-select --install），引擎首次使用时自动编译"
  - "Windows：系统自带 Windows PowerShell 5.1（不支持 PowerShell 7）"
  - "浏览器通道：Chrome / Edge / Chromium 任一"
allowed-tools: Bash
---

# Surehand — 会看、会判断、会认账的操作层

名字里的 sure 指的不是「保证成功」，而是**每一步都说得清自己凭什么**：
看到了什么、凭什么认为能点、点完算不算送到。不确定的时候它说不确定，不假装成功。

```bash
SH="python3 ~/.workbuddy/skills/surehand/scripts/cli.py"
$SH up                                  # 起通道，看权限
$SH look --app 微信                      # 看界面，它会告诉你该走哪条路
$SH do click --ref d:e12                 # 动手，用发过证的令牌
```

## 0. 装

**macOS**：需要 Xcode 命令行工具。引擎在第一次 `up` 时自动编译，不用手动 build。

```bash
xcode-select --install        # 只需一次
$SH up                        # 首次会自动编译 engine/macos（约 20 秒）
```

装完要在 **系统设置 → 隐私与安全性** 里给终端（或你跑 Python 的那个程序）两项授权：
**辅助功能**（读结构、模拟点击）和 **屏幕录制**（视觉通道截图）。少一项，对应通道降级。

**Windows**：什么都不用装，系统自带 Windows PowerShell 5.1 和 .NET 的 UIAutomation。

```powershell
python scripts\cli.py up
```

有一个前提容易踩：**必须是 Windows PowerShell 5.1，不能是 PowerShell 7（pwsh）**。
UIAutomationClient 程序集只在 .NET Framework 里有，pwsh 上加载不到。`up` 会直接告诉你当前用的是哪个。

还有一条：**以管理员身份运行的窗口（UAC 提升过的）对普通权限进程是不可见的**，
这是 Windows 的 UIPI 保护，不是本工具的限制。要操作它们，本工具也得用管理员身份启动。

## 1. 两个平台，同一套判断

| | macOS | Windows |
|---|---|---|
| 结构通道 | AX（Accessibility） | UIA（UIAutomation） |
| 输入注入 | CGEvent | SendInput |
| 端点 | AF_UNIX `/tmp/mccd-<uid>.sock` | 回环 TCP + 令牌 |
| 引擎 | `engine/macos/mccd.swift` | `engine/windows/wccd.ps1` |
| 快照速度 | 快（每属性约 0.1 ms） | 慢一个量级（每属性一次 COM 往返） |
| 三态精度 | 高（AX 会明确回答「没这个属性」） | 低（UIA 只抛异常，absent 与 unknown 界线更粗） |
| 角色名 | `AXButton` / `AXTextField` | `button` / `edit` |

角色名两边都认：写 `--role button` 或 `--role AXButton` 都行，客户端会翻成当前平台的叫法。

**Windows 的三态精度更低，这是硬限制**，不是偷懒。macOS 的 AX 会用 `attributeUnsupported`
告诉你「这个元素确实没有这个属性」，UIA 没有等价回答，只会在元素读不到时抛 COM 异常。
所以 Windows 侧出现的 `unknown` 基本只意味着「元素不见了」，而不是「属性不存在」。
在 Windows 上判断「某个字段是不是空的」，宁可多读一次 `state` 复核。

## 2. 三条判断，不要跳

### 判断一：这个界面属于哪一类

`look` 直接给结论，不用你猜：

| surface | 含义 | 怎么操作 |
|---|---|---|
| `structure` | 读得到完整结构（访达/资源管理器、计算器、原生对话框、开了 AX/UIA 的 Electron） | 用 `ref` 或 `--id` 精确操作 |
| `visual` | 结构面只有窗口框和红绿灯（微信 4.x、抖音、多数 Qt/游戏） | `shot` 拿几何 → `tap` 按**窗口内点数**点 → 写文字一律 `paste` |
| `partial` | 遍历没走完（`--depth` 限制、节点上限、或某个子树读不出来） | 只够摸结构，要动手先去掉限制或 `--from` 钻进去 |
| `web` | 网页 | `--web`，按可访问名/ref 操作 |

判据是「去掉窗口框和红绿灯之后还剩多少个**有意义**的目标」，不是节点数。
微信整窗 6 个节点会被判成 `visual`，计算器 35 个节点判成 `structure`。

### 判断二：这个令牌能不能动手

桌面快照里的元素按「能对它做什么」分三档，不是按「读得全不全」：

| 标记 | 条件 | 能做什么 |
|---|---|---|
| `ref`（如 `e12`） | 整窗遍历完成 + 身份唯一 + 字段全读到，**完整令牌** | 点击、填值、读值都行 |
| `[仅可填]` | 同上但身份有字段读不出，**受限令牌**（有机器标识兜底） | 只许 `fill` / `read`；点击报 `TOKEN_RESTRICTED` |
| `·e12`（带 `·`） | 没发证，只是个导航句柄 | 只能 `--from` 继续观察，动手被拒 |
| `[不唯一 ×N]` | 整窗里有 N 个同身份元素 | 补 `--role` / `--id` / `--contains` 收窄 |

受限令牌的存在是为了一类具体摩擦：输入框的值在空状态下常读作 unknown，按老口径一个令牌
都拿不到，人就退回按坐标盲输入。而填值走的是「直接设值」，不经坐标、不看可见性、不受遮挡，
风险模型跟点击根本不是一回事——所以放开填，继续禁点。

`[子树内唯一]` 是另一件事：用 `--from` 钻取出来的令牌，唯一性只在那个子树里证过，
动作返回里会带 `proven_in: subtree:e12`。

用 `--ref` 动手时默认做一次轻量复核（进程、身份、是否还挂在同一窗口）；
加 `--strict` 则整窗重数一遍身份，几十毫秒，写关键操作时值得。

### 判断三：这个结果算不算数

每个写动作都带 `delivery`：

| state | 含义 | 该怎么办 |
|---|---|---|
| `delivered` | 应用确认收到（Invoke/AXPress 返回成功，或观测到值变化） | 继续 |
| `not_delivered` | 确定没送到 | 按错误类别处理，别直接重放 |
| `uncertain` | 动作已发出，拿不到确认（坐标点击、粘贴、按键都是这类） | **先复核界面再决定**，不要重放 |

`retry` 独立于 `state`：`unsafe` 表示重放会变成两次投递。

退出码：`0` 已送达 / `1` 未送达 / `2` 不确定。批量的每一步标 `ok` / `unv` / `FAIL`。

## 3. 铁律

1. **先 look 再 do。** 没有观察过的界面不做动作；`ref` 只在最近一次快照内有效，过期报 `REF_STALE`，重看不猜。
2. **ref 是令牌，handle 不是。** 用 handle 动手会被 `HANDLE_NOT_TOKEN` 拒绝，这不是 bug，是设计。
   受限令牌（`[仅可填]`）能填不能点，被拒时按提示改用 `--app/--role/--id` 定位。
3. **不点不可达的东西。** 落点被别的窗口盖住时直接报 `OCCLUDED`，不盲点；先 `activate`。
4. **同名必须消歧。** 命中多个报 `AMBIGUOUS:n`，补条件，不按顺序取第一个。
5. **视觉通篇不算坐标，只算相对位置。** 图会被缩放，照抄截图上的像素必偏；`tap` 用的是窗口内点数，由窗口几何现算。
6. **写文字一律 `paste`。** Qt/CEF/自绘界面会忽略底层 unicode 注入，`type` 报成功但界面没反应。
   原生输入框用 `fill`（直接设值，最快也最稳）。
7. **不确定就说不确定。** 不允许把 `uncertain` 当成功汇报；复核之后再下结论。

## 4. 命令表

`SH="python3 ~/.workbuddy/skills/surehand/scripts/cli.py"`

| 目的 | 命令 |
|---|---|
| 起通道、看权限 | `$SH up [--launch]` |
| 环境体检 | `$SH doctor [--json]` |
| 起一个可调试的浏览器 | `$SH launch [--port 9222] [--url ...]` |
| 列出应用 | `$SH apps [--filter chrome]` |
| 切前台 | `$SH activate --app 文本编辑` |
| 观察桌面 | `$SH look --app 微信 [--depth 3] [--from e2]` |
| 观察网页 | `$SH look --web [--url-contains 关键词]` |
| 只找不动 | `$SH find --app 备忘录 --text 新建` / `--id Save` |
| 点（令牌） | `$SH do click --ref d:e12 [--strict] [--prefer ax\|cg]` |
| 点（身份） | `$SH do click --app 计算器 --role button --id Seven` |
| 点（窗口相对坐标） | `$SH tap --app 微信 --x 120 --y 20` |
| 填输入框 | `$SH do fill --ref d:e9 --text "内容"` |
| 往任意界面写文字 | `$SH do paste --text "中文内容"` |
| 组合键 | `$SH do key --combo "cmd+s"` 或 `--combo "ctrl+s,return"` |
| 滚动（结构面） | `$SH do scroll --ref d:e5 --dy 5` |
| 滚动（自绘列表） | `$SH scroll --app 抖音 --x 600 --y 400 --dy -6 --times 3` |
| 悬停 | `$SH hover --app 微信 --x 500 --y 300` |
| 截图（可叠网格） | `$SH shot --app 微信 [--grid] [--out /tmp/a.png]` |
| 读状态 | `$SH state --ref d:e12 [--strict]` |
| 诊断为什么找不到 | `$SH attrs --ref d:e4` 或 `--x 544 --y 653` |
| 网页导航 | `$SH do goto --url https://...` |
| 网页填充/点击 | `$SH do fill --web --text 账号 --text-value 丁伟平` / `$SH do click --web --ref w:3` |
| 网页读值 | `$SH do eval --text "document.title"` |
| 跑多步 | `$SH run steps.json` |

ref 前缀：`d:e12` 桌面、`w:3` 网页。裸编号默认按桌面解析。

**句柄带 `·` 前缀**（`·e2`）。句柄是「看过但没发证」的元素，只能拿去 `--from` 继续观察，
动手会被 `HANDLE_NOT_TOKEN` 拒绝。显示上区分开，是为了避免一眼扫过去把「看过」当成「点得」。

组合键里的修饰键按平台自动换：`cmd` 在 Windows 上等同于 `ctrl`，`option` 等同 `alt`。
所以同一份步骤文件两边都能跑。

## 5. 什么时候用哪条通道

```
目标在浏览器页面里？
├── 是 → --web（CDP：DOM 定位 2~30 ms，可读值可断言）
└── 否 → 桌面
    ├── look 报 structure → ref / --id / fill / Invoke
    └── look 报 visual    → shot → tap（窗口内点数）→ paste
```

### 点击走哪条腿

`auto`（默认）**优先应用层动作**（macOS 的 AXPress / Windows 的 Invoke），不是因为快——
它反而要付一次跨进程 IPC——而是因为它给确定回执 `delivered / ax_action_result`。
坐标点击毫秒级就返回，但只能给 `uncertain / event_posted`，接下来必须 `look` 复核，
那又是几十毫秒，还得赌落点没被遮挡。这笔账算下来，应用层动作更划算，而且不会点错位置。

`--prefer cg` 是显式换出速度：同一窗口内连续几十次点击、或目标不支持应用层动作时才用。

应用层动作返回失败（有应用会返回错误但仍可响应点击）时，`auto` 会自动降级到坐标点击，
方法记作 `cgevent_after_axpress_fail`。

浏览器**外壳**（地址栏、书签、下载气泡、扩展弹窗）不属于页面，仍走桌面通道。

## 6. 回执怎么读

```json
{"ok": true, "via": "ref", "method": "invoke",
 "delivery": {"state": "delivered", "retry": "unsafe", "witness": "ax_action_result"}}
```

`witness` 是判定依据，只有四种：

- `ax_action_result` —— 应用对动作回了成功，最强
- `value_delta` —— 动作前后值变了，强
- `event_posted` —— 事件已投进系统，弱（坐标点击、按键、粘贴）
- `unreported` —— 没有投递语义（观察类动作）

## 7. 批量

`$SH run steps.json`，桌面步骤共用一个连接，网页步骤共用一个 CDP 会话，可混排：

```json
[
  {"do": "activate", "app": "Calculator"},
  {"do": "click", "app": "Calculator", "id": "Seven"},
  {"do": "click", "app": "Calculator", "id": "Add"},
  {"do": "click", "app": "Calculator", "id": "Two"},
  {"do": "click", "app": "Calculator", "id": "Equals"},
  {"do": "goto", "url": "https://example.com", "web": true},
  {"do": "fill", "web": true, "text": "账号", "text-value": "丁伟平"},
  {"do": "click", "web": true, "ref": "w:3"}
]
```

每一步可加 `"continue": true` 表示失败也继续。默认遇 `FAIL` 停。

## 8. 边界（说清楚，不硬撑）

- **自绘界面只有坐标精度**：微信、抖音这类界面改版就要重新对位置。能操作，但不是确定性的。
- **登录窗口 / FileVault / 授权弹窗 / DRM 窗口**：软件层没有权限，够不到。
- **Windows 的 UIPI**：管理员权限的窗口对普通进程不可见，反之亦然（提权进程能看到普通窗口）。
- **Windows 的 UIA 三态更粗**：absent 与 unknown 的界线不如 macOS 清晰，关键判断多做一次复核。
- **Windows 引擎单线程串行**：UIA 客户端本来就要求串行调用，所以同一连接严格按序；
  但一个慢快照会挡住同时进来的其他请求。
- **多显示器**：Windows 侧按虚拟桌面归一化坐标，副屏可点；
  macOS 侧坐标用全局显示系，未做逐屏换算。
- **慢树**：访达这类应用单属性往返就要 30~40 ms，整窗遍历 7~9 秒。这是 macOS AX 的固有问题，
  不是实现问题；用 `--depth` 摸结构、`--from` 钻取来绕。
- **`AXObserver` 未接**：`waitchange` 仍是轮询。
- **仅 macOS 与 Windows**。Linux 会明确报「不支持的平台」，不会假装能跑。

## 9. 参考

- `references/contract.md` —— 输出契约：三态、令牌三档、投递、错误码、退出码
- `references/method.md` —— 为什么这么设计：借鉴了什么、拒绝了什么、代价在哪
- `references/recipes.md` —— 实战配方与踩过的坑（微信/抖音/浏览器/慢树/Windows 缩屏）
- `docs/architecture.md` —— 分层与数据流
- 引擎：`engine/macos/mccd.swift`、`engine/windows/wccd.ps1`

自测：

```bash
python3 scripts/selftest.py                       # macOS / Windows 通用，17 项
powershell -File engine\windows\verify.ps1        # Windows 专属验收，12 步
```
