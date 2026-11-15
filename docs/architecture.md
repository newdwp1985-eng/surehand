# 架构

## 分层

```
cli.py           命令行入口：解析参数、组装请求、按契约渲染结果
   │
   ├── evidence.py     纯函数：三态合并、令牌可动性、投递分级、错误分类、定位选择
   │                   —— 没有 IPC、没有子进程，因此可被单测完全钉住
   ├── transport.py    桌面通道客户端：按平台选端点，JSON-lines 收发
   └── web.py          网页通道适配：调 vendor/browser/fastlane.py，把结果归一成同一形状
          │
          ├── engine/macos/mccd.swift    常驻，AF_UNIX，AX + CGEvent
          ├── engine/windows/wccd.ps1    常驻，回环 TCP，UIA + SendInput
          └── vendor/browser/fastlane.py 每次调用一个进程，CDP 四层降级
```

判断全在 `evidence.py`，通道只负责「把事做到」和「如实报告做到了什么」。
这条边界是刻意的：**换平台只换通道，判断逻辑一行不改**。

## 一次快照的数据流

```
cli look --app 计算器
  → transport.snapshot(app=...)
    → 引擎：从窗口根元素开始，逐层遍历
        · 每个元素读 role / name / id / value / bbox / actions / enabled
        · 三态：读到了→known，明确没有→absent，这次没读出来→unknown
        · 统计整窗每个身份键出现几次（witness）
      ← 返回 {nodes:[...], complete, refs_issued, ...}
  → evidence.summarize()
    → 去掉窗口框与红绿灯，数「有意义的目标」→ 判 surface
  → 打印：surface + 节点表 + 令牌标记
```

发证（决定给不给 `ref`）在**引擎里**做，因为唯一性计数需要整窗视野；
判断「这个 surface 该走哪条路」在**Python 里**做，因为那是策略不是事实。

## 一次动作的数据流

```
cli do click --ref d:e12
  → transport.act(...)
    → 引擎：从注册表取元素 → 复核（进程/角色/名字是否还一致）
        · 应用层动作可用 → Invoke/AXPress → delivered / ax_action_result
        · 不可用但有坐标 → 坐标点击 → uncertain / event_posted
        · 都不行 → NO_ACTION_PATH / not_delivered
      ← 返回 {ok, method, before, after, delivery}
  → evidence.verdict() → ok / unverified / fail → 退出码 0 / 2 / 1
```

`before`/`after` 是刻意读两次的：值变了是最硬的送达证据，可以把 `uncertain` 升级成 `delivered`。

## 为什么两端能共用一份判断层

三个原因：

1. **协议同构**。两个引擎吐同样字段、同样错误码、同样投递语义。差异只在 `role` 的取值
   与三态精度，两者都在 `transport.py` 的 `norm_role` / 文档第 8 节里显式处理。
2. **发证规则同构**。三档令牌的判据是纯逻辑（完整性 × 唯一性 × 字段是否读全），
   与 API 无关。Swift 和 PowerShell 各写一遍，规则来自同一段注释。
3. **纯粹的判断被抽干了**。「这个界面算不算有结构」「这个错误该不该重试」这类问题
   不需要接触系统，所以能写成不依赖平台的函数。

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 给 Agent 读的操作手册：判断规则、命令表、铁律、边界 |
| `README.md` | 给人读的门面：差异点、安装、能力矩阵、实测 |
| `scripts/mcp_server.py` | MCP 入口（stdio JSON-RPC，12 个工具；只做管道，判断仍在 evidence） |
| `bin/surehand` | 可执行薄壳，按自身真实位置定位 cli.py，可软链进 PATH |
| `scripts/cli.py` | 命令行入口 |
| `scripts/evidence.py` | 判断层（纯函数） |
| `scripts/transport.py` | 桌面通道客户端（跨平台） |
| `scripts/web.py` | 网页通道适配 + 浏览器启动 |
| `scripts/selftest.py` | 17 项自测 |
| `engine/macos/mccd.swift` | macOS 引擎 |
| `engine/macos/build.sh` | 用系统 Swift 工具链编译 |
| `engine/windows/wccd.ps1` | Windows 引擎 |
| `engine/windows/verify.ps1` | Windows 验收脚本（12 步） |
| `vendor/browser/fastlane.py` | CDP 层（零第三方依赖） |
| `vendor/browser/cdp.py` | 手写 WebSocket + CDP 传输（自带优先，不依赖外部技能） |
| `AGENTS.md` | 非技能型 agent 的接入说明（MCP / CLI / 规则） |
| `references/contract.md` | 输出契约：字段语义、错误码、退出码 |
| `references/method.md` | 设计取舍：借鉴了什么、拒绝了什么、代价在哪 |
| `references/recipes.md` | 实战配方与踩过的坑 |
