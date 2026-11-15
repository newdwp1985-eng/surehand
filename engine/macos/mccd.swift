// mccd — macOS computer control daemon (zero third-party dependency)
// 常驻进程 + AF_UNIX socket + JSON-lines 协议
// 通道：AX 读结构 / AX 动作 / CGEvent 原生输入

import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ImageIO
import CoreText

let VERSION = "1.1.0"
let SOCK_PATH = "/tmp/mccd-\(getuid()).sock"
let LOCK_PATH = "/tmp/mccd-\(getuid()).lock"

// MARK: - 证据三态
//
// 传统读法 `err == success ? 值 : nil` 把两种完全不同的失败折叠成同一个 nil：
//   attributeUnsupported —— 这个元素确实没有这个属性，是**答案**（确定没有）
//   cannotComplete       —— 这次没读出来，不是答案（说不准）
// 折叠之后，任何形如「没有 X 就做 Y」的判断都会把「说不准」当成「确定没有」，
// 在模糊的界面上做出确定性的错事。所以读取必须返回三态，且在谓词里 Unknown 永不取反。

enum Ev: String {
    case known = "known"
    case absent = "absent"
    case unknown = "unknown"
}

struct Val {
    let ev: Ev
    let v: CFTypeRef?
}

func axRead(_ el: AXUIElement, _ key: String) -> Val {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, key as CFString, &v)
    switch e {
    case .success:
        return Val(ev: .known, v: v)
    case .attributeUnsupported, .noValue:
        // 属性不存在 / 当前无值：这是一个关于该元素的确定结论
        return Val(ev: .absent, v: nil)
    case .invalidUIElement:
        // 元素已失效：等同于「这个句柄不再指向任何东西」，不是「说没有」
        return Val(ev: .unknown, v: nil)
    default:
        // cannotComplete / apiDisabled / 超时：不是答案
        return Val(ev: .unknown, v: nil)
    }
}

func axAttr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
}

func valStr(_ val: Val) -> String {
    guard let v = val.v else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

// 三态读字符串：返回 (是否确定读到值, 值)
func evStr(_ el: AXUIElement, _ key: String) -> (Ev, String) {
    let r = axRead(el, key)
    return (r.ev, valStr(r))
}

func axStr(_ el: AXUIElement, _ key: String) -> String {
    guard let v = axAttr(el, key) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func axBool(_ el: AXUIElement, _ key: String) -> Bool {
    guard let v = axAttr(el, key) else { return false }
    if let n = v as? NSNumber { return n.boolValue }
    return false
}

func axPoint(_ el: AXUIElement, _ key: String) -> CGPoint? {
    guard let v = axAttr(el, key), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue((v as! AXValue), .cgPoint, &p) ? p : nil
}

func axSize(_ el: AXUIElement, _ key: String) -> CGSize? {
    guard let v = axAttr(el, key), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue((v as! AXValue), .cgSize, &s) ? s : nil
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
    return arr
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func elementCenter(_ el: AXUIElement) -> CGPoint? {
    guard let p = axPoint(el, kAXPositionAttribute as String),
          let s = axSize(el, kAXSizeAttribute as String) else { return nil }
    return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
}

func elementBox(_ el: AXUIElement) -> [Double] {
    guard let p = axPoint(el, kAXPositionAttribute as String),
          let s = axSize(el, kAXSizeAttribute as String) else { return [] }
    return [Double(p.x), Double(p.y), Double(s.width), Double(s.height)]
}

func hitTest(_ p: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var out: AXUIElement?
    let e = AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &out)
    return e == .success ? out : nil
}

func isDescendantOrSelf(_ el: AXUIElement, of ancestor: AXUIElement) -> Bool {
    if CFEqual(el, ancestor) { return true }
    var cur: AXUIElement? = el
    var depth = 0
    while let c = cur, depth < 24 {
        guard let parentRef = axAttr(c, kAXParentAttribute as String),
              CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return false }
        let parent = parentRef as! AXUIElement
        if CFEqual(parent, ancestor) { return true }
        cur = parent
        depth += 1
    }
    return false
}

// MARK: - ref 注册表（快照内有效，带捕获证明）
//
// 一个 ref 只有在同时满足下面三条时才发放：
//   1. 整窗完整遍历过（没有深度截断、没有读不出来的子树）
//   2. 它的身份键在整窗唯一（不是「我看不到第二个」，而是「数过了，就一个」）
//   3. 身份字段全部读到过（没有 Unknown）
// 任何一条不满足就不发 ref —— 宁可不给，也不给一个可能指错的编号。

struct RefEntry {
    let el: AXUIElement
    let role: String
    let name: String
    let desc: String
    let pid: pid_t
    let window: AXUIElement
    let witness: Int
    let proven: Bool          // true 才发过证，才允许动手
    let restricted: Bool      // 受限令牌：身份字段没读全，但机器标识唯一。只许填，不许点
    let scope: String         // 唯一性在哪个范围证明的："window" | "subtree:e12"
    let identifiedBy: String
    let addressedBy: String   // "identity" | "geometry"
}

final class Registry {
    private let lock = NSLock()
    private var map: [String: RefEntry] = [:]
    private var counter = 0
    private var sid = ""
    private var win: AXUIElement?
    private var pid: pid_t = 0

    func newSnapshot(_ window: AXUIElement, pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
        // counter 不清零：ref 编号在本进程生命周期内单调递增，永不复用。
        // 清零会让下一次快照的 e2 顶掉上一次的 e2——用户手里的旧 ref 不是「失效」，
        // 而是静默指到了另一个元素上。失效会报错，指错不会，这就是误点的最短路径。
        win = window
        self.pid = pid
        sid = "s\(Int(Date().timeIntervalSince1970 * 1000))"
        return sid
    }

    var snapshotId: String {
        lock.lock(); defer { lock.unlock() }
        return sid
    }

    var window: AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return win
    }

    func put(_ el: AXUIElement, role: String, name: String, desc: String,
             witness: Int, identifiedBy: String, addressedBy: String,
             proven: Bool = true, restricted: Bool = false,
             scope: String = "window") -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let r = "e\(counter)"
        map[r] = RefEntry(el: el, role: role, name: name, desc: desc,
                          pid: pid, window: win ?? el, witness: witness,
                          proven: proven, restricted: restricted, scope: scope,
                          identifiedBy: identifiedBy, addressedBy: addressedBy)
        return r
    }

    func get(_ r: String) -> RefEntry? {
        lock.lock(); defer { lock.unlock() }
        return map[r]
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
        counter = 0
        sid = ""
    }
}

let registry = Registry()

// 身份键：用于「整窗唯一性」计数。
// 有名字的按 role|title|desc 计（这与按名字定位的歧义面一致）；
// 没名字的按 role|value|几何 计，并标注 addressed_by=geometry —— 这种 ref 只靠位置成立，
// 界面一滚动就作废，用之前必须 strict 校验。
func identityKey(role: String, name: String, desc: String, value: String,
                 box: [Double], identifier: String) -> (String, String) {
    // AXIdentifier 是 App 自己给的稳定标识，比可见文字可靠：
    // 文案会随语言变、随改版变，identifier 不变。有就优先用它。
    if !identifier.isEmpty {
        return ("\(role)|#\(identifier)", "identity")
    }
    if !name.isEmpty || !desc.isEmpty {
        return ("\(role)|\(name)|\(desc)", "identity")
    }
    let geo = box.count == 4 ? "\(Int(box[0])):\(Int(box[1])):\(Int(box[2])):\(Int(box[3]))" : "-"
    return ("\(role)|\(value)|\(geo)", "geometry")
}

// MARK: - 应用枚举

struct AppInfo {
    let pid: pid_t
    let name: String
    let exe: String
    let bundle: String
    let frontmost: Bool
    let windows: Int
}

// 关键：daemon 不跑 runloop，NSWorkspace 的进程列表不会刷新。
// 因此以 WindowServer 的窗口列表为准（每次都是实时查询）。
func runningApps() -> [AppInfo] {
    let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    var map: [Int32: (String, Int)] = [:]
    for w in info {
        guard let raw = w[kCGWindowOwnerPID as String] as? Int else { continue }
        let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
        if layer != 0 { continue }
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
        let pid = Int32(raw)
        let cur = map[pid] ?? (owner, 0)
        map[pid] = (cur.0.isEmpty ? owner : cur.0, cur.1 + 1)
    }
    var out: [AppInfo] = []
    for (pid, v) in map {
        let ra = NSRunningApplication(processIdentifier: pid)
        let exe = ra?.executableURL?.lastPathComponent ?? ""
        out.append(AppInfo(pid: pid,
                           name: v.0.isEmpty ? (ra?.localizedName ?? exe) : v.0,
                           exe: exe,
                           bundle: ra?.bundleIdentifier ?? "",
                           frontmost: ra?.isActive ?? false,
                           windows: v.1))
    }
    return out.sorted { $0.windows > $1.windows }
}

func resolveApp(_ spec: String?) -> AppInfo? {
    let apps = runningApps()
    let withWin = apps.filter { $0.windows > 0 }
    guard let s = spec, !s.isEmpty, s != "front", s != "frontmost" else {
        if let f = withWin.first(where: { $0.frontmost }) { return f }
        if let f = apps.first(where: { $0.frontmost }) { return f }
        return withWin.first
    }
    if let pid = pid_t(s), let hit = apps.first(where: { $0.pid == pid }) {
        return hit
    }
    let exacts = apps.filter { $0.name == s || $0.bundle == s || $0.exe == s }
    if let w = exacts.first(where: { $0.windows > 0 }) { return w }
    if let e = exacts.first { return e }
    let low = s.lowercased()
    let partial = apps.filter {
        $0.name.lowercased().contains(low) || $0.exe.lowercased().contains(low) || $0.bundle.lowercased().contains(low)
    }
    if let w = partial.first(where: { $0.windows > 0 }) { return w }
    return partial.first
}

func appElement(_ app: AppInfo) -> AXUIElement {
    AXUIElementCreateApplication(app.pid)
}

func windowsOf(_ app: AppInfo) -> [AXUIElement] {
    (axAttr(appElement(app), kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
}

// MARK: - 快照

let INTERACTIVE: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXMenuItem", "AXMenuBarItem", "AXRow", "AXCell", "AXTabGroup",
    "AXComboBox", "AXSearchField", "AXSlider", "AXScrollBar", "AXDisclosureTriangle",
    "AXToggle", "AXMenuButton", "AXColorWell", "AXIncrementor", "AXSegmentedControl",
    "AXOutline", "AXList", "AXTable", "AXMenu", "AXToolbar"
]

let TEXTY: Set<String> = ["AXStaticText", "AXHeading", "AXCell"]

func axHasAttr(_ el: AXUIElement, _ key: String) -> Bool {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success
}

func shouldKeep(role: String, text: String, includeStatic: Bool) -> Bool {
    if INTERACTIVE.contains(role) { return true }
    if role == "AXWindow" { return true }
    if TEXTY.contains(role) {
        if !includeStatic { return false }
        return !text.isEmpty && text.count <= 120
    }
    return !text.isEmpty && text.count <= 120
}

// 一次遍历把要用的字段全部读掉，之后渲染不再回头读 AX。
// 这不只是省时间：每个字段的读取结论（known/absent/unknown）必须与这一次遍历绑定，
// 否则「快照时唯一」这个证明在渲染时就已经不成立了。
struct NodeRec {
    let el: AXUIElement
    let depth: Int
    let role: String
    let subrole: String
    let name: String
    let desc: String
    let identifier: String
    let value: String
    let box: [Double]
    let acts: [String]
    let enabledEv: Ev
    let enabled: Bool
    let focused: Bool
    let identity: String
    let addressedBy: String
    let attested: Bool
    let nameFrom: String
}

func doSnapshot(_ req: [String: Any]) -> [String: Any] {
    let t0 = Date()
    guard let app = resolveApp(req["app"] as? String) else {
        return ["ok": false, "error": "APP_NOT_FOUND"]
    }
    var wins = windowsOf(app)
    if let title = req["window"] as? String, !title.isEmpty {
        let filtered = wins.filter { axStr($0, kAXTitleAttribute as String).contains(title) }
        if !filtered.isEmpty { wins = filtered }
    }
    guard let win = wins.first else {
        return ["ok": false, "error": "NO_WINDOW", "app": app.name, "pid": Int(app.pid)]
    }

    let maxNodes = (req["max_nodes"] as? Int) ?? 1500
    let includeStatic = (req["include_static"] as? Bool) ?? true
    let maxDepth = (req["max_depth"] as? Int) ?? 40

    // 钻取：从上一份快照里的某个 ref 继续往下看。
    // 慢树上整窗遍历要好几秒，先用 depth 拿结构、再按区域 from 钻进去，
    // 证明的范围随之收窄到该子树（scope 字段写明），不假装自己证明了整窗。
    var rootEl = win
    var scope = "window"
    if let fromRef = req["from"] as? String, !fromRef.isEmpty {
        guard let e = registry.get(fromRef) else { return ["ok": false, "error": "REF_STALE"] }
        rootEl = e.el
        scope = "subtree:\(fromRef)"
    }

    var freq: [String: Int] = [:]
    var recs: [NodeRec] = []
    var visited = 0
    var unknownSubtrees = 0
    var unattestedNodes = 0
    var depthCapped = false
    var overflow = false

    func collect(_ el: AXUIElement, _ depth: Int) {
        visited += 1
        if depth > maxDepth { depthCapped = true; return }

        let (roleEv, role) = evStr(el, kAXRoleAttribute as String)
        let (nameEv, rawTitle) = evStr(el, kAXTitleAttribute as String)
        let (descEv, desc) = evStr(el, kAXDescriptionAttribute as String)
        let (valEv, value) = evStr(el, kAXValueAttribute as String)
        let (_, identifier) = evStr(el, "AXIdentifier")

        // 名字缺失时补一次计算名，且只对可交互角色做，避免给每个布局容器都多打两次 IPC
        var title = cleanText(rawTitle)
        var nameFrom = ""
        if title.isEmpty && desc.isEmpty && INTERACTIVE.contains(role) {
            let c = computedName(el)
            if !c.isEmpty { title = c; nameFrom = "content" }
        }

        let named = !title.isEmpty || !desc.isEmpty
        let text = title.isEmpty ? value : title
        let keep = shouldKeep(role: role, text: text, includeStatic: includeStatic)

        // 计数范围必须覆盖「按名字可能命中的全部元素」，而不只是被保留的那些，
        // 否则唯一性会算少，同名元素又会被当成唯一发出去。
        if named || keep {
            var box: [Double] = []
            if keep || !named { box = elementBox(el) }
            let (key, by) = identityKey(role: role, name: title, desc: desc,
                                        value: value, box: box, identifier: identifier)
            freq[key, default: 0] += 1
            if keep {
                if recs.count >= maxNodes {
                    overflow = true
                } else {
                    // absent 是确定的结论（这个元素确实没有这个字段），
                    // 只有 unknown 才意味着「没查到」，才取消发证资格。
                    let attested = (roleEv != .unknown && nameEv != .unknown
                                    && descEv != .unknown && valEv != .unknown)
                    if !attested { unattestedNodes += 1 }
                    let en = axRead(el, kAXEnabledAttribute as String)
                    recs.append(NodeRec(
                        el: el, depth: depth, role: role,
                        subrole: evStr(el, kAXSubroleAttribute as String).1,
                        name: title, desc: desc, identifier: identifier, value: value, box: box,
                        acts: axActions(el),
                        enabledEv: en.ev,
                        enabled: (en.v as? NSNumber)?.boolValue ?? false,
                        focused: axBool(el, kAXFocusedAttribute as String),
                        identity: key, addressedBy: by, attested: attested,
                        nameFrom: nameFrom
                    ))
                }
            }
        }

        // 子节点三态：读不出来 ≠ 没有子节点
        let kidsR = axRead(el, kAXChildrenAttribute as String)
        let kids: [AXUIElement]
        switch kidsR.ev {
        case .known:  kids = (kidsR.v as? [AXUIElement]) ?? []
        case .absent: kids = []
        case .unknown:
            unknownSubtrees += 1
            return
        }
        for c in kids { collect(c, depth + 1) }
    }
    collect(rootEl, 0)

    let complete = !depthCapped && unknownSubtrees == 0
    let sid = registry.newSnapshot(win, pid: app.pid)

    var nodes: [[String: Any]] = []
    var issued = 0
    var withheld = 0
    var restrictedCount = 0
    for r in recs {
        let witness = freq[r.identity] ?? 1
        var d: [String: Any] = ["role": r.role, "depth": r.depth, "witness": witness]
        if !r.subrole.isEmpty { d["subrole"] = r.subrole }
        if !r.name.isEmpty {
            d["name"] = r.name
            if !r.nameFrom.isEmpty { d["name_from"] = r.nameFrom }
        }
        if !r.desc.isEmpty { d["desc"] = r.desc }
        if !r.identifier.isEmpty { d["id"] = r.identifier }
        if !r.value.isEmpty { d["value"] = r.value.count > 300 ? String(r.value.prefix(300)) : r.value }
        if r.box.count == 4 { d["bbox"] = r.box }
        if !r.acts.isEmpty { d["actions"] = r.acts }
        if r.focused { d["focused"] = true }

        var ev: [String: String] = [:]
        switch r.enabledEv {
        case .known:   d["enabled"] = r.enabled
        case .absent:  ev["enabled"] = "absent"
        case .unknown: ev["enabled"] = "unknown"
        }
        // 整窗没证明完整时不发 ref，逐节点再标一遍「身份没读全」只会制造噪音
        if !r.attested && complete { ev["identity"] = "unknown" }
        if !ev.isEmpty { d["evidence"] = ev }

        // 发证分三档，按「能对它做什么」而不是按「读得全不全」划分：
        //
        //   完整令牌 —— 整窗完整 + 身份唯一 + 字段全读到：点什么都可以
        //   受限令牌 —— 身份有字段读不出来（典型是 AXValue 在空输入框上返回 unknown），
        //               但机器标识（AXIdentifier）存在且在整窗唯一：只许填值，不许点
        //   导航句柄 —— 其余情况：只能拿去 --from 继续看，动手一律拒绝
        //
        // 为什么给受限令牌：写文字走 AXSetValue，直接落在指定元素上，
        // 不经坐标、不看可见性、不受遮挡影响，风险模型跟点击根本不是一回事。
        // 拿点击的严格性去卡输入框，只会逼人退回按坐标盲输入，那才是真的危险。
        if complete && witness == 1 && r.attested {
            d["ref"] = registry.put(r.el, role: r.role, name: r.name, desc: r.desc,
                                    witness: witness, identifiedBy: r.identifier,
                                    addressedBy: r.addressedBy, scope: scope)
            if r.addressedBy == "geometry" { d["addressed_by"] = "geometry" }
            if scope != "window" { d["proven_in"] = scope }
            issued += 1
        } else if complete && witness == 1 && !r.identifier.isEmpty {
            d["ref"] = registry.put(r.el, role: r.role, name: r.name, desc: r.desc,
                                    witness: witness, identifiedBy: r.identifier,
                                    addressedBy: r.addressedBy, restricted: true,
                                    scope: scope)
            d["restricted"] = true
            d["allowed"] = ["fill", "read"]
            if scope != "window" { d["proven_in"] = scope }
            restrictedCount += 1
            issued += 1
        } else {
            withheld += 1
            // 没证明的元素仍然留一个导航句柄：它不能拿去点，但可以拿去 --from 继续钻。
            // 句柄与令牌分开，是为了让「看一眼结构」和「对此下手」是两件不同权限的事。
            d["handle"] = registry.put(r.el, role: r.role, name: r.name, desc: r.desc,
                                      witness: witness, identifiedBy: r.identifier,
                                      addressedBy: r.addressedBy, proven: false,
                                      scope: scope)
            if witness > 1 { d["ambiguous"] = witness }
            if !r.attested { d["unattested"] = true }
        }
        nodes.append(d)
    }

    let ms = Date().timeIntervalSince(t0) * 1000
    var out: [String: Any] = [
        "ok": true,
        "snapshot_id": sid,
        "app": app.name,
        "pid": Int(app.pid),
        "window": axStr(win, kAXTitleAttribute as String),
        "window_bbox": elementBox(win),
        "scope": scope,
        "complete": complete,
        "visited": visited,
        "count": nodes.count,
        "refs_issued": issued,
        "refs_restricted": restrictedCount,
        "refs_withheld": withheld,
        "truncated": overflow,
        "elapsed_ms": (ms * 1000).rounded() / 1000,
        "nodes": nodes,
    ]
    if !complete {
        var why: [String] = []
        if depthCapped { why.append("depth_cap:\(maxDepth)") }
        if unknownSubtrees > 0 { why.append("unknown_subtree:\(unknownSubtrees)") }
        out["incomplete_because"] = why
        out["refs_usable"] = false
    } else {
        out["refs_usable"] = issued > 0
    }
    return out
}

// MARK: - 动作

func postClick(_ p: CGPoint) -> Double {
    let t0 = Date()
    let src = CGEventSource(stateID: .hidSystemState)
    let saved = CGEvent(source: nil)?.location ?? p
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(1500)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(11000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(1500)
    if saved != p {
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: saved, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    return Date().timeIntervalSince(t0) * 1000
}

func postScroll(_ p: CGPoint, dy: Int32) {
    let src = CGEventSource(stateID: .hidSystemState)
    let saved = CGEvent(source: nil)?.location ?? p
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(800)
    (CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))?
        .post(tap: .cghidEventTap)
    usleep(800)
    if saved != p {
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: saved, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

func postUnicode(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let units = Array(s.utf16)
    var i = 0
    while i < units.count {
        let n = min(16, units.count - i)
        var buf = Array(units[i..<(i + n)])
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
            up.post(tap: .cghidEventTap)
        }
        i += n
        usleep(1500)
    }
}

let KEYMAP: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
]

func postKey(_ combo: String) -> Bool {
    let parts = combo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard let last = parts.last, let code = KEYMAP[last] else { return false }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        switch m {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: return false
        }
    }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(8000)
    up?.post(tap: .cghidEventTap)
    return true
}

// MARK: - 目标解析（带复核）

struct Target {
    let el: AXUIElement
    let role: String
    let name: String
    let desc: String
    let witness: Int
    let via: String      // "ref" | "name"
    let restricted: Bool // 受限令牌：只准填，不准点
    let scope: String    // 唯一性在哪个范围证明的
}

// 受限令牌放行这几类动作。判断依据是「会不会落到坐标上」：
// 填值走 AXSetValue，直接作用于元素；读只是取值。
// click/press 要算坐标、要被遮挡影响，scroll 会移动视图让后续坐标失真，都不放行。
let RESTRICTED_OK_ACTIONS: Set<String> = [
    "setvalue", "fill", "type_into", "read", "get", "state",
]

// 整窗重数身份，用于 strict 复核
func countWitness(role: String, name: String, desc: String,
                   identifier: String, in win: AXUIElement) -> Int {
    var n = 0
    func walk(_ el: AXUIElement, _ d: Int) {
        if d > 40 { return }
        let r = axStr(el, kAXRoleAttribute as String)
        if r != role { for c in axChildren(el) { walk(c, d + 1) }; return }
        if !identifier.isEmpty {
            if axStr(el, "AXIdentifier") == identifier { n += 1 }
            for c in axChildren(el) { walk(c, d + 1) }
            return
        }
        let t = cleanText(axStr(el, kAXTitleAttribute as String))
        let de = axStr(el, kAXDescriptionAttribute as String)
        if t == name && de == desc { n += 1 }
        for c in axChildren(el) { walk(c, d + 1) }
    }
    walk(win, 0)
    return n
}

// ref 复核三档：
//   none   —— 不查，最快，只适合紧接着自己的快照做只读
//   attach —— 校验 pid 未变、身份未变、仍挂在同一个窗口下（约 1 ms）
//   strict —— 整窗重数身份（与快照同口径，几十毫秒起）
// 写操作请用 strict：ref 指错一个元素的代价，远大于一次整窗遍历。
func verifyRef(_ r: String, mode: String) -> (Target?, String?) {
    guard let e = registry.get(r) else { return (nil, "REF_STALE") }
    // 句柄只能用来继续观察，不能拿来动手 —— 「看过」不等于「点得」
    if !e.proven { return (nil, "HANDLE_NOT_TOKEN") }
    if mode != "none" {
        var pid: pid_t = 0
        AXUIElementGetPid(e.el, &pid)
        if pid != e.pid { return (nil, "REF_REBOUND:pid_changed") }
        let role = axStr(e.el, kAXRoleAttribute as String)
        if role != e.role { return (nil, "REF_REBOUND:role_changed") }
        if !e.name.isEmpty && axStr(e.el, kAXTitleAttribute as String) != e.name {
            return (nil, "REF_REBOUND:name_changed")
        }
        if !isDescendantOrSelf(e.el, of: e.window) { return (nil, "REF_DETACHED") }
    }
    if mode == "strict" {
        let n = countWitness(role: e.role, name: e.name, desc: e.desc,
                             identifier: e.identifiedBy, in: e.window)
        if n == 0 { return (nil, "REF_STALE") }
        if n > 1 { return (nil, "AMBIGUOUS:\(n)") }
    }
    return (Target(el: e.el, role: e.role, name: e.name, desc: e.desc,
                   witness: e.witness, via: "ref",
                   restricted: e.restricted, scope: e.scope), nil)
}

func resolveTarget(_ req: [String: Any]) -> (Target?, String?) {
    if let r = req["ref"] as? String {
        return verifyRef(r, mode: (req["verify"] as? String) ?? "attach")
    }
    guard let app = resolveApp(req["app"] as? String) else { return (nil, "APP_NOT_FOUND") }
    let role = (req["role"] as? String) ?? ""
    let name = (req["name"] as? String) ?? ""
    let ident = (req["id"] as? String) ?? ""
    let contains = req["contains"] as? Bool ?? false
    guard !role.isEmpty || !name.isEmpty || !ident.isEmpty else { return (nil, "NO_TARGET") }
    var wins = windowsOf(app)
    if let title = req["window"] as? String, !title.isEmpty {
        let f = wins.filter { axStr($0, kAXTitleAttribute as String).contains(title) }
        if !f.isEmpty { wins = f }
    }
    guard let win = wins.first else { return (nil, "NO_WINDOW") }
    var hits: [AXUIElement] = []
    func walk(_ el: AXUIElement, _ d: Int) {
        if d > 40 || hits.count > 40 { return }
        let r = axStr(el, kAXRoleAttribute as String)
        let t = axStr(el, kAXTitleAttribute as String)
        let v = axStr(el, kAXValueAttribute as String)
        let de = axStr(el, kAXDescriptionAttribute as String)
        let roleOK = role.isEmpty ? true : (r == role)
        var nameOK = true
        if !ident.isEmpty {
            nameOK = (axStr(el, "AXIdentifier") == ident)
        } else if !name.isEmpty {
            let hay = [t, v, de]
            nameOK = contains ? hay.contains { $0.contains(name) } : hay.contains { $0 == name }
        }
        if roleOK && nameOK { hits.append(el) }
        for c in axChildren(el) { walk(c, d + 1) }
    }
    walk(win, 0)
    if hits.isEmpty { return (nil, "NOT_FOUND") }
    if hits.count > 1 && !contains { return (nil, "AMBIGUOUS:\(hits.count)") }
    let el = hits[0]
    return (Target(el: el,
                   role: axStr(el, kAXRoleAttribute as String),
                   name: axStr(el, kAXTitleAttribute as String),
                   desc: axStr(el, kAXDescriptionAttribute as String),
                   witness: hits.count, via: "name",
                   restricted: false, scope: "window"), nil)
}

func deliveryOf(_ state: String, _ retry: String, _ witness: String) -> [String: Any] {
    ["state": state, "retry": retry, "witness": witness]
}

func doAct(_ req: [String: Any]) -> [String: Any] {
    let t0 = Date()
    let action = (req["action"] as? String) ?? "click"
    let (maybeT, err) = resolveTarget(req)
    if let e = err { return ["ok": false, "error": e] }
    guard let t = maybeT else { return ["ok": false, "error": "NO_TARGET"] }
    let el = t.el
    let role = t.role
    let name = t.name
    let before = axStr(el, kAXValueAttribute as String)

    // 受限令牌的门禁：这里回的是「确定没做」，不是「不确定」。
    // 拒绝一个动作必须给出可执行的替代方案，否则调用方只会去试别的歪路。
    if t.restricted && !RESTRICTED_OK_ACTIONS.contains(action) {
        return ["ok": false, "error": "TOKEN_RESTRICTED",
                "action": action, "role": role, "name": name,
                "allowed": Array(RESTRICTED_OK_ACTIONS).sorted(),
                "hint": "该元素身份字段没读全，只发了受限令牌（只许填值）。"
                      + "要点击请用 --app/--role/--id 按身份定位，或先让界面状态稳定后重新快照。",
                "delivery": deliveryOf("not_delivered", "safe", "no_path")]
    }

    func finish(_ method: String, _ state: String, _ retry: String, _ witness: String,
                _ extra: [String: Any] = [:]) -> [String: Any] {
        let after = axStr(el, kAXValueAttribute as String)
        var out: [String: Any] = [
            "ok": state != "not_delivered",
            "action": action,
            "via": t.via,
            "role": role,
            "name": name,
            "before": before,
            "after": after,
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000,
            "method": method,
        ]
        // 唯一性是不是只在子树里证过，动手的人有权知道
        if t.scope != "window" { out["proven_in"] = t.scope }
        if t.restricted { out["restricted"] = true }
        // 观测到值变化是可以把「不确定」升级成「确定送达」的唯一证据
        var st = state, wt = witness
        if st == "uncertain" && before != after {
            st = "delivered"
            wt = "value_delta"
        }
        out["delivery"] = deliveryOf(st, retry, wt)
        if st != "delivered" { out["ok"] = st == "delivered" }
        for (k, v) in extra { out[k] = v }
        return out
    }

    switch action {
    case "read", "get":
        var out: [String: Any] = ["ok": true, "action": "read", "via": t.via,
                                  "role": role, "name": name,
                                  "value": before, "witness": t.witness,
                                  "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
        if t.scope != "window" { out["proven_in"] = t.scope }
        if t.restricted { out["restricted"] = true }
        return out

    case "click", "press":
        let center = elementCenter(el)
        let prefer = (req["prefer"] as? String) ?? "auto"
        let acts = axActions(el)
        let canPress = acts.contains(kAXPressAction as String) || acts.contains("AXConfirm")
        if prefer == "cg", let c = center {
            let ms = postClick(c)
            return finish("cgevent_forced", "uncertain", "unsafe", "event_posted",
                          ["point": [Double(c.x), Double(c.y)], "click_ms": (ms * 1000).rounded() / 1000])
        }
        var reachable = false
        if prefer != "ax", let c = center {
            if let under = hitTest(c) { reachable = isDescendantOrSelf(under, of: el) }
        }
        // auto 优先 AXPress，理由不是快（它反而要 ~100ms IPC 税），而是它给确定回执：
        // 应答复述「我收到这次按压」，而坐标点击只能给「事件已投递，结果不知」。
        // 复核一次 uncertain 本身要几十毫秒，还得赌落点没被遮挡；这笔账不划算。
        // 真要高频连点（同一窗口几十次）时显式给 --prefer cg，用速度换掉回执。
        var pressErr = 0
        if canPress && prefer != "cg" {
            let e = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if e == .success {
                return finish("axpress", "delivered", "unsafe", "ax_action_result",
                              ["ax_error": 0, "reachable": reachable])
            }
            pressErr = Int(e.rawValue)
        }
        if let c = center, reachable {
            let ms = postClick(c)
            return finish(pressErr == 0 ? "cgevent" : "cgevent_after_axpress_fail",
                          "uncertain", "unsafe", "event_posted",
                          ["point": [Double(c.x), Double(c.y)],
                           "click_ms": (ms * 1000).rounded() / 1000,
                           "ax_error": pressErr])
        }
        if canPress {
            return finish("axpress_failed", "not_delivered", "safe", "ax_action_error",
                          ["ax_error": pressErr, "reachable": false])
        }
        return ["ok": false, "error": "NO_ACTION_PATH", "role": role, "name": name,
                "delivery": deliveryOf("not_delivered", "safe", "no_path")]

    case "setvalue", "fill", "type_into":
        guard let text = req["text"] as? String else { return ["ok": false, "error": "NO_TEXT"] }
        let e = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
        let ok = (e == .success)
        return finish("axsetvalue", ok ? "delivered" : "not_delivered",
                      "safe", ok ? "ax_action_result" : "ax_action_error",
                      ["ax_error": Int(e.rawValue)])

    case "type":
        guard let text = req["text"] as? String else { return ["ok": false, "error": "NO_TEXT"] }
        let e = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if e != .success {
            _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
        postUnicode(text)
        return finish("cgevent_unicode", "uncertain", "unsafe", "event_posted")

    case "key":
        guard let combo = req["key"] as? String else { return ["ok": false, "error": "NO_KEY"] }
        let ok = postKey(combo)
        return finish(ok ? "cgevent_key" : "cgevent_key_failed",
                      ok ? "uncertain" : "not_delivered",
                      "unsafe", ok ? "event_posted" : "no_path")

    case "scroll":
        guard let c = elementCenter(el) else { return ["ok": false, "error": "NO_BBOX"] }
        postScroll(c, dy: Int32((req["dy"] as? Int) ?? 3))
        return finish("cgevent_scroll", "uncertain", "safe", "event_posted")

    default:
        return ["ok": false, "error": "UNKNOWN_ACTION:\(action)"]
    }
}

// 单个元素的现场读数（三态），用于 hit 反查与 state 复核
func elementDigest(_ el: AXUIElement) -> [String: Any] {
    var d: [String: Any] = ["role": evStr(el, kAXRoleAttribute as String).1]
    var ev: [String: String] = [:]
    let (nEv, name) = evStr(el, kAXTitleAttribute as String)
    if !name.isEmpty { d["name"] = name }
    if nEv == .unknown { ev["name"] = "unknown" }
    let (deEv, desc) = evStr(el, kAXDescriptionAttribute as String)
    if !desc.isEmpty { d["desc"] = desc }
    if deEv == .unknown { ev["desc"] = "unknown" }
    let (vEv, value) = evStr(el, kAXValueAttribute as String)
    if !value.isEmpty { d["value"] = value.count > 300 ? String(value.prefix(300)) : value }
    if vEv == .unknown { ev["value"] = "unknown" }
    let en = axRead(el, kAXEnabledAttribute as String)
    switch en.ev {
    case .known:   d["enabled"] = (en.v as? NSNumber)?.boolValue ?? false
    case .absent:  ev["enabled"] = "absent"
    case .unknown: ev["enabled"] = "unknown"
    }
    let box = elementBox(el)
    if box.count == 4 { d["bbox"] = box }
    let acts = axActions(el)
    if !acts.isEmpty { d["actions"] = acts }
    if axBool(el, kAXFocusedAttribute as String) { d["focused"] = true }
    if !ev.isEmpty { d["evidence"] = ev }
    return d
}

func doHit(_ req: [String: Any]) -> [String: Any] {
    let t0 = Date()
    guard let x = req["x"] as? Double, let y = req["y"] as? Double else {
        return ["ok": false, "error": "NO_POINT"]
    }
    guard let el = hitTest(CGPoint(x: x, y: y)) else { return ["ok": false, "error": "NO_ELEMENT"] }
    var d = elementDigest(el)
    d["ok"] = true
    d["pid"] = Int(pidOfElement(el))
    d["elapsed_ms"] = ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000
    return d
}

// 计算名：很多原生控件（计算器按键、部分工具栏图标）自己不暴露 AXTitle，
// 可见文字在内层 AXStaticText 里，或者挂在 AXTitleUIElement 上。
// 浏览器的可访问名也是这么算的，这里对齐同一套规则，否则「按名字找控件」在这些 App 上
// 会全军覆没，只能退化成按位置点。
func cleanText(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{200E}", with: "")
        .replacingOccurrences(of: "\u{200F}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func computedName(_ el: AXUIElement) -> String {
    let tu = axRead(el, "AXTitleUIElement")
    if tu.ev == .known, let tv = tu.v, CFGetTypeID(tv) == AXUIElementGetTypeID() {
        let e2 = tv as! AXUIElement
        let t = cleanText(axStr(e2, kAXTitleAttribute as String))
        if !t.isEmpty && t.count <= 60 { return t }
        let v = cleanText(axStr(e2, kAXValueAttribute as String))
        if !v.isEmpty && v.count <= 60 { return v }
    }
    let kidsR = axRead(el, kAXChildrenAttribute as String)
    if kidsR.ev == .known, let kids = kidsR.v as? [AXUIElement] {
        for k in kids.prefix(4) {
            let r = axStr(k, kAXRoleAttribute as String)
            guard r == "AXStaticText" || r == "AXImage" else { continue }
            let v = cleanText(axStr(k, kAXValueAttribute as String))
            if !v.isEmpty && v.count <= 60 { return v }
            let t = cleanText(axStr(k, kAXTitleAttribute as String))
            if !t.isEmpty && t.count <= 60 { return t }
        }
    }
    return ""
}

// 完整属性转储：定位「为什么按名字找不到」这件事的最后手段。
// 空白树的 App 常把可见标签放在 AXHelp / AXTitleUIElement / AXRoleDescription 里，
// 靠猜属性名一个个试比一次全导出来慢得多。
func doAttrs(_ req: [String: Any]) -> [String: Any] {
    var el: AXUIElement?
    var via = ""
    if let r = req["ref"] as? String {
        guard let e = registry.get(r) else { return ["ok": false, "error": "REF_STALE"] }
        el = e.el; via = "ref"
    } else if let x = req["x"] as? Double, let y = req["y"] as? Double {
        el = hitTest(CGPoint(x: x, y: y)); via = "hit"
    }
    guard let target = el else { return ["ok": false, "error": "NO_ELEMENT"] }

    var names: CFArray?
    guard AXUIElementCopyAttributeNames(target, &names) == .success,
          let list = names as? [String] else {
        return ["ok": false, "error": "NO_ATTRIBUTES"]
    }
    var out: [String: Any] = [:]
    var unknowns: [String] = []
    for n in list.sorted() {
        let r = axRead(target, n)
        switch r.ev {
        case .absent:
            continue
        case .unknown:
            unknowns.append(n)
        case .known:
            if let v = r.v {
                if let s = v as? String {
                    if !s.isEmpty { out[n] = s.count > 200 ? String(s.prefix(200)) : s }
                } else if let n2 = v as? NSNumber {
                    out[n] = n2
                } else if CFGetTypeID(v) == AXValueGetTypeID() {
                    if let p = axPoint(target, n) { out[n] = [Double(p.x), Double(p.y)] }
                    else if let sz = axSize(target, n) { out[n] = [Double(sz.width), Double(sz.height)] }
                } else if let arr = v as? [AXUIElement] {
                    out[n] = "AXUIElement[\(arr.count)]"
                } else {
                    out[n] = "<\(CFGetTypeID(v))>"
                }
            }
        }
    }
    var acts: [String] = []
    var names2: CFArray?
    if AXUIElementCopyActionNames(target, &names2) == .success, let a = names2 as? [String] { acts = a }
    return ["ok": true, "via": via, "pid": Int(pidOfElement(target)),
            "attribute_count": list.count, "attributes": out,
            "actions": acts, "unreadable": unknowns]
}

func doState(_ req: [String: Any]) -> [String: Any] {
    guard let r = req["ref"] as? String else { return ["ok": false, "error": "NO_REF"] }
    let mode = (req["verify"] as? String) ?? "attach"
    let (t, err) = verifyRef(r, mode: mode)
    if let e = err { return ["ok": false, "error": e] }
    guard let t = t else { return ["ok": false, "error": "NO_TARGET"] }
    var d = elementDigest(t.el)
    d["ok"] = true
    d["ref"] = r
    d["witness"] = t.witness
    d["verify"] = mode
    return d
}

func doWaitChange(_ req: [String: Any]) -> [String: Any] {
    let t0 = Date()
    guard let r = req["ref"] as? String else { return ["ok": false, "error": "NO_REF"] }
    let (t, err) = verifyRef(r, mode: (req["verify"] as? String) ?? "attach")
    if let e = err { return ["ok": false, "error": e] }
    guard let t = t else { return ["ok": false, "error": "NO_TARGET"] }
    let el = t.el
    let timeout = (req["timeout_ms"] as? Int) ?? 3000
    let interval = (req["interval_ms"] as? Int) ?? 10
    let before = axStr(el, kAXValueAttribute as String)
    let beforeBox = elementBox(el)
    while Date().timeIntervalSince(t0) * 1000 < Double(timeout) {
        let now = axStr(el, kAXValueAttribute as String)
        if now != before {
            return ["ok": true, "changed": true, "before": before, "after": now,
                    "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
        }
        let box = elementBox(el)
        if box != beforeBox && !box.isEmpty {
            return ["ok": true, "changed": true, "before": before, "after": now,
                    "note": "bbox_changed",
                    "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
        }
        usleep(useconds_t(interval * 1000))
    }
    return ["ok": true, "changed": false, "before": before,
            "after": axStr(el, kAXValueAttribute as String),
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

// MARK: - 窗口枚举（WindowServer 实时）

struct WinInfo {
    let wid: Int
    let pid: Int32
    let owner: String
    let title: String
    let layer: Int
    let bounds: CGRect
    let onscreen: Bool
}

// kCGWindowListOptionOnScreenOnly 返回的数组是「前→后」顺序，首个 layer 0 窗口即最前应用。
func windowInfoList(onScreenOnly: Bool = false) -> [WinInfo] {
    let opts: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll, .excludeDesktopElements]
    let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [WinInfo] = []
    for w in info {
        guard let rawPid = w[kCGWindowOwnerPID as String] as? Int,
              let wid = w[kCGWindowNumber as String] as? Int else { continue }
        let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
        let rect = CGRect(x: (b["X"] as? Double) ?? 0,
                          y: (b["Y"] as? Double) ?? 0,
                          width: (b["Width"] as? Double) ?? 0,
                          height: (b["Height"] as? Double) ?? 0)
        out.append(WinInfo(
            wid: wid,
            pid: Int32(rawPid),
            owner: (w[kCGWindowOwnerName as String] as? String) ?? "",
            title: (w[kCGWindowName as String] as? String) ?? "",
            layer: (w[kCGWindowLayer as String] as? Int) ?? 0,
            bounds: rect,
            onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        ))
    }
    return out
}

func frontmostPid() -> Int32? {
    windowInfoList(onScreenOnly: true).first { $0.layer == 0 }?.pid
}

func mainWindowOf(_ pid: Int32) -> WinInfo? {
    // 同一进程常有不可见的辅助窗口（layer 0、area 更大、onscreen=false），
    // 必须优先取真正在屏的那一个，否则会截到幽灵窗口。
    let all = windowInfoList().filter { $0.pid == pid && $0.layer == 0 }
    let onscreen = all.filter { $0.onscreen }
    let pool = onscreen.isEmpty ? all : onscreen
    let titled = pool.filter { !$0.title.isEmpty }
    let final = titled.isEmpty ? pool : titled
    return final.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

func doWindows(_ req: [String: Any]) -> [String: Any] {
    let list = windowInfoList()
    var rows: [[String: Any]] = []
    for w in list where w.layer == 0 {
        if let spec = req["app"] as? String, !spec.isEmpty {
            guard let app = resolveApp(spec), app.pid == w.pid else { continue }
        }
        rows.append([
            "wid": w.wid, "pid": Int(w.pid), "owner": w.owner, "title": w.title,
            "onscreen": w.onscreen,
            "bbox": [Double(w.bounds.minX), Double(w.bounds.minY),
                     Double(w.bounds.width), Double(w.bounds.height)],
        ])
    }
    return ["ok": true, "count": rows.count, "windows": rows]
}

// MARK: - 视觉通道（窗口截图）

func pngSize(_ path: String) -> (Double, Double) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return (0, 0) }
    return (Double(img.width), Double(img.height))
}

func doShot(_ req: [String: Any]) -> [String: Any] {
    let t0 = Date()
    guard let app = resolveApp(req["app"] as? String) else {
        return ["ok": false, "error": "APP_NOT_FOUND"]
    }
    var candidates = windowInfoList().filter { $0.pid == app.pid && $0.layer == 0 }
    let onscreen = candidates.filter { $0.onscreen }
    if !onscreen.isEmpty { candidates = onscreen }
    if let want = req["window"] as? String, !want.isEmpty {
        let f = candidates.filter { $0.title.contains(want) }
        if !f.isEmpty { candidates = f }
    }
    let titled = candidates.filter { !$0.title.isEmpty }
    if !titled.isEmpty { candidates = titled }
    guard let w = candidates.max(by: {
        $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
    }) else {
        return ["ok": false, "error": "NO_WINDOW", "app": app.name, "pid": Int(app.pid)]
    }
    let out = (req["out"] as? String) ?? "/tmp/mcc-shot-\(w.wid).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -x 静音  -o 不含阴影  -l 指定窗口
    p.arguments = ["-x", "-o", "-l\(w.wid)", "-t", "png", out]
    do { try p.run() } catch {
        return ["ok": false, "error": "SPAWN_FAIL:\(error)"]
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        return ["ok": false, "error": "CAPTURE_FAIL:\(p.terminationStatus)", "wid": w.wid]
    }
    guard FileManager.default.fileExists(atPath: out),
          (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0 > 0 else {
        return ["ok": false, "error": "EMPTY_IMAGE", "wid": w.wid, "path": out]
    }
    let (iw, ih) = pngSize(out)
    let bw = Double(w.bounds.width), bh = Double(w.bounds.height)
    shotLock.lock(); LAST_SHOT[w.wid] = (iw, ih, bw, bh); shotLock.unlock()
    var gridPath: String? = nil
    if (req["grid"] as? Bool) ?? false {
        let gp = (out as NSString).deletingPathExtension + "-grid.png"
        if drawGridOn(out, out: gp, step: (req["grid_step"] as? Int) ?? 100) { gridPath = gp }
    }
    return [
        "ok": true,
        "app": app.name, "pid": Int(app.pid), "wid": w.wid, "title": w.title,
        "path": out,
        "img_w": iw, "img_h": ih,
        "win_x": Double(w.bounds.minX), "win_y": Double(w.bounds.minY),
        "win_w": bw, "win_h": bh,
        "scale_x": bw > 0 ? (iw / bw * 1000).rounded() / 1000 : 0,
        "scale_y": bh > 0 ? (ih / bh * 1000).rounded() / 1000 : 0,
        "bytes": (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0,
        "grid_path": gridPath ?? "",
        "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000,
    ]
}

// MARK: - 无元素通道（自绘界面专用）

// 上一次 shot 的图幅，用于把图片像素换算成窗口内点
var LAST_SHOT: [Int: (imgW: Double, imgH: Double, winW: Double, winH: Double)] = [:]
let shotLock = NSLock()

func shotGeom(_ wid: Int) -> (imgW: Double, imgH: Double, winW: Double, winH: Double)? {
    shotLock.lock(); defer { shotLock.unlock() }
    return LAST_SHOT[wid]
}

func pidOfElement(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

func doClickAt(_ req: [String: Any]) -> [String: Any] {
    guard var x = req["x"] as? Double, var y = req["y"] as? Double else {
        return ["ok": false, "error": "NO_POINT"]
    }
    let space = (req["space"] as? String) ?? "screen"
    var meta: [String: Any] = ["space": space]
    var expectPid: pid_t? = nil

    if space != "screen" {
        guard let app = resolveApp(req["app"] as? String) else {
            return ["ok": false, "error": "APP_NOT_FOUND"]
        }
        if (req["raise"] as? Bool) ?? true {
            _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
            let dl = Date().addingTimeInterval(2)
            while Date() < dl && frontmostPid() != app.pid { usleep(15_000) }
        }
        guard let w = mainWindowOf(app.pid) else {
            return ["ok": false, "error": "NO_WINDOW", "app": app.name]
        }
        if space == "image" {
            guard let last = shotGeom(w.wid), last.winW > 0 else {
                return ["ok": false, "error": "NEED_SHOT_FIRST", "wid": w.wid]
            }
            let sx = last.imgW / last.winW
            let sy = last.imgH / last.winH
            x = x / sx
            y = y / sy
            meta["scale_x"] = (sx * 1000).rounded() / 1000
            meta["scale_y"] = (sy * 1000).rounded() / 1000
        }
        let wx = Double(w.bounds.minX), wy = Double(w.bounds.minY)
        meta["win_x"] = wx
        meta["win_y"] = wy
        x = wx + x
        y = wy + y
        expectPid = app.pid
    }

    // 遮挡守卫：落点若属于别的进程，直接拒绝，不盲点
    if let ep = expectPid, let hit = hitTest(CGPoint(x: x, y: y)) {
        let hp = pidOfElement(hit)
        if hp != ep {
            return ["ok": false, "error": "OCCLUDED", "hit_pid": Int(hp),
                    "expect_pid": Int(ep), "point": [x, y]]
        }
        meta["hit_role"] = axStr(hit, kAXRoleAttribute as String)
        meta["hit_name"] = axStr(hit, kAXTitleAttribute as String)
    }

    let count = max(1, (req["count"] as? Int) ?? 1)
    let t0 = Date()
    var clickMs = 0.0
    for _ in 0..<count {
        clickMs += postClick(CGPoint(x: x, y: y))
        if count > 1 { usleep(60_000) }
    }
    meta["ok"] = true
    meta["point"] = [x, y]
    meta["count"] = count
    meta["click_ms"] = (clickMs * 1000).rounded() / 1000
    meta["elapsed_ms"] = ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000
    return meta
}


// 坐标滚动：自绘列表（朋友圈/抖音）没有可滚动的 AX 元素，只能投滚轮事件
// 悬停：不点击只移动指针，用于唤出自绘界面的悬停菜单
func doMoveAt(_ req: [String: Any]) -> [String: Any] {
    guard var x = req["x"] as? Double, var y = req["y"] as? Double else {
        return ["ok": false, "error": "NO_POINT"]
    }
    let space = (req["space"] as? String) ?? "screen"
    if space != "screen", let app = resolveApp(req["app"] as? String), let w = mainWindowOf(app.pid) {
        if (req["raise"] as? Bool) ?? true {
            _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
            let dl = Date().addingTimeInterval(2)
            while Date() < dl && frontmostPid() != app.pid { usleep(15_000) }
        }
        if space == "image", let last = shotGeom(w.wid), last.winW > 0 {
            x = x / (last.imgW / last.winW)
            y = y / (last.imgH / last.winH)
        }
        x = Double(w.bounds.minX) + x
        y = Double(w.bounds.minY) + y
    }
    let t0 = Date()
    let src = CGEventSource(stateID: .hidSystemState)
    let p = CGPoint(x: x, y: y)
    // 分两段移动，触发 hover 的鼠标进入事件
    let cur = CGEvent(source: nil)?.location ?? p
    let mid = CGPoint(x: (cur.x + p.x) / 2, y: (cur.y + p.y) / 2)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: mid, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    return ["ok": true, "point": [x, y],
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

func doScrollAt(_ req: [String: Any]) -> [String: Any] {
    guard var x = req["x"] as? Double, var y = req["y"] as? Double else {
        return ["ok": false, "error": "NO_POINT"]
    }
    let space = (req["space"] as? String) ?? "screen"
    if space != "screen", let app = resolveApp(req["app"] as? String), let w = mainWindowOf(app.pid) {
        if (req["raise"] as? Bool) ?? true {
            _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
            let dl = Date().addingTimeInterval(2)
            while Date() < dl && frontmostPid() != app.pid { usleep(15_000) }
        }
        if space == "image", let last = shotGeom(w.wid), last.winW > 0 {
            x = x / (last.imgW / last.winW)
            y = y / (last.imgH / last.winH)
        }
        x = Double(w.bounds.minX) + x
        y = Double(w.bounds.minY) + y
    }
    let dy = Int32((req["dy"] as? Int) ?? 5)
    let times = max(1, (req["times"] as? Int) ?? 1)
    let t0 = Date()
    for _ in 0..<times {
        postScroll(CGPoint(x: x, y: y), dy: dy)
        usleep(90_000)
    }
    return ["ok": true, "point": [x, y], "dy": Int(dy), "times": times,
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

// 在截图上叠 100px 网格与坐标标签：视觉读到的数字即为真实像素坐标
func drawGridOn(_ path: String, out: String, step: Int) -> Bool {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setStrokeColor(CGColor(red: 0.9, green: 0.15, blue: 0.2, alpha: 0.35))
    ctx.setLineWidth(1)
    var x = step
    while x < w {
        ctx.move(to: CGPoint(x: CGFloat(x), y: 0))
        ctx.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(h)))
        x += step
    }
    var yt = step
    while yt < h {
        let yy = CGFloat(h - yt)
        ctx.move(to: CGPoint(x: 0, y: yy))
        ctx.addLine(to: CGPoint(x: CGFloat(w), y: yy))
        yt += step
    }
    ctx.strokePath()
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(max(11, step / 4)), nil)
    let color = CGColor(red: 0.85, green: 0.0, blue: 0.1, alpha: 0.95)
    func label(_ s: String, _ px: CGFloat, _ py: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        ctx.textPosition = CGPoint(x: px, y: py)
        CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    }
    var lx = step
    while lx < w { label("\(lx)", CGFloat(lx + 3), CGFloat(h - step / 3 - 4)); lx += step }
    var ly = step
    while ly < h { label("\(ly)", 3, CGFloat(h - ly - step / 4 - 2)); ly += step }
    guard let outImg = ctx.makeImage() else { return false }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, outImg, nil)
    return CGImageDestinationFinalize(dest)
}

func doActivate(_ req: [String: Any]) -> [String: Any] {
    guard let app = resolveApp(req["app"] as? String) else {
        return ["ok": false, "error": "APP_NOT_FOUND"]
    }
    let ra = NSRunningApplication(processIdentifier: app.pid)
    let ok = ra?.activate(options: [.activateAllWindows]) ?? false
    let deadline = Date().addingTimeInterval(3)
    var front = false
    while Date() < deadline {
        if frontmostPid() == app.pid { front = true; break }
        usleep(20_000)
    }
    return ["ok": true, "activated": ok, "frontmost": front,
            "app": app.name, "pid": Int(app.pid)]
}

func doTypeText(_ req: [String: Any]) -> [String: Any] {
    guard let text = req["text"] as? String else { return ["ok": false, "error": "NO_TEXT"] }
    let t0 = Date()
    postUnicode(text)
    return ["ok": true, "chars": text.count, "text": text,
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

// 剪贴板粘贴：Qt / 自绘 / Electron 普遍忽略 CGEvent 的 unicode 注入，
// 但一定响应标准的 ⌘V。这是往任意界面写中文最稳的一条路。
func doPaste(_ req: [String: Any]) -> [String: Any] {
    guard let text = req["text"] as? String else { return ["ok": false, "error": "NO_TEXT"] }
    let t0 = Date()
    let pb = NSPasteboard.general
    let old = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(60_000)
    let ok = postKey("cmd+v")
    let restore = (req["restore"] as? Bool) ?? true
    if restore {
        usleep(useconds_t(max(120, (req["settle_ms"] as? Int) ?? 400) * 1000))
        if let o = old {
            pb.clearContents()
            pb.setString(o, forType: .string)
        }
    }
    return ["ok": ok, "chars": text.count, "text": text,
            "clipboard_restored": restore && old != nil,
            "frontmost": resolveApp(nil)?.name ?? "",
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

func doKeys(_ req: [String: Any]) -> [String: Any] {
    guard let raw = req["key"] as? String, !raw.isEmpty else { return ["ok": false, "error": "NO_KEY"] }
    let t0 = Date()
    var done: [String] = []
    var failed: [String] = []
    for part in raw.split(separator: ",") {
        let combo = part.trimmingCharacters(in: .whitespaces)
        if combo.isEmpty { continue }
        if postKey(combo) { done.append(combo) } else { failed.append(combo) }
        usleep(120_000)
    }
    return ["ok": failed.isEmpty, "sent": done, "failed": failed,
            "frontmost": resolveApp(nil)?.name ?? "",
            "elapsed_ms": ((Date().timeIntervalSince(t0)) * 1000 * 1000).rounded() / 1000]
}

// MARK: - 分发

func handle(_ req: [String: Any]) -> [String: Any] {
    let cmd = (req["cmd"] as? String) ?? ""
    switch cmd {
    case "ping":
        let apps = runningApps()
        // NSRunningApplication.isActive 在无 runloop 的常驻进程里可能过期，以 WindowServer 前序为准
        let fp = frontmostPid()
        let frontName = fp.flatMap { p in apps.first(where: { $0.pid == p })?.name } ?? ""
        return ["ok": true, "version": VERSION, "pid": Int(getpid()),
                "ax_trusted": AXIsProcessTrusted(),
                "screen_trusted": CGPreflightScreenCaptureAccess(),
                "frontmost": frontName,
                "sock": SOCK_PATH]
    case "apps":
        let list = runningApps().map { a -> [String: Any] in
            ["pid": Int(a.pid), "name": a.name, "exe": a.exe, "bundle": a.bundle,
             "frontmost": a.frontmost, "windows": a.windows]
        }
        return ["ok": true, "apps": list]
    case "snapshot":
        return doSnapshot(req)
    case "act":
        return doAct(req)
    case "hit":
        return doHit(req)
    case "attrs":
        return doAttrs(req)
    case "state":
        return doState(req)
    case "waitchange", "wait":
        return doWaitChange(req)
    case "windows":
        return doWindows(req)
    case "shot", "screenshot":
        return doShot(req)
    case "clickat":
        return doClickAt(req)
    case "scrollat":
        return doScrollAt(req)
    case "moveat", "hover":
        return doMoveAt(req)
    case "activate", "focus":
        return doActivate(req)
    case "typetext":
        return doTypeText(req)
    case "keys":
        return doKeys(req)
    case "paste":
        return doPaste(req)
    case "sleep":
        usleep(useconds_t(max(0, (req["ms"] as? Int) ?? 200) * 1000))
        return ["ok": true]
    default:
        return ["ok": false, "error": "UNKNOWN_CMD:\(cmd)"]
    }
}

// MARK: - 实例租约
//
// 没有租约时，两个客户端同时冷启动会各拉起一个 daemon，
// 后起的 unlink 掉 socket 再 bind，前一个就此变成孤儿：
// 占着 AX 句柄与内存，永远 accept 在没人知道的 inode 上。
// 本机实测曾一次留下 13 个孤儿进程，并发任务还会互相打断。
// 修法是把「唯一实例」交给内核判定：锁文件 + flock 独占非阻塞。
// 锁由文件描述符持有，进程一死内核自动释放，不存在需要手工清理的陈旧锁。

var leaseFd: Int32 = -1

func acquireLease() -> Bool {
    let fd = open(LOCK_PATH, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return true }   // 锁文件都建不了，不该成为拒绝启动的理由
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    leaseFd = fd
    writeAll(fd, Data("\(getpid())\n".utf8))
    return true
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var off = 0
        while off < data.count {
            let n = write(fd, base + off, data.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

func handleClient(_ client: Int32) {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(client, &chunk, chunk.count)
        if n <= 0 { break }
        buf.append(contentsOf: chunk[0..<n])
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineData = buf[buf.startIndex..<nl]
            buf.removeSubrange(buf.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            var resp: [String: Any]
            var stop = false
            if let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] {
                if (obj["cmd"] as? String) == "shutdown" {
                    resp = ["ok": true, "bye": true, "pid": Int(getpid())]
                    stop = true
                } else {
                    resp = handle(obj)
                }
            } else {
                resp = ["ok": false, "error": "BAD_JSON"]
            }
            if let out = try? JSONSerialization.data(withJSONObject: resp, options: []),
               var s = String(data: out, encoding: .utf8) {
                s += "\n"
                writeAll(client, s.data(using: .utf8)!)
            }
            if stop {
                close(client)
                unlink(SOCK_PATH)
                exit(0)
            }
        }
    }
    close(client)
}

func serve() {
    if !acquireLease() {
        // 已有实例在跑：安静退出，让客户端去连现成的那个
        print("MCCD_ALREADY_RUNNING pid=\(getpid()) sock=\(SOCK_PATH)")
        fflush(stdout)
        exit(0)
    }

    unlink(SOCK_PATH)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { print("SOCKET_FD_FAIL"); exit(1) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = SOCK_PATH.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in pathBytes.enumerated() where i < 104 { dst[i] = b }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard bound == 0 else { print("BIND_FAIL errno=\(errno)"); exit(1) }
    guard listen(fd, 64) == 0 else { print("LISTEN_FAIL"); exit(1) }
    chmod(SOCK_PATH, 0o600)

    print("MCCD_READY pid=\(getpid()) sock=\(SOCK_PATH) ax=\(AXIsProcessTrusted())")
    fflush(stdout)

    // 每连接一个线程：单线程串行 accept 会让一条 pipe 长连接把其他所有客户端堵死
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        let th = Thread { handleClient(client) }
        th.stackSize = 1 << 20
        th.start()
    }
}

serve()
