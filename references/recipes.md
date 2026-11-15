# 实战配方

每条都是真机跑过的路径，连坑一起记。

## 1. 微信：给某人发消息（视觉通道）

`look --app 微信` 会判成 `visual`。全程坐标 + 剪贴板。

```bash
SH="surehand"        # 技能自带的入口；没接进 PATH 时用 python3 <技能目录>/scripts/cli.py
$SH do activate --app 微信
$SH do key --combo "cmd+1"                 # 回聊天视图（cmd+2 通讯录 / cmd+3 收藏 / cmd+4 朋友圈）
$SH tap --app 微信 --x 120 --y 20           # 点搜索框
$SH do paste --text "联系人名"
$SH do key --combo "return"                # 回车进首个结果
$SH shot --app 微信                         # 复核：标题栏是不是这个人
$SH tap --app 微信 --x 579 --y 575          # 点输入框（不点这里写不进字）
$SH do paste --text "正文"
$SH shot --app 微信                         # 复核：文字完整、无残留
$SH do key --combo "return"
```

要点：
- 搜索面板有时不弹出，`return` 会用首个匹配结果 —— **发送前必须从聊天标题核对联系人**。
- 座标是窗口内点数，窗口挪了也不受影响。不要用 `clickat` 的屏幕绝对坐标。

## 2. 微信：朋友圈点赞

```bash
$SH do activate --app 微信
$SH do key --combo "cmd+4"
$SH scroll --app 微信 --x 600 --y 400 --dy -6 --times 3
$SH shot --app 微信
# 找到目标动态 → 点右下角「••」→ 弹 [♡ 赞][评论] → 点「赞」
$SH shot --app 微信      # 复核：动态下方出现灰底「♡ 自己的昵称」
```

悬停（`hover`）**不会**唤出赞按钮，必须点「••」。

## 3. 抖音：取最新视频的链接

1. AX 树为空，全程视觉通道。
2. **置顶不等于最新**：本次实测三条置顶分别是 2024-11-20、2023-02-24、2020-03-09，最新那条排第 4 位。
   逐个打开视频页，读左下角 `@作者 · N天前` 才可靠。
3. 分享入口在右侧图标栏（♡ 点赞 / 💬 评论 / ⭐ 收藏 / ↗ 分享 / 听抖音）。
4. 分享面板的「分享给朋友」**只搜互关好友**，非好友一律「没有搜索到朋友」；此时点「复制链接」。
5. 剪贴板形如 `… https://v.douyin.com/xxxx/ 复制此链接，打开Dou音搜索…`，取中间 URL。

## 4. 浏览器：登录表单（结构通道）

```bash
$SH do goto --url https://example.com/login
$SH look --web
$SH do fill --web --text 账号 --text-value "dingweiping"
$SH do fill --web --text 密码 --text-value "……"
$SH do click --web --text 登录
$SH do eval --text "document.title"        # 断言登录后的页面
```

要点：
- `--text` 匹配的是可访问名（aria-label → placeholder → label → 文本），对输入框也有效。
- 用 `w:N` 的 ref 跨进程操作时，会自动按记下的身份复核一次；编号被复用会改按身份找。
- 页面一跳转，ref 全部作废（`REF_STALE`），重新 `look --web`。

## 5. 原生应用：靠 `AXIdentifier` 精确点

计算器这类应用按钮**没有可见名字**（标签是画上去的），但有稳定标识：

```bash
$SH look --app Calculator
#   e4 | Button | #Delete @520,629 48x48
$SH do click --app Calculator --id AllClear
```

`--id` 比 `--name` 稳：文案会随语言和改版变，identifier 不变。

**但 identifier 也可能随状态变**：计算器在「有输入」时是 `Clear`（C），空的时候是 `AllClear`（AC）。
`NOT_FOUND` 时先 `look` 看当前标识，别硬试。

## 6. 慢树：先摸结构再钻

访达的 AX 属性是逐次跨进程取的，单节点约 36 ms，整窗 7~9 秒。

```bash
$SH look --app 访达 --depth 3              # 70 ms，只摸结构，不发证
#   · | Window | '下载' | #FinderWindow
#       · | Outline | #_NS:8
$SH look --app 访达 --from e2 --depth 7     # 从侧边栏钻进去，范围收窄
```

`--from` 接受 `handle`（显示为 `·`）—— 句柄能导航不能动手，这正是它存在的意义。

## 7. 多步混排

```json
[
  {"do": "activate", "app": "Calculator"},
  {"do": "click", "app": "Calculator", "id": "Seven"},
  {"do": "click", "app": "Calculator", "id": "Add"},
  {"do": "click", "app": "Calculator", "id": "Two"},
  {"do": "click", "app": "Calculator", "id": "Equals"},
  {"do": "goto", "url": "https://example.com", "web": true},
  {"do": "fill", "web": true, "text": "账号", "text-value": "丁伟平"},
  {"do": "click", "web": true, "ref": "w:3"},
  {"do": "eval", "web": true, "text": "document.getElementById('r').textContent"}
]
```

桌面上一步用 `{"do":"activate"...}`，网页步骤加 `"web": true`。
需要更硬的回执时给桌面点击加 `"prefer": "ax"`（+100 ms，换 `delivered`）。

## 8. 排错顺序

界面找不到东西时，按这个顺序查，别跳：

1. `$SH look --app X` —— 判成 `visual` 就别再试语义定位，直接走截图。
2. `$SH look --app X` 里的 `[不唯一 ×N]` —— 同名元素，补 `--role`/`--id`/`--contains`。
3. `$SH attrs --ref eN` —— 把元素全部属性导出来，看标签到底藏在哪个字段
   （常见：`AXHelp`、`AXTitleUIElement`、`AXIdentifier`）。
4. `$SH find --app X --text 关键词 --contains` —— 模糊找一下。
5. `$SH doctor` —— 权限、daemon 实例数、CDP 端口。

## 9. 已知的环境坑

| 现象 | 原因 | 做法 |
|---|---|---|
| CDP 报 `Connection refused` 或 502 | 全局 HTTP 代理把 127.0.0.1 也转出去了 | 强制 `no_proxy=127.0.0.1,localhost,::1`（已内置） |
| Chrome 起不来，日志 `GPU process isn't usable` | 无头/受限环境 GPU 沙箱失败 | 加 `--disable-gpu --no-sandbox --disable-dev-shm-usage` |
| 截图纯白 | 尾随窗口（layer=0、面积更大、onscreen=false） | 优先 `onscreen=true` 且标题非空的窗口（已内置） |
| 注入中文无反应 | Qt/CEF 忽略 CGEvent unicode | 用 `paste` |
| 点了没反应，日志却 ok | 坐标点击拿不到应用确认 | 就是 `uncertain`；复核界面，别重放 |
| 有多个 daemon 进程 | 老版本没有租约 | 现在 `flock` 独占；`doctor` 会报实例数 |

## 10. Windows：资源管理器里找文件

```bash
$SH activate --app explorer
$SH look --app explorer --depth 3          # 先摸结构，别一上来整窗遍历
$SH do click --app explorer --role edit --id 1001   # 地址栏的 AutomationId 通常是 1001
$SH do key --combo "ctrl+a"
$SH do paste --text "C:\Users\me\Documents"
$SH do key --combo "return"
```

资源管理器的 UIA 树很深，整窗遍历常常上千节点。`--depth 3` 先看清骨架，
再用 `--from` 钻进具体区域，比一次整窗快得多。

## 11. Windows：点不进去的三个原因，按顺序排

1. **目标窗口不是前台**。`activate` 先切；切换被拒会报 `FOREGROUND_REFUSED`——
   这是系统的前台锁，不是 bug。对策：让窗口自己弹出来（比如重新触发一次托盘菜单），
   或先手动切一次前台再跑。
2. **目标进程是管理员权限**。UIPI 会挡住普通权限进程的输入与 UIA 读取。
   这种窗口在 `apps` 里能看到，但 `look` 读出来的树是空的。
   对策：本工具也用管理员身份启动，或换一个非提权的等价操作路径。
3. **坐标偏了**。先确认 `shot` 出来的图与屏幕一致；若缩放屏上整体偏移，
   说明 DPI 感知没生效（正常情况下引擎启动时就设了）。

## 12. Windows：往自绘控件里写字

不少国产软件用自绘输入框，没有 ValuePattern。此时 `fill` 会自动退成
「聚焦 + 全选 + 输入」，返回 `uncertain / event_posted`。

这个回执是诚实的：键盘事件确实投进去了，但控件收没收下只有界面知道。
**下一步必须 `look` 或 `state` 复核**，不要因为 `ok` 为真就往下走——
`fill` 的 `ok` 在 `uncertain` 时是假的，判断要看 `delivery.state`。
