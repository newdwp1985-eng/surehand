#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""evidence.py —— 判断层：把「读数」变成「能不能下手」的纯函数。

这一层里没有 IPC、没有 socket、没有子进程，全是输入输出明确的函数，
所以它可以被单测钉住。所有关于「这个元素能不能点」「这次失败要不要重试」
的判断都集中在这里，不散落在各条通道的实现里。

三条规则来自对 vercel-labs/agent-desktop 的逆向，以及我们自己在微信、抖音上
踩过的坑：

1. 证据三态。known / absent / unknown 永不合并。把 unknown 压成 false，
   等于把「我说不准」改写成了「确定没有」，这是所有「偶尔点错」的总根源。
2. 令牌要有证。ref 只在整窗遍历完整、身份唯一、字段全读到的情况下签发；
   没证的只给 handle（能继续观察，不能动手）。
3. 投递与重试分开定价。delivered / not_delivered / uncertain 是「事情做没做」，
   safe / unsafe 是「能不能再做一次」。两者混用就会授权双重投递。
"""

from __future__ import annotations


# ---------------------------------------------------------------- 错误契约

# 每条错误都给出三样东西：类别（该换通道还是该重新观察）、能否重试、下一步做什么。
# 上层 agent 读 code 就该能决断，不该去解析自然语言。
ERRORS = {
    # 观察层：目标不在了，重新看，别猜
    "REF_STALE":         ("stale",      True,  "目标已不在，重新 look"),
    "HANDLE_NOT_TOKEN":  ("stale",      True,  "这只是导航句柄，没有发证；先 look 拿 ref"),
    "TOKEN_RESTRICTED":  ("restricted", True,  "受限令牌只许填值；要点击请用 --app/--role/--id 按身份定位"),
    "REF_REBOUND":       ("stale",      True,  "同一位置换了元素，重新 look"),
    "REF_DETACHED":      ("stale",      True,  "元素已从窗口脱离，重新 look"),
    "AMBIGUOUS":         ("ambiguous",  True,  "命中多个，补 role / id / contains 收窄"),
    "NOT_FOUND":         ("missing",    True,  "整窗没有这个身份，检查名字或改用 --contains"),
    "APP_NOT_FOUND":     ("env",        True,  "应用没在跑，先启动它"),
    "NO_WINDOW":         ("env",        True,  "进程在但没有可访问窗口（最小化/已关闭）"),
    "NO_TARGET":         ("bug",        False, "调用方没给任何定位条件"),
    # 动作层
    "NO_ACTION_PATH":    ("unsupported", False, "既没有可压的动作，坐标也不可达；换视觉通道"),
    "OCCLUDED":          ("occluded",   False, "落点被别的窗口盖住；先 activate 再试"),
    "NO_BBOX":           ("unsupported", False, "元素没有几何，无法按坐标操作"),
    "NEED_SHOT_FIRST":   ("env",        True,  "先 shot 一次，图片坐标才有换算依据"),
    # 通道层
    "CDP_DOWN":          ("env",        True,  "浏览器没开远程调试端口"),
    "DAEMON_DOWN":       ("env",        True,  "桌面守护进程没起来"),
    "TIMEOUT":           ("timeout",    True,  "超时；先 look 看界面到底走到哪一步"),
    # 平台层：Windows 独有的几类拒绝，各自的对策不一样，不能笼统归成「环境错误」
    "FOREGROUND_REFUSED": ("env",       True,  "系统前台锁拒绝了切换；让窗口自己弹出来，或先手动切一次"),
    "UNSUPPORTED_PLATFORM": ("env",     False, "本技能只覆盖 macOS 与 Windows"),
    "NO_UIA":            ("env",        False, "Windows PowerShell 5.1 的 UIAutomation 不可用（pwsh 上没有）"),
    "CAPTURE_FAILED":    ("env",        True,  "截图失败：窗口被遮挡或最小化，先 activate"),
    "CLIPBOARD_FAILED":  ("env",        True,  "剪贴板写不进去；可能有别的程序占着"),
    "BAD_TOKEN":         ("env",        True,  "引擎握手的令牌不对，端点文件可能过期；重启引擎"),
    "BAD_JSON":          ("bug",        False, "发出去的不是合法 JSON 行"),
    "INTERNAL":          ("bug",        False, "引擎内部异常，看引擎日志"),
    # 入力层：参数本身写错了。这一类必须和「目标消失」分开报，
    # 否则用户会一遍遍 look，而真正的问题是漏写了一个 e。
    "REF_MALFORMED":     ("bad_input",  True,  "ref 写法不对：桌面用 d:e12 或 e12，网页用 w:3"),
    "ARG_MISSING":       ("bad_input",  True,  "缺少必填参数，看 --help"),
    "VERB_UNSUPPORTED":  ("unsupported", False, "这条通道没有这个动词，换一个或看 --help"),
    "STEP_BAD":          ("bad_input",  True,  "步骤文件读不到或格式不对：路径要对，内容是 JSON 数组或 {\"steps\": [...]}"),
    # 网页层：fastlane 的步骤级失败，此前落到 unknown 里，提示「未登记的错误」
    "WEB_STEP_FAILED":   ("web",        True,  "网页步骤失败；先 look --web 看页面当前状态"),
    "WEB_NO_TARGET":     ("web",        True,  "网页上没找到该元素；先 look --web 看它叫什么"),
    "WEB_LAYER_DOWN":    ("web",        True,  "四层全都失败；改用截图 + 坐标，或检查页面是否被弹窗遮住"),
}

# 这些错误一旦发生，说明「状态未知」，绝不能盲目重放写操作
UNSAFE_ON_ERROR = {"occluded"}


def classify(error) -> dict:
    """把错误码（可能带 :detail）翻成结构化结论。"""
    raw = str(error or "")
    code = raw.split(":", 1)[0].strip() or "UNKNOWN"
    kind, retry, hint = ERRORS.get(code, ("unknown", False, "未登记的错误，停下来看现场"))
    out = {"code": code, "kind": kind, "retry": retry, "hint": hint}
    if ":" in raw:
        out["detail"] = raw.split(":", 1)[1]
    if kind in UNSAFE_ON_ERROR:
        out["retry"] = False
    return out


# ---------------------------------------------------------------- 令牌

def token_of(node) -> str:
    """node 能动手的凭证：只有 ref 算，handle 不算。"""
    return node.get("ref") or ""


def handle_of(node) -> str:
    return node.get("handle") or node.get("ref") or ""


def token_state(node) -> str:
    if node.get("ref"):
        return "token"
    if node.get("handle"):
        return "handle"
    return "none"


def actionable(node, action=None) -> bool:
    """能不能对它下手。

    三种令牌权限不同：
      完整令牌  —— action 给什么都放行
      受限令牌  —— 只放行动作不落到坐标上的那几类（填值、读值）
      导航句柄  —— 一律不行（没 ref）

    action 不给时按"能不能当作通用目标动手"判，受限令牌算不能 ——
    因为调用方还没说自己要做什么，而点击是最常见的那种。
    """
    if not node.get("ref"):
        return False
    if node.get("ambiguous"):
        return False
    if node.get("restricted"):
        return action in ("fill", "read", "state")
    return True


# ---------------------------------------------------------------- 投递

def has_delivery(res) -> bool:
    """只有写动作才有投递语义。观察类（snapshot/activate/state）没有「送达」这回事。"""
    return bool(res.get("delivery"))


def delivery(res) -> dict:
    """归一化动作结果里的投递语义。缺字段时退回最保守的判断。"""
    d = res.get("delivery") or {}
    if not d:
        return {"state": "uncertain" if res.get("ok") else "not_delivered",
                "retry": "unsafe", "witness": "unreported"}
    state = d.get("state", "uncertain")
    retry = d.get("retry", "unsafe")
    # 已经确认送达时，「能不能重试」是个无意义的问题。写 n/a 而不是沿用 unsafe：
    # 读结果的人不该被一个不适用的字段牵着走。
    if state == "delivered":
        retry = "n/a"
    return {"state": state, "retry": retry, "witness": d.get("witness", "")}


def delivered(res) -> bool:
    return delivery(res)["state"] == "delivered"


def retry_ok(res) -> bool:
    d = delivery(res)
    return d["state"] == "not_delivered" and d["retry"] == "safe"


def verdict(res) -> str:
    """一步的结论：ok / unverified / fail。unverified 不等于失败，它只是没拿到确认。"""
    if not res:
        return "fail"
    if not has_delivery(res):
        return "ok" if res.get("ok") else "fail"
    state = delivery(res)["state"]
    if state == "delivered":
        return "ok"
    if state == "uncertain":
        return "unverified"
    return "fail"


def describe(res) -> str:
    """一句话说清结果。注意 uncertain 不是失败，它是第三种结局。"""
    if not has_delivery(res):
        if res.get("ok"):
            return "完成"
        c = classify(res.get("error"))
        return "失败 %s（%s）：%s" % (c["code"], c["kind"], c["hint"])
    d = delivery(res)
    if d["state"] == "uncertain":
        return "已发出但未确认（依据 %s）；重试%s" % (
            d["witness"], "危险" if d["retry"] == "unsafe" else "安全")
    if not res.get("ok") or d["state"] == "not_delivered":
        c = classify(res.get("error"))
        return "未送达 %s（%s）：%s" % (c["code"], c["kind"], c["hint"])
    return "已送达（依据 %s）" % d["witness"]


# ---------------------------------------------------------------- 快照结论

# 这些角色本身意味着「界面有内容可读」，与有没有名字无关。
# 同时收录 macOS 的 AX 名与 UIA 的官方名——两个平台跑同一套判断，不该有两份表。
STRUCTURAL_ROLES = {
    "axtextfield", "axtextarea", "axsearchfield", "axcombobox", "axlist", "axoutline",
    "axtable", "axcell", "axrow", "axlink", "axcheckbox", "axradiobutton", "axmenuitem",
    "axtabgroup", "axslider", "axwebarea", "axscrollarea", "text", "input", "textarea",
    "select", "a", "button",
    # UIA
    "edit", "document", "hyperlink", "tree", "treeitem", "tab", "tabitem", "spinner",
    "listitem", "dataitem", "datagrid", "menuitem", "slider",
}


def _substantive(nodes):
    """去掉「窗口本身」与「红绿灯」之后，还剩多少真能操作的东西。

    微信、抖音这类自绘界面读出来恰好是：一个窗口框 + 三个无名按钮 + 若干空组。
    如果只数节点数，它们会被误判成「有结构」；按「有意义的目标」数才分得开。
    """
    keep = []
    for n in nodes:
        role = (n.get("role") or "").lower()
        if role in ("axwindow", "window"):
            continue
        if n.get("name") or n.get("id"):
            keep.append(n)
        elif role in STRUCTURAL_ROLES and role not in ("button",):
            keep.append(n)
    return keep


def summarize(snap) -> dict:
    """把快照读成一句能用的结论：这个界面属于哪一类，能怎么操作。"""
    if not snap.get("ok"):
        return {"ok": False, "surface": "unknown", "error": snap.get("error"),
                "error_info": classify(snap.get("error"))}
    nodes = snap.get("nodes") or []
    tokens = [n for n in nodes if actionable(n)]
    handles = [n for n in nodes if token_state(n) == "handle"]
    visited = snap.get("visited") or len(nodes)
    complete = bool(snap.get("complete"))

    real = _substantive(nodes)
    named = [n for n in tokens if n.get("name") or n.get("id")]

    # 只剩窗口框和几个红绿灯：结构面没内容，只能走视觉
    if not real and visited <= 24:
        surface = "visual"
        why = "整窗只有 %d 个节点，去掉窗口框和红绿灯后没有可读目标（自绘界面）" % visited
    elif not complete:
        surface = "partial"
        why = "遍历不完整（%s），只够摸结构" % "、".join(snap.get("incomplete_because") or [])
    else:
        surface = "structure"
        why = "整窗 %d 节点，%d 个可操作令牌" % (visited, len(tokens))

    return {"ok": True, "surface": surface, "why": why,
            "complete": complete, "visited": visited,
            "tokens": len(tokens), "handles": len(handles),
            "withheld": snap.get("refs_withheld", 0),
            "scope": snap.get("scope", "window"),
            "snapshot_id": snap.get("snapshot_id", "")}


# 角色名归一化：macOS 是 AXButton，UIA 是 button / edit。判断层不该因此分裂，
# 所以比较前先收敛到同一个键。这里只做小写去前缀与少量别名，翻译在 transport 里。
_ROLE_ALIAS = {
    "edit": "textfield", "hyperlink": "link", "tree": "outline", "treeitem": "outlineitem",
    "dataitem": "cell", "tab": "tabgroup", "tabitem": "tab", "document": "textarea",
    "statictext": "text", "progressbar": "progressindicator", "splitbutton": "popupbutton",
}


def canon_role(role) -> str:
    k = (role or "").strip().lower()
    if k.startswith("ax"):
        k = k[2:]
    return _ROLE_ALIAS.get(k, k)


def choose(nodes, name=None, role=None, ident=None, contains=False) -> tuple:
    """按身份挑元素。返回 (候选列表, 结论字符串)。不做「取第一个」这种猜测。"""
    out = []
    want = canon_role(role) if role else ""
    for n in nodes:
        if want and canon_role(n.get("role")) != want:
            continue
        if ident and n.get("id") != ident:
            continue
        if name:
            hay = [n.get("name") or "", n.get("value") or "", n.get("desc") or ""]
            hit = any(name in h for h in hay) if contains else (name in hay)
            if not hit:
                continue
        out.append(n)
    if not out:
        return [], "没有匹配"
    if len(out) == 1:
        return out, "唯一命中"
    return out, "命中 %d 个，必须收窄" % len(out)


def merge_evidence(*vals) -> str:
    """多个读数求交：任何一个说不准，结果就是说不准；全部确定没有才是没有。"""
    states = list(vals)
    if "unknown" in states:
        return "unknown"
    if "known" in states:
        return "known"
    return "absent"


def predicate_gate(node, field) -> dict:
    """按字段做谓词判断，Unknown 永不取反。

    返回 {"value": True/False/None, "evidence": "known"/"absent"/"unknown"}。
    None 表示「说不准」，调用方必须当作第三种结果处理，不能落进 else 分支。
    """
    ev = (node.get("evidence") or {}).get(field)
    if ev == "unknown":
        return {"value": None, "evidence": "unknown"}
    if field == "enabled":
        if "enabled" in node:
            return {"value": bool(node["enabled"]), "evidence": "known"}
        return {"value": None, "evidence": ev or "absent"}
    return {"value": None, "evidence": ev or "unknown"}
