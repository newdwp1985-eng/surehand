<p align="center">
  <img src="docs/icon.png" width="112" alt="Surehand">
</p>

# Surehand

**让 Agent 操作电脑时说得清「凭什么」。**

```bash
$ surehand look --app 计算器
[计算器] '计算器'  structure  整窗 35 节点，28 个可操作令牌  49 ms
e1 | Window | '计算器' | #main | @510,496 230x408
  e7 | Button | #Seven | @520,683 48x48
  ...

$ surehand do click --ref d:e7
{"ok": true, "via": "ref", "method": "axpress",
 "delivery": {"state": "delivered", "retry": "unsafe", "witness": "ax_action_result"}}
```

不是「我点了」，是「我点了，而且应用回了话」。

---

## 这跟别的自动化库差在哪

`pyautogui` 给你坐标，`Playwright` 给你选择器，`pynput` 给你按键。它们都能让程序动起来。
但它们都不回答一个问题：**你凭什么认为刚才那一下点对了，而且真送到了？**

Surehand 把这件事拆成三个可判定的问题，每个都有明确答案，而不是一个 `True`：

| 问题 | 它给什么 | 别的库给什么 |
|---|---|---|
| 这个元素现在能不能动手 | 三档令牌：完整 / 受限 / 只是句柄（只能看不能点） | 一个可能已经失效的坐标或选择器 |
| 我到底找到几个 | `witness: 1`，整窗数出来的；多个就报 `AMBIGUOUS:n`，绝不取第一个 | 通常取第一个，或者抛异常 |
| 那一下送到了吗 | `delivered` / `not_delivered` / `uncertain`，附判定依据 | 函数没抛异常就算成功 |

第三行是差异最大的地方。坐标点击在系统层面 0.2 ms 就返回了，但「事件投进去了」和
「界面收到了」是两件事。把它俩混成一个 `True`，就是所有「偶尔点错两次」的总根源。

Surehand 的坐标点击老实报 `uncertain`，并独立给出 `retry: safe|unsafe`——
因为重放一次可能变成两次投递。这不是保守，是把账算清楚。

---

## 能操作什么

```
                      ┌─────────────────────────────┐
   你要做的事          │  判断层（纯函数，可单测）      │
   ─────────          │  三态合并 · 令牌分档 · 投递分级 │
                      └──────────┬──────────────────┘
                                 │  同一个 JSON-lines 协议
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
      ┌───────────────┐  ┌───────────────┐  ┌──────────────┐
      │ 结构通道        │  │ 视觉通道        │  │ 网页通道      │
      │ AX / UIA      │  │ 窗口内相对坐标   │  │ CDP          │
      │ 读得到就精确    │  │ 读不到就靠图     │  │ DOM 级精确    │
      └───────┬───────┘  └───────┬───────┘  └──────┬───────┘
              │                  │                 │
      ┌───────▼──────────────────▼───────┐         │
      │ 引擎（常驻，两端各一份）             │         │
      │ macOS: mccd.swift  (AX + CGEvent) │         │
      │ Windows: wccd.ps1  (UIA + SendInput)│        │
      └──────────────────────────────────┘         │
                                          Chrome / Edge / Chromium
```

原生控件（访达、资源管理器、计算器、原生对话框、开了可访问性的 Electron）走**结构通道**：
读得到完整的可访问性树，拿得到带证据的唯一令牌。

自绘界面（微信 4.x、抖音、多数 Qt / 游戏）走**视觉通道**：结构读出来只有一个窗口框和几个
红绿灯，此时自动判定 `visual`，改用截图 + 窗口内相对坐标 + 剪贴板。这类界面能操作，
但只有坐标精度——软件改版就要重新对位置，这不是缺陷，是这类界面的客观限制。

网页走 **CDP**：DOM 定位 2~30 ms，可读值、可断言。

---

## 装

### macOS

需要 Xcode 命令行工具（引擎用 Swift 写的，首次使用时自动编译）：

```bash
xcode-select --install          # 只需一次
git clone https://github.com/<you>/surehand.git ~/.workbuddy/skills/surehand
cd ~/.workbuddy/skills/surehand
python3 scripts/cli.py up       # 首次会自动编译 engine/macos，约 20 秒
```

然后到 **系统设置 → 隐私与安全性** 里给你的终端两项授权：

- **辅助功能** —— 读界面结构、模拟点击
- **屏幕录制** —— 视觉通道截图

少一项，对应通道会降级，`up` 会直接告诉你缺哪个。

### Windows

需要 Python 3.8+。**其余零依赖**——系统自带的 Windows PowerShell 5.1 就够了。

```powershell
git clone https://github.com/<you>/surehand.git $env:USERPROFILE\.workbuddy\skills\surehand
cd $env:USERPROFILE\.workbuddy\skills\surehand
python scripts\cli.py up
```

> **Windows 侧说明（读之前请先看这段）**
>
> 引擎（`engine/windows/wccd.ps1`）已完整实现，但**作者手上没有 Windows 机器，
> 未做过实机验证**。它的协议、发证规则、错误码与 macOS 侧逐字对齐，逻辑经过静态审查，
> 但「能在真实 Windows 上跑」这件事需要在这台机器上验证：
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File engine\windows\verify.ps1
> ```
>
> 这个脚本会起一个记事本当靶子，把 ping / apps / snapshot / 发证自洽 / fill / read /
> state / 句柄拦截 / 截图 / 错误契约逐项打一遍，写出 `verify-report.json`。
> 全绿之前，请把 Windows 侧当作 **beta**。
>
> 另外两个硬约束：必须是 **Windows PowerShell 5.1**（`pwsh` 上没有 UIAutomation 程序集）；
> 管理员权限的窗口受 UIPI 保护，普通进程点不进去。

### 浏览器通道（可选）

```bash
python3 scripts/cli.py launch          # 起一个带调试端口的 Chrome（独立 profile）
```

Chrome 136+ 对默认 profile 禁用了 `--remote-debugging-port`，所以必须用独立
`--user-data-dir`。代价是那个窗口里没有你原来的登录态。

---

## 用

```bash
SH="python3 scripts/cli.py"

$SH look --app 微信                    # 看界面，它直接告诉你该走哪条路
$SH look --web                         # 看网页
$SH do click --ref d:e12               # 用发过证的令牌
$SH do click --app 计算器 --role button --id Seven   # 或按身份定位
$SH tap --app 微信 --x 120 --y 20      # 视觉通道：窗口内相对坐标
$SH do paste --text "中文内容"          # 往任意界面写文字
$SH run steps.json                     # 多步混排（桌面 + 网页）
```

完整命令表与判断规则见 [SKILL.md](SKILL.md)。

### 三条判断，写在文档里也写在代码里

1. **这个界面属于哪一类** —— `structure` / `visual` / `partial` / `web`。
   判据是「去掉窗口框和红绿灯后还剩多少有意义的目标」，不是节点数。
2. **这个令牌能不能动手** —— 完整令牌全放行；受限令牌只许填值；句柄只能继续观察。
3. **这个结果算不算数** —— `delivered` / `not_delivered` / `uncertain`，附判定依据。

### 两条铁律最容易被违反

- **先 look 再 do。** `ref` 只对最近一次快照有效，过期报 `REF_STALE`。重看不猜。
- **不确定就说不确定。** `uncertain` 不是失败，也不是成功，是第三种结局。

---

## 平台能力矩阵

| 能力 | macOS | Windows |
|---|---|---|
| 结构通道 | AX | UIA |
| 输入注入 | CGEvent | SendInput |
| 快照速度（35 节点） | 50~130 ms | 未实测（UIA 每属性一次 COM 往返，预计慢一个量级） |
| 三态精度 | 高（AX 会明确回答「没这个属性」） | 低（UIA 只抛异常，absent/unknown 界线更粗） |
| 角色名 | `AXButton` / `AXTextField` | `button` / `edit` |
| 坐标归属 | 全局显示系，未做逐屏换算 | 虚拟桌面归一化，副屏可点 |
| DPI 缩放 | 系统自动 | 引擎启动时设 `SetProcessDpiAwareness(2)` |
| 并发模型 | 每连接一线程 | 单线程串行轮转（UIA 要求串行） |
| 单实例 | `flock` 独占锁 | 命名互斥体 |
| 端点保护 | AF_UNIX + 内核 uid 权限 | 回环 TCP + 32 字节令牌 + 文件 ACL |

角色名两端都收：写 `--role button` 或 `--role AXButton` 都行，客户端会翻成当前平台的叫法。

---

## 实测

macOS 26.5.1 / M4 / 16 GB，2026-11：

| 场景 | 结果 |
|---|---|
| 计算器整窗（37 节点） | 75~130 ms，发证 28/29 |
| Chrome 窗口（789 访问） | 145 ms，发证 376，扣证 114（同名导航项） |
| 微信整窗（6 节点） | 12 ms，判 `visual`，发证 0（正确地不发证） |
| 访达·下载（205 节点） | 7~9 秒（每属性往返 36 ms，AX 固有） |
| 访达 `--depth 3` | 67~73 ms（比整窗快 8.3 倍） |
| 应用层点击回执（AXPress） | 96~123 ms，`delivered` |
| 坐标点击 | 12~25 ms，`uncertain` |
| 混排 11 步（5 桌面 + 3 网页） | 2.26 秒 |
| 并发冷启动 8 个引擎 | 1 个存活，7 个退让 |

自测 17 项全过（网页类 2 项在无浏览器环境自动跳过，不计失败）：

```bash
python3 scripts/selftest.py
```

---

## 边界（不硬撑）

- **自绘界面只有坐标精度**：微信、抖音这类界面改版就要重新对位置。
- **登录窗口 / FileVault / 授权弹窗 / DRM 窗口**：软件层没有权限，够不到。
- **Windows UIPI**：管理员权限窗口对普通进程不可见，反之亦然。
- **慢树是 AX 的固有代价**：访达单属性往返 36 ms，不是实现问题。用 `--depth` 和 `--from` 绕。
- **`AXObserver` 未接**：`waitchange` 仍是轮询。
- **只覆盖 macOS 与 Windows**。Linux 会明确报 `UNSUPPORTED_PLATFORM`，不假装能跑。

---

## 设计来源

三态证据、令牌证明、投递语义这三件事，来自对 [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop)
（Rust，21k stars）的逆向分析，以及我们在微信、抖音、访达上实打实踩过的坑。
具体借鉴了什么、拒绝了什么、代价在哪，见 [references/method.md](references/method.md)。

---

## License

MIT。用、改、商用都行，出问题别找我。
