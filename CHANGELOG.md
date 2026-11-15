# 变更记录

格式照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号照语义化版本。

## [1.1.2] — 2026-11-15

上一版发完之后，在给自己装第二个副本时踩到一件事：**升级技能，引擎没换。**

引擎是常驻进程，握手又不校验版本。把技能更新到新版之后，旧引擎还在跑，
新 CLI 会静默地连上去——新错误码它不认识，刚修好的语义它照旧。
用户什么都没做错，只是「更新了一下」。

这是这个项目最想消灭的那类错：不是崩，是悄悄地不对。

### 修复

- **引擎跟着技能版本走**（`transport.start()`）。启动前对一次版本：
  引擎比技能旧，就用 `shutdown` 让它体面退场再拉起新的；引擎比技能新，
  只提示不换（说明机器上还有另一份更新的安装，换掉是倒退）。
- **只换一次**。版本对不上时反复重启比问题本身更糟，所以换过就记一笔
  （`.engine.swap`）；还是对不上就明确说「源码与 SKILL.md 版本不一致」，
  不再动引擎。
- 版本号只认 `SKILL.md`：`transport.skill_version()` 是唯一实现，
  `cli --version`、`doctor`、MCP 握手都复用它。

### 新增

- **自测 27 → 29 项**：A8「引擎新旧判断」（按数字比，别按字符串——
  `"1.10.0" < "1.9.0"` 会得出 True）、B15「引擎跟着技能版本走」（停掉再起，
  自报版本必须与技能一致）。当前 29/29，0 跳过。

## [1.1.1] — 2026-11-15

1.1.0 发出去之后又测了一轮，专打「调用方按契约解析输出」这条线。四条都是同一个毛病：
**出错时给的东西没法用**。

### 修复

- **`--json` 下失败一定还是 JSON**。此前 11 处参数校验走 `raise SystemExit("中文提示")`，
  带 `--json` 时输出是一行散文、没有错误码，机器调用方解析失败后只能猜。
  现在统一成带码结构化输出（`ARG_MISSING` / `REF_MALFORMED` / `STEP_BAD` / `VERB_UNSUPPORTED`）。
  argparse 自己的报错也一并接管——写错动词不会再吐一屏 usage。
- **`FAIL ValueError: invalid literal for int()`**。`--web` 配 `d:e12` 会把桌面 ref 送进
  `int()` 当场抛异常。现在提前拦住，报 `REF_MALFORMED` 并说清「要么去掉 `--web`，
  要么 `look --web` 拿 `w:N`」。
- **意外异常不再裸奔**。兜底从 `FAIL <异常类名>` 改成 `INTERNAL（bug）`，
  带 hint 明确「这是工具缺陷，不要重放」。异常类名留在 `detail` 里，不丢信息。
- **`via` 归因说准了**（两个引擎）。按 `AXIdentifier` / `AutomationId` 命中时，
  回执原先一律写 `via: "name"`，让排查「为什么点错了」的人一直盯着名字看，
  而真正生效的是标识符。现在 `ref` / `id` / `name` / `role` 各归各位。

### 变更

- **`find` 认 `--name`**。`do` 用 `--name`、`find` 用 `--text`，同一个概念两个名字，
  学到前者的人写后者只会拿到一屏 usage。现在两个都认。
- **批量两种外层格式都收**：顶层数组，或 `{"steps": [...]}`；步骤里的 `"do"` 也可写成 `"action"`。
  改文档说明回执形状（`results` / `count` / `unverified`）。
- **两个平台引擎版本号对齐**。Windows 引擎此前停在 1.0.0，`wccd --version` 与技能版本对不上。

### 新增

- **自测 25 → 27 项**。新增 B13「`--json` 失败也是合法 JSON」（5 种错误路径逐一解析）、
  B14「批量两种格式与 `via` 归因」。当前 27/27，0 跳过。

## [1.1.0] — 2026-11-15

这一版来自一轮对抗性测试：故意做错事、故意读不该读的东西、故意把令牌放到过期之后。
下面每条都是先看到现象、再定位、再修，没有一条是「顺手改进」。

### 安全

- **令牌编号不再复用**（`mccd.swift` / `wccd.ps1`）。此前每次快照把计数器清零，
  上一次的 `e2` 会被下一次的 `e2` 顶掉。用户手里的旧令牌不是「失效」，而是**静默指向
  另一个元素**——失效会报错，指错不会。现在编号在本进程内单调递增，旧令牌一律
  `REF_STALE`。实测：两次快照编号区间不重叠，旧 `d:e1` 立即被拒。

### 修复

- **`read` 不返回值**。桌面 `read` 走 `state` 后只打印「完成」，网页 `read` 把结果留在
  `attempts[].detail.result` 里没提上来。读到却不告诉调用方，等于没读。现在两条通道
  都直接给 `value`。
- **网页快照看不见结果区**。选择器只有可交互元素，`<pre>`、`[aria-label]`、`[aria-live]`
  这类承载结果的节点完全不在快照里，agent 点完按钮只能靠截图猜。现在纳入并标
  `actionable: false`（显示为 `[只读]`）。
- **复选框状态读不出**。`value` 取的是 `el.value`，复选框恒为 `on`，「勾没勾上」永远
  无法判断。现在返回 `checked` / `unchecked`。
- **`setvalue("")` 被当成「没给文本」**。清空输入框是填表前的高频动作，此前只能逐字删除。
  根因在 `transport.act` 用 `if v not in (None, "")` 过滤参数。
- **`launch` 起不动浏览器**。`open -na ... --args` 在本机返回 0 却不起进程，轮询 25 秒后
  报「端口被安全软件拦了」，误导排查方向。改成 `Popen` 直接启动（`start_new_session`），
  并把浏览器 stderr 收进日志，失败时按 `sandbox initialization failed` / 端口占用 /
  profile 锁残留分别给结论。
- **`doctor` 不检查仓库完整性**。`vendor/browser/cdp.py` 缺失时网页通道要到真正调用才炸，
  报错还指向别的技能。现在体检直接报。
- **iframe 完全不可见**。页面有 iframe 时快照只覆盖主文档，看起来像「页面是空的」。
  现在如实返回 `frame_count` 并在 `look` 里提示。

### 变更

- **错误码精度**：`ref` 写法错报 `REF_MALFORMED`（`bad_input`），不再复用 `REF_STALE`。
  后者提示「目标已不在，重新 look」，照做一万次也发现不了是自己少写了个 `e`。
- **新增错误码**：`ARG_MISSING`、`WEB_STEP_FAILED`、`WEB_NO_TARGET`、`WEB_LAYER_DOWN`。
  此前网页步骤失败落到 `unknown`，提示是「未登记的错误」。
- **`delivered` 时 `retry` 改为 `n/a`**。已经送达，重试与否是个不适用的问题；
  沿用 `unsafe` 会让读结果的人被一个无意义的字段牵着走。

### 新增

- **MCP server**（`scripts/mcp_server.py`）：零依赖 stdio JSON-RPC，12 个工具。
  Claude Code / Cursor / Codex / WorkBuddy 以及任何支持 stdio MCP 的客户端都能接，
  不再只限认识 `SKILL.md` 的宿主。
- **`AGENTS.md`**：给非技能型 agent 的接入说明、平台差异、以及「不要做的事」。
- **自测 17 → 25 项**：新增错误码登记、`read` 返回值、令牌不复用、参数错与目标失效分离、
  网页文本保真、只读节点与勾选状态、iframe 报告、MCP 握手与调用。当前 25/25，0 跳过。

## [1.0.2] — 2026-11-15

一个只在 macOS 上出现的 shell 边界问题。引擎与判断层都没动。

### 修复

- `install.sh` 里三处 `$VAR` 后面紧跟全角标点。macOS 的 `/bin/sh` 是 bash 3.2，不做 UTF-8
  感知的标识符解析，会把全角字符的首字节吃进变量名：`echo "目标：$TARGET（$MODE_LABEL）"`
  实际输出成 `目标：  \xbc\x88\xbc\x89` —— 变量展开为空，标点被削掉半个字节，输出流因此不是
  合法 UTF-8。全部改成 `${VAR}` 定界，并在代码里写明原因。
- 这类问题 grep 文本看不出来（源码字节完全正确），只有实际运行并校验输出编码才会暴露。
  所以这次的验收方式是把脚本输出重定向到文件、再按 UTF-8 解码。

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
