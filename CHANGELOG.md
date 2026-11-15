# 变更记录

格式照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号照语义化版本。

## [1.0.1] — 2026-11-15

修掉「换了宿主就失效」的一类问题。引擎二进制没有变化，不需要重建。触发它的场景是
把技能装进 DeepSeek Harness：宿主不同，技能目录就不同，而文档里写死了绝对路径。

### 新增

- `bin/surehand`：一层薄壳，按自身真实位置定位 `scripts/cli.py`，可以安全地被软链到
  PATH 上任意位置。文档里的命令统一改成 `surehand ...`，不再依赖技能装在哪儿。

### 修复

- `SKILL.md` 两处写死的 `python3 ~/.workbuddy/skills/surehand/scripts/cli.py` 换成
  `surehand`，并附等价字面量写法。
- `references/recipes.md` 里的调用变量仍指向已废弃的 `computer-use` 路径（实测会直接报
  `No such file or directory`），30 处引用一并改为 `SH=surehand`。
- `install.sh`：目标目录改为可传参（`./install.sh ~/.dsh/skills/surehand`），默认用复制
  而不是符号链接——宿主自己的文件服务可能拒绝跨出允许根目录的软链；顺带把 `surehand`
  接进 `~/.local/bin`，并新增 `--link` / `--copy` / `--force`。
- **浏览器层原本不是自包含的**：`vendor/browser/fastlane.py` 写死了
  `~/.workbuddy/skills/browser-automation-cdp/scripts/cdp.py`。一旦换了宿主或那门技能被移动，
  网页通道直接报缺文件，而且报错里让人跑本仓库根本没有的 `scripts/start_chrome.py`。
  现在把 `cdp.py` 收进 `vendor/browser/`，改成「自带优先、外部兜底」；三处提示文案改成
  `surehand launch`。

## [1.0.0] — 2026-11-15

首个公开版本。此前它以 `computer-use` 的名字在内部用了一周，跑过三个验收任务：
TextEdit 造文件（逐字节比对一致）、网页多字段表单（DOM 回显一致）、访达大树钻取（8.3 倍加速）。

### 新增

- **统一判断层**：三态证据（known/absent/unknown 永不合并）、三档令牌（完整/受限/导航句柄）、
  投递语义（delivered/not_delivered/uncertain × safe/unsafe）。
- **macOS 引擎** `engine/macos/mccd.swift`：AX + CGEvent，常驻进程，AF_UNIX 端点。
  - `flock` 独占单实例（实测 8 并发 → 1 存活 7 退让）。
  - 每连接一线程，长连接不会堵死其他客户端。
- **Windows 引擎** `engine/windows/wccd.ps1`：UIA + SendInput，零安装依赖。
  - 回环 TCP + 32 字节随机令牌 + 端点文件 ACL。
  - `SetProcessDpiAwareness(2)` 先于任何 UIA 调用，避免缩放屏系统性点偏。
  - 命名互斥体单实例；非阻塞轮询轮转处理多连接。
  - ⚠️ **未经实机验证**，随仓库提供 `verify.ps1` 供使用者验收。
- **网页通道**：CDP，DOM 级定位。`launch` 子命令可起带调试端口的浏览器
  （独立 profile，因为 Chrome 136+ 对默认 profile 禁了 `--remote-debugging-port`）。
- **跨平台角色名翻译**：`--role button` 与 `--role AXButton` 等价，客户端翻成平台真名。
- **受限令牌**：身份字段读不全但机器标识唯一时，放行填值、继续禁点。
  判据是「动作会不会落到坐标上」，不是「读得全不全」。
- **子树证明范围**：`--from` 钻取出的令牌带 `proven_in: subtree:eN`，不假装证明了整窗。
- 自测 17 项（`scripts/selftest.py`），Windows 验收 12 步（`engine/windows/verify.ps1`）。

### 修复

- macOS 客户端 `alive()` 只 connect 不 ping，导致并发冷启动会留下 13 个孤儿 daemon。
  改为真问一句 ping + 引擎侧 flock 独占锁。
- 引擎单线程串行 accept，一条长连接堵死所有客户端。改为每连接一线程。
- `stop` 杀不掉进程（`shutdown` 命令未实现）。补上，响应后退出。
- 计算器按钮的 `AXTitle`/`AXDescription` 全空，真正标识在 `AXIdentifier`，且随状态变
  （空输入 `AllClear` / 有输入 `Clear`）。身份键优先级改为先取机器标识。
- 点击通道顺序反了：原本 `auto` 优先坐标点击（快但不确认），改为优先应用层动作
  （慢约 100 ms 但给确定回执）。复核 `uncertain` 本身就要几十毫秒，还得赌落点没被遮挡。
- 导航句柄与令牌同形，容易看错。统一加 `·` 前缀——这是防误点，不是排版。

### 已知问题

- `AXObserver` 未接，`waitchange` 仍是 10 ms 轮询。
- macOS 多显示器未做逐屏坐标换算。
- Windows 引擎单线程串行，慢快照会挡住同时进来的请求。
- Windows 三态精度低于 macOS：UIA 没有「明确说没这个属性」的等价回答。
