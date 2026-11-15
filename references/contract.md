# 输出契约

这份文件是给「读结果的人」看的。任何实现细节变了，这里的字段语义不能变。

两个平台的引擎（macOS 的 mccd、Windows 的 wccd）产出同一套形状。**唯一有意保留的差异**
是 `role` 的取值与三态的精度，见第 8 节。凡是要做跨平台判断的地方，先按第 8 节归一化。

## 1. 观察（`look` / snapshot）

```json
{
  "ok": true,
  "snapshot_id": "s1794709293662",
  "app": "计算器", "pid": 88642, "window": "计算器", "window_bbox": [510,496,230,408],
  "scope": "window",
  "complete": true,
  "visited": 37,
  "count": 29,
  "refs_issued": 28,
  "refs_restricted": 1,
  "refs_withheld": 1,
  "truncated": false,
  "refs_usable": true,
  "elapsed_ms": 84.38,
  "nodes": [ ... ]
}
```

| 字段 | 语义 |
|---|---|
| `complete` | 整窗遍历是否走完：没有深度截断，也没有读不出来的子树。**只有它为真才发 ref** |
| `scope` | `window` 或 `subtree:<ref>`。用 `--from` 钻取时证明范围会收窄，字段如实写 |
| `visited` | 实际访问的节点数（不管保不保留） |
| `count` | 返回的节点数（受 `max_nodes` 限制） |
| `truncated` | 输出被 `max_nodes` 截断。**不影响发证**，因为遍历是完整的 |
| `refs_issued` / `refs_withheld` | 发证数 / 扣证数。`refs_issued` 含受限令牌 |
| `refs_restricted` | 其中受限令牌的数量（身份没读全但有机器标识，只许填值） |
| `incomplete_because` | `depth_cap:N`、`unknown_subtree:N` |

节点：

```json
{
  "ref": "e4",            // 发过证的令牌；没有这个字段说明没发证
  "handle": "e4",          // 未发证时的导航句柄（与 ref 互斥，不会同时出现）
  "role": "AXButton",      // Windows 上是 "button"；见第 8 节
  "name": "提交",
  "id": "Delete",          // 机器标识：AXIdentifier / AutomationId
  "value": "…",
  "bbox": [520,629,48,48],
  "actions": ["AXPress"],  // Windows 上是 press / setvalue / select / toggle / expand / scroll
  "enabled": false,
  "evidence": {"enabled": "unknown", "identity": "unknown"},
  "witness": 1,            // 整窗里同身份元素个数
  "ambiguous": 3,          // 仅当 witness > 1
  "unattested": true,      // 有身份字段读到 unknown
  "restricted": true,      // 受限令牌：只许 fill / read
  "allowed": ["fill", "read"],  // 仅当 restricted
  "proven_in": "subtree:e91",   // 仅当 scope 不是 window：唯一性只在子树内证过
  "addressed_by": "geometry",  // 没名字/没标识，靠位置成立
  "name_from": "content",  // 名字是从子节点算出来的
  "actionable": false,     // 仅网页：能读不能点（结果区、标题）
  "text": "…"              // 仅网页：节点文本，长文本截断到 300 字
}
```

网页快照在顶层另带两项，用来解释「你没看到的不是没有」：

```json
{"count": 7, "nodes": [], "ref_valid_at": "https://…", 
 "frames": ["fr", ""], "frame_count": 2}
```

`frame_count > 0` 表示页面有内嵌框架，其内部元素不在本次快照里。

## 2. 三态

| 值 | 含义 | 反例 |
|---|---|---|
| `known` | 读到了 | — |
| `absent` | 这个元素确实没有这个属性 | 窗口没有 `AXEnabled` |
| `unknown` | 这次没读出来，**不是答案** | `cannotComplete`、`invalidUIElement` |

映射：`success → known`；`attributeUnsupported`、`noValue → absent`；其余错误 `→ unknown`。

`unknown` 一旦进入谓词，结果就是 `unknown`，**永不当成 false**。
节点没有 `enabled` 字段且 `evidence.enabled == "unknown"` 时，不能推断它 disabled。

## 3. 令牌分三档

按「能对它做什么」划分，而不是按「读得全不全」。三条同时满足才是完整令牌：

1. `complete == true`（整窗遍历走完，身份计数才可信）
2. 身份键在整窗唯一（`witness == 1`）
3. 身份字段没有 `unknown`（`attested == true`；`absent` 不影响）

| 档 | 条件 | 能做什么 | 标记 |
|---|---|---|---|
| **完整令牌** | 上面三条全满足 | 点击、填值、读值、滚动 | 无标记 |
| **受限令牌** | 前两条满足，第 3 条不满足，但 `AXIdentifier` 非空且整窗唯一 | 只许 `fill` / `read` | `restricted: true` + `allowed` |
| **导航句柄** | 其余情况 | 只能 `--from` 继续观察 | 只有 `handle`，显示为 `·eN` |

受限令牌的由来：`AXValue` 在空输入框上常返回 `unknown`（TextEdit 的文档区就是典型），按老口径这种元素一个令牌都拿不到，逼得人退回按坐标盲输入 —— 那才是真正的风险。而写文字走 `AXSetValue`，直接落在指定元素上，不经坐标、不看可见性、不受遮挡影响，风险模型与点击不是一回事。所以放开填值、继续禁止点击。

点击被拒时返回 `TOKEN_RESTRICTED`，并附 `allowed` 与可执行的替代方案（改用 `--app/--role/--id` 按身份定位，或等界面状态稳定后重新快照）。

身份键按可靠性依次取：

| 条件 | 键 | `addressed_by` |
|---|---|---|
| 有 `AXIdentifier` | `role|#identifier` | `identity` |
| 有名字或描述 | `role|title|desc` | `identity` |
| 都没有 | `role|value|几何` | `geometry` |

`geometry` 的令牌只靠位置成立，界面一滚动就可能失效 —— 用 `--strict` 之前务必重看。

## 4. 动作

```json
{
  "ok": true,
  "action": "click", "via": "ref", "method": "axpress",
  "role": "AXButton", "name": "提交",
  "before": "", "after": "",
  "elapsed_ms": 103.2,
  "delivery": {"state": "delivered", "retry": "n/a", "witness": "ax_action_result"}
}
```

`ok` 与 `delivery.state` 不等价：`uncertain` 的动作 `ok` 为假，但它不是「没送到」。
判断以 `delivery.state` 为准。

`retry` 只在「还没送到」时有意义：

| state | retry | 含义 |
|---|---|---|
| `delivered` | `n/a` | 已送达，谈不上重试 |
| `not_delivered` | `safe` | 明确没送到，可以重放 |
| `not_delivered` | `unsafe` | 没送到，但重放有副作用（如落点被遮挡） |
| `uncertain` | `unsafe` | 事件已投出，重放会变成两次投递 |

| 动作 | macOS method | Windows method | state | witness |
|---|---|---|---|---|
| click（应用层可用） | axpress | invoke / select | delivered | ax_action_result |
| click（不可达坐标） | axpress | invoke / select | delivered | ax_action_result |
| click（降级到坐标） | cgevent_after_axpress_fail | cgevent_after_axpress_fail | uncertain | event_posted |
| click（`--prefer cg`） | cgevent_forced | cgevent_forced | uncertain | event_posted |
| fill / setvalue | axsetvalue | setvalue | delivered | ax_action_result |
| fill（无 ValuePattern） | — | focus_and_type | uncertain | event_posted |
| paste / type / key | cgevent | sendinput | uncertain | event_posted |
| scroll | cgevent | sendinput_wheel | uncertain | event_posted |

Windows 的 `fill` 在没有 ValuePattern 的控件上会退到「聚焦 + 全选 + 输入」，
此时只能给 `uncertain`——键盘注入无法确认控件是否真的收下了。

任何动作只要观测到 `before != after`，`uncertain` 会被升级为 `delivered`，`witness` 变 `value_delta`。

## 5. 错误码

| code | kind | 重试 | 含义 |
|---|---|---|---|
| `REF_STALE` | stale | 可以（重看后） | 令牌已不在最近快照里 |
| `HANDLE_NOT_TOKEN` | stale | 可以 | 这是导航句柄，没发证 |
| `TOKEN_RESTRICTED` | restricted | 可以 | 受限令牌只许填值；点击请按身份定位 |
| `REF_REBOUND` | stale | 可以 | 同位置换成了别的元素 |
| `REF_DETACHED` | stale | 可以 | 元素已从窗口脱离 |
| `AMBIGUOUS` | ambiguous | 可以（收窄后） | 命中多个 |
| `NOT_FOUND` | missing | 可以 | 整窗没有这个身份 |
| `NO_ACTION_PATH` | unsupported | 不行 | 没有可压的动作，坐标也不可达 |
| `OCCLUDED` | occluded | **不行** | 落点被别的窗口盖住 |
| `NO_BBOX` | unsupported | 不行 | 元素没有几何 |
| `APP_NOT_FOUND` / `NO_WINDOW` | env | 可以 | 应用没跑 / 没有可访问窗口 |
| `NEED_SHOT_FIRST` | env | 可以 | 图片坐标缺少换算依据 |
| `FOREGROUND_REFUSED` | env | 可以 | Windows 前台锁拒绝了切换 |
| `CAPTURE_FAILED` | env | 可以 | 截图失败：窗口被遮挡或最小化 |
| `CLIPBOARD_FAILED` | env | 可以 | 剪贴板被别的程序占着 |
| `BAD_TOKEN` | env | 可以 | 握手令牌不对，端点文件过期 |
| `UNSUPPORTED_PLATFORM` | env | **不行** | 不是 macOS 也不是 Windows |
| `BAD_JSON` / `INTERNAL` | bug | 不行 | 客户端发了非法 JSON / 引擎内部异常 |
| `REF_MALFORMED` | bad_input | 可以 | ref 写法错（漏了 `e`、用了不认识的前缀）；修正参数再试 |
| `ARG_MISSING` | bad_input | 可以 | 缺必填参数 |
| `WEB_STEP_FAILED` | web | 可以 | 网页步骤失败；先 `look --web` 看页面现状 |
| `WEB_NO_TARGET` | web | 可以 | 网页上没这个元素；先看它到底叫什么 |
| `WEB_LAYER_DOWN` | web | 可以 | 四层定位全失败；改走截图 + 坐标 |

状态未知类错误（`occluded`）一律不授权重放。

## 6. 退出码

| 码 | 含义 |
|---|---|
| 0 | 已送达 / 观察完成 |
| 1 | 未送达 / 观察失败 |
| 2 | 动作已发出但未确认（`uncertain`） |

批量报告中每步 `verdict`：`ok` / `unverified` / `fail`。
`unverified` 记在总数里但不打断流程，`fail` 默认中止（`continue: true` 可继续）。

## 7. 网页通道

节点形状归一成同一套字段（`ref` 带 `w:` 前缀），差别只在：

- `witness` 恒为 1（CDP 侧要求选择器唯一命中，不等于是不操作）
- 没有 `handle`：网页 ref 存在页面 DOM 的 `data-fastlane-ref` 上，跨进程天然可见
- 用 `--ref` 动手前会按 `.state.json` 里记的身份复核一次；编号被复用就自动改按可访问名定位

## 8. 平台差异（唯一有意保留的）

### 角色名

macOS 用 AX 名（`AXButton`），Windows 用 UIA 官方名小写（`button`）。**这两套名字不是
同一套词汇，也不该假装是**——UIA 的 `Edit` 对应 AX 的 `AXTextField`，强行统一会误导。

客户端负责翻译：`--role` 收到任何写法都先收敛到规范键（小写去 `ax` 前缀）再翻成当前平台的名字。
所以写 `--role button`、`--role AXButton`、`--role Button` 效果相同。

常用对照：

| 规范键 | macOS | Windows |
|---|---|---|
| button | AXButton | button |
| textfield | AXTextField | edit |
| statictext | AXStaticText | text |
| link | AXLink | hyperlink |
| outline | AXOutline | tree |
| cell | AXCell | dataitem |
| tabgroup | AXTabGroup | tab |

快照里的 `role` 字段按各平台原样给出，不做归一——它是给人看的，保留原始叫法更有诊断价值。

### 三态精度

| | macOS AX | Windows UIA |
|---|---|---|
| 明确「没这个属性」 | `attributeUnsupported` → `absent` | 无等价回答 |
| 元素读不到 | `invalidUIElement` → `unknown` | COM 异常 → `unknown` |
| 空值 | `noValue` → `absent` | 空字符串 → `absent` |

结论：**Windows 的 `unknown` 含义更窄**，基本只代表「元素消失了」。因此 Windows 上
`absent` 与 `unknown` 混用的概率更高。涉及「某字段是不是空」的判断，Windows 侧应多读一次
`state` 复核，而不是只看快照里有没有那个字段。
