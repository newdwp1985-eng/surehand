#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cu.py —— 电脑操作的统一入口。

只有一个入口、一套 ref 语义、一种结果形状，底层两条通道（桌面 AX / 浏览器 CDP）
对调用者不可见。设计目标不是「功能最多」，而是「不猜」。

四条不猜：
  1. 不猜该走哪条通道 —— look 会告诉你这个界面属于 structure / visual / partial。
  2. 不猜元素指谁 —— ref 是发过证的令牌，没证的 element 只给 handle，动手会被拒。
  3. 不猜动作做没做 —— 每个动作都带 delivery.state 与 retry，不确定就说不确定。
  4. 不猜失败要不要重试 —— 错误带 kind，stale 才重看，occluded 绝不重放。

用法见 references/cli.md；日常最短路径：
  cu.py look --app 微信          # 先看，拿到结论与 ref
  cu.py do click --ref d:e12     # 再动
  cu.py do paste --text "你好"   # 视觉通道写文字一律 paste
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import transport as desk   # noqa: E402
import evidence            # noqa: E402
import web                 # noqa: E402

ROOT = HERE.parent
STATE = ROOT / ".state.json"
MAX_IDENTITIES = 600


def skill_version():
    """版本号只有一个源头：SKILL.md 的 frontmatter。

    在 cli 里另写一个常量，迟早和引擎、MCP server 各说各话——
    调用方问「你跑的是哪个版本」，得到三个答案比没有答案更糟。
    """
    try:
        text = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    except OSError:
        return "unknown"
    for line in text.splitlines()[:20]:
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().strip('"\'')
    return "unknown"


# ---------------------------------------------------------------- 状态

def load_state():
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(st):
    st["ts"] = time.time()
    try:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def remember_desk(snap):
    st = load_state()
    ident = {}
    for n in snap.get("nodes") or []:
        tok = evidence.handle_of(n)
        if not tok:
            continue
        if len(ident) >= MAX_IDENTITIES:
            break
        ident[tok] = {"role": n.get("role"), "name": n.get("name") or "",
                      "id": n.get("id") or "", "token": evidence.token_state(n)}
    st["desk"] = {"app": snap.get("app"), "pid": snap.get("pid"),
                  "window": snap.get("window"), "snapshot_id": snap.get("snapshot_id"),
                  "ts": time.time(), "identities": ident}
    save_state(st)
    return st


def remember_web(snap, nodes):
    st = load_state()
    ident = {}
    for n in nodes[:MAX_IDENTITIES]:
        ident[n["ref"]] = {"role": n.get("role"), "name": n.get("name") or ""}
    st["web"] = {"url": snap.get("ref_valid_at") or snap.get("url"),
                 "count": snap.get("count"),
                 "ts": time.time(), "identities": ident}
    save_state(st)
    return st


# ---------------------------------------------------------------- 输出

def out(obj, human=None, as_json=False):
    if as_json or human is None:
        print(json.dumps(obj, ensure_ascii=False))
    else:
        print(human)
    return 0 if obj.get("ok") is not False else 1


def print_look_desk(snap, summary):
    head = "[%s] %r  %s  %s  %.1f ms" % (
        snap.get("app"), snap.get("window") or "", summary["surface"],
        summary["why"], snap.get("elapsed_ms") or 0)
    print(head)
    if summary["surface"] == "visual":
        print("  → 结构面读不到东西。走视觉通道：shot 拿几何，tap 按窗口内点数点击，写文字用 paste。")
    elif summary["surface"] == "partial":
        print("  → 只够摸结构。要动手请去掉 --depth，或用 --from <handle> 钻进某个区域。")
    if snap.get("refs_withheld"):
        print("  扣证 %d 个（不唯一或身份没读全），它们只有 handle 没有 ref，不能直接动手"
              % snap["refs_withheld"])
    for n in snap.get("nodes") or []:
        # 令牌和句柄必须长得不一样。都是 e12 形态时，只能靠尾巴上的标签分辨谁不能点，
        # 一眼扫过去就会把一个「看过」误当「点得」。句柄统一带 · 前缀。
        ref, handle = n.get("ref"), n.get("handle")
        label = ref if ref else ("·" + handle if handle else "·")
        bits = ["  " * min(n.get("depth", 0), 6) + label,
                (n.get("role") or "").replace("AX", "")]
        if n.get("name"):
            bits.append(repr(n["name"]))
        if n.get("id"):
            bits.append("#" + n["id"])
        if n.get("value"):
            v = n["value"]
            bits.append("=" + (repr(v) if len(v) <= 40 else repr(v[:37] + "...")))
        if n.get("bbox"):
            bits.append("@%d,%d %dx%d" % tuple(n["bbox"]))
        if n.get("focused"):
            bits.append("*focus")
        if n.get("enabled") is False:
            bits.append("[disabled]")
        ev = n.get("evidence") or {}
        if ev.get("enabled") == "unknown":
            bits.append("[enabled 说不准]")
        if ev.get("identity") == "unknown":
            bits.append("[身份没读全]")
        if n.get("restricted"):
            bits.append("[仅可填]")
        if n.get("proven_in"):
            bits.append("[%s内唯一]" % n["proven_in"])
        if n.get("ambiguous"):
            bits.append("[不唯一 ×%d]" % n["ambiguous"])
        if n.get("addressed_by") == "geometry":
            bits.append("[靠位置]")
        print(" | ".join(bits))


def print_look_web(nodes, snap, summary):
    print("[web] %s  %s 个元素  %s" % (
        snap.get("ref_valid_at") or snap.get("url") or "", len(nodes), summary["why"]))
    for n in nodes:
        bits = [n["ref"], n.get("role") or n.get("tag") or "?"]
        if n.get("name"):
            bits.append(repr(n["name"])[:60])
        if n.get("value"):
            bits.append("=" + repr(n["value"])[:40])
        if n.get("enabled") is False:
            bits.append("[disabled]")
        if n.get("actionable") is False:
            bits.append("[只读]")
        print(" | ".join(bits))
    frames = snap.get("frame_count") or 0
    if frames:
        labels = [x for x in (snap.get("frames") or []) if x]
        print("  ! 页面含 %d 个内嵌框架，其内部元素不在本次快照里%s"
              % (frames, ("：%s" % "、".join(labels[:3])) if labels else ""))
        print("    要操作框架内的元素，用 do goto 打开该框架自己的地址，或直接对整页截图走视觉通道。")


# ---------------------------------------------------------------- ref 解析

class BadInput(Exception):
    """调用方给的参数或文件本身有问题。

    带错误码是硬要求：这些分支以前直接 `raise SystemExit("中文提示")`，
    走 --json 时输出既不是 JSON、也没有 code，机器调用方拿到的是一行
    中文散文——解析失败后只能猜。人眼看的提示和机器看的码，缺一不可。
    """

    code = "ARG_MISSING"

    def __init__(self, msg="", code=None):
        super().__init__(msg)
        if code:
            self.code = code


class RefFormatError(BadInput):
    """ref 写法本身不合法。与「目标消失」是两件事，不能共用 REF_STALE。"""

    code = "REF_MALFORMED"


_REF_DESK = re.compile(r"^(?:e)?(\d+)$", re.I)
_REF_WEB = re.compile(r"^(\d+)$")


def parse_ref(ref):
    """d:e12 / e12 → 桌面令牌；w:3 → 网页令牌。

    非法写法抛 RefFormatError 而不是硬塞给引擎：引擎查不到只会回 REF_STALE，
    提示「目标已不在，重新 look」——用户照着做一万次也不会发现是自己少写了个 e。
    """
    if not ref:
        return (None, None)
    r = str(ref).strip()
    low = r.lower()
    if low.startswith(("w:", "web:")):
        tail = r.split(":", 1)[1]
        m = _REF_WEB.match(tail)
        if not m:
            raise RefFormatError("网页 ref 应写成 w:3 这种形式，收到 %r" % ref)
        return ("web", m.group(1))
    if low.startswith(("d:", "desk:")):
        tail = r.split(":", 1)[1]
        m = _REF_DESK.match(tail)
        if not m:
            raise RefFormatError("桌面 ref 应写成 d:e12 或 e12，收到 %r" % ref)
        return ("desk", "e" + m.group(1))
    m = _REF_DESK.match(r)
    if m:
        return ("desk", "e" + m.group(1))
    raise RefFormatError("认不出的 ref %r：桌面用 d:e12 或 e12，网页用 w:3" % ref)


def require_desk_ref(ref):
    surface, tok = parse_ref(ref)
    if surface != "desk":
        raise BadInput("这是网页 ref（%s），--web 只认 w:N 这种网页 ref；桌面动作别加 --web" % ref,
                        "REF_MALFORMED")
    return tok


# ---------------------------------------------------------------- 命令

def cmd_up(a):
    report = {"ok": True, "desk": {}, "web": {}}
    try:
        started = desk.start()
        report["desk"] = dict(desk.health(), started=started)
    except Exception as exc:
        report["desk"] = {"daemon": False, "error": str(exc)[:200]}
        report["ok"] = False
    if getattr(a, "launch", False) and not web.health().get("cdp_alive"):
        report["launched"] = web.launch()
    report["web"] = web.health()

    if a.json:
        return out(report, as_json=True)

    d, w = report["desk"], report["web"]
    print("平台：%s" % d.get("platform", desk.PLATFORM))
    print("桌面通道：%s" % ("就绪 v%s pid=%s" % (d.get("version"), d.get("pid"))
                          if d.get("daemon") else "不可用 %s" % d.get("error", "")))
    if d.get("daemon"):
        if desk.PLATFORM == "windows":
            print("  UIA 可用=%s  当前前台=%s"
                  % (d.get("ax_trusted"), d.get("frontmost") or "-"))
            print("  注意：以管理员身份运行的窗口受 UIPI 保护，普通权限进程点不进去；"
                  "需要时也用管理员身份启动本工具。")
        else:
            print("  辅助功能权限=%s  屏幕录制权限=%s  当前前台=%s"
                  % (d.get("ax_trusted"), d.get("screen_trusted"), d.get("frontmost") or "-"))
            if not d.get("ax_trusted"):
                print("  ! 需要授权：系统设置 → 隐私与安全性 → 辅助功能")
            if not d.get("screen_trusted"):
                print("  ! 需要授权：系统设置 → 隐私与安全性 → 屏幕录制（视觉通道要用）")
    print("浏览器通道：%s" % ("就绪 %s，%s 个标签页" % (w.get("browser"), w.get("pages"))
                            if w.get("cdp_alive") else "未连上 %s 端口" % w.get("port")))
    if not w.get("cdp_alive"):
        print("  浏览器需要在启动时带 --remote-debugging-port=%s。已经开着的 Chrome 无法事后开启，"
              % w.get("port"))
        print("  要么退出后用带参数的方式重启（会保留你的登录态），要么只用桌面通道操作浏览器外壳。"
              "`--launch` 可以直接替你起一个。")
    return 0 if report["ok"] else 1


def _instance_count():
    """同名引擎进程数。单实例由引擎自己的锁保证，这里只是事后核对。"""
    import subprocess
    try:
        if desk.PLATFORM == "windows":
            r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq powershell.exe", "/FO", "CSV"],
                               capture_output=True, text=True, timeout=15)
            # PowerShell 宿主进程不止引擎一个，只能靠命令行区分，退化为未知
            return 0
        pat = str(desk.BIN)
        r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True, timeout=15)
        return len([x for x in (r.stdout or "").split() if x.strip()])
    except Exception:
        return 0


def cmd_doctor(a):
    d = desk.health()
    w = web.health()
    multi = _instance_count()
    rep = {"ok": True, "version": skill_version(),
           "desk": d, "web": w, "daemon_instances": multi,
           "state_file": str(STATE), "state_exists": STATE.is_file(),
           "binaries": {"engine": str(desk.BIN if desk.PLATFORM == "macos" else desk.WCCD),
                        "engine_exists": (desk.BIN if desk.PLATFORM == "macos" else desk.WCCD).is_file(),
                        "browser": str(web.CLI), "browser_exists": web.CLI.is_file(),
                        "cdp_lib": str(web.CDP_LIB), "cdp_lib_exists": web.CDP_LIB.is_file()}}
    if not web.CDP_LIB.is_file():
        # 这一项缺失时网页通道会在真正用到时才炸，报错还指向别的技能。
        # 自包含是这个仓库的核心承诺，必须能在体检里一眼看出来。
        rep["ok"] = False
        rep["warning"] = "缺少 vendor/browser/cdp.py，网页通道不可用（仓库不完整）"
    if desk.PLATFORM == "unsupported":
        rep["ok"] = False
        rep["warning"] = "不支持的平台 %s，本技能只覆盖 macOS 与 Windows" % sys.platform
    if multi > 1:
        rep["ok"] = False
        rep["warning"] = "检测到 %d 个引擎实例，应当只有 1 个" % multi
    if a.json:
        return out(rep, as_json=True)
    print(json.dumps(rep, ensure_ascii=False, indent=2))
    return 0 if rep["ok"] else 1


def cmd_launch(a):
    r = web.launch(port=a.port, profile=a.profile or None, url=a.url)
    if a.json:
        return out(r, as_json=True)
    if r.get("ok"):
        print("浏览器通道就绪：%s，端口 %s（profile: %s）"
              % (r.get("browser") or "chromium", r.get("port"), r.get("profile") or "沿用已有"))
        if not r.get("already"):
            print("  这是独立 profile，原来的登录态不在里面；需要登录的站点得在这个窗口里登一次。")
    else:
        print("起不来 %s：%s" % (r.get("error"), r.get("hint", "")))
    return 0 if r.get("ok") else 1


def cmd_apps(a):
    r = desk.apps()
    rows = r.get("apps") or []
    if a.filter:
        f = a.filter.lower()
        rows = [x for x in rows if f in ((x.get("name") or "") + (x.get("bundle") or "")).lower()]
    if a.json:
        return out({"ok": True, "apps": rows}, as_json=True)
    for x in rows:
        print("%-6s %-24s win=%d%s  %s" % (x["pid"], x["name"], x["windows"],
                                           "  *front" if x.get("frontmost") else "",
                                           x.get("bundle") or ""))
    return 0


def cmd_activate(a):
    """切前台。很多动作要求目标在前台，这步没有回执可拿，只能事后看 frontmost。"""
    r = desk.activate(a.app)
    if a.json:
        return out(r, as_json=True)
    if r.get("ok"):
        print("已切到前台：%s" % (r.get("app") or a.app))
        return 0
    print(evidence.describe(r))
    return 1


def cmd_look(a):
    if a.web:
        snap = web.snapshot(target=a.target, url_contains=a.url_contains)
        nodes = web.normalize(snap.get("nodes"))
        n_act = sum(1 for n in nodes if n.get("actionable", True))
        n_read = len(nodes) - n_act
        summary = {"ok": True, "surface": "web", "complete": True,
                   "tokens": n_act, "handles": n_read, "withheld": 0,
                   "visited": len(nodes), "scope": "page", "snapshot_id": "",
                   "why": "%d 个可操作  %d 个只读" % (n_act, n_read)}
        remember_web(snap, nodes)
        if a.json:
            return out({"ok": True, "surface": "web", "summary": summary,
                        "url": snap.get("ref_valid_at"), "nodes": nodes}, as_json=True)
        print_look_web(nodes, snap, summary)
        return 0

    snap = desk.snapshot(app=a.app, window=a.window, max_nodes=a.max,
                         include_static=not a.no_static,
                         from_ref=a.from_ref, max_depth=a.depth)
    summary = evidence.summarize(snap)
    if snap.get("ok"):
        remember_desk(snap)
    if a.json:
        return out(dict(snap, summary=summary), as_json=True)
    if not snap.get("ok"):
        info = summary.get("error_info") or {}
        print("FAIL %s（%s）%s" % (info.get("code"), info.get("kind"), info.get("hint")))
        return 1
    print_look_desk(snap, summary)
    return 0


def cmd_find(a):
    if not a.text and getattr(a, "name", ""):
        a.text = a.name
    if a.web:
        snap = web.snapshot(target=a.target, url_contains=a.url_contains)
        nodes = web.normalize(snap.get("nodes"))
        hits, why = evidence.choose(nodes, name=a.text, role=a.role,
                                   ident=a.ident, contains=a.contains)
        if a.json:
            return out({"ok": bool(hits), "why": why, "hits": hits}, as_json=True)
        print("%s：%s" % (why, ", ".join(h["ref"] for h in hits) or "无"))
        for h in hits:
            print("  %s %s %r" % (h["ref"], h.get("role"), h.get("name")))
        return 0 if len(hits) == 1 else 1

    snap = desk.snapshot(app=a.app, window=a.window, max_nodes=a.max)
    if not snap.get("ok"):
        info = evidence.classify(snap.get("error"))
        if a.json:
            return out({"ok": False, "error": snap.get("error"), "info": info}, as_json=True)
        print("FAIL %s：%s" % (info["code"], info["hint"]))
        return 1
    remember_desk(snap)
    hits, why = evidence.choose(snap.get("nodes") or [], name=a.text, role=a.role,
                               ident=a.ident, contains=a.contains)
    if a.json:
        return out({"ok": len(hits) == 1, "why": why, "hits": hits,
                    "snapshot_id": snap.get("snapshot_id")}, as_json=True)
    print("%s：%s" % (why, ", ".join((h.get("ref") or h.get("handle") or "·") for h in hits) or "无"))
    for h in hits:
        extra = ""
        if h.get("id"):
            extra += "  #" + h["id"]
        if h.get("restricted"):
            extra += "  [仅可填]"
        if not evidence.actionable(h):
            extra += "  [不可动手]"
        print("  %s %s %r%s" % (h.get("ref") or h.get("handle") or "·", h.get("role"),
                                h.get("name") or "", extra))
    return 0 if len(hits) == 1 else 1


def _desk_act(a, action):
    req = {"cmd": "act", "action": action,
           "verify": "strict" if a.strict else "attach"}
    if a.ref:
        req["ref"] = require_desk_ref(a.ref)
    else:
        for k, v in (("app", a.app), ("window", a.window), ("role", a.role),
                     ("name", a.name), ("id", a.ident)):
            if v:
                req[k] = v
        if a.contains:
            req["contains"] = True
    if a.text is not None and action in ("setvalue", "type"):
        req["text"] = a.text
    if a.dy is not None:
        req["dy"] = a.dy
    if a.prefer:
        req["prefer"] = a.prefer
    if not (a.ref or a.name or a.ident or a.role):
        raise BadInput("要么给 --ref，要么给 --app/--role/--name/--id")
    return desk.call(req)


def cmd_do(a):
    verb = a.verb
    if a.web or (a.ref and parse_ref(a.ref)[0] == "web") or (verb in ("goto", "press", "eval", "wait")):
        return _web_do(a)

    if verb == "key":
        r = desk.keys(a.combo or a.text or "")
        res = dict(r, method="cgevent_key")
        # 组合键解析失败 = 确定没送到；投递成功才是「说不准」
        res["delivery"] = ({"state": "uncertain", "retry": "unsafe", "witness": "event_posted"}
                           if r.get("ok") else
                           {"state": "not_delivered", "retry": "safe", "witness": "no_path"})
    elif verb == "paste":
        r = desk.paste(a.text or "")
        res = dict(r, method="clipboard_cmdv")
        res["delivery"] = ({"state": "uncertain", "retry": "unsafe", "witness": "event_posted"}
                           if r.get("ok") else
                           {"state": "not_delivered", "retry": "safe", "witness": "no_path"})
    elif verb == "scroll" and a.ref:
        res = _desk_act(a, "scroll")
    elif verb == "read":
        tok = require_desk_ref(a.ref) if a.ref else None
        res = desk.state(tok, verify="strict" if a.strict else "attach")
    elif verb == "click":
        res = _desk_act(a, "click")
    elif verb == "activate":
        if not a.app:
            raise BadInput("activate 需要 --app")
        res = desk.activate(a.app)
        if a.json:
            return out(res, as_json=True)
        print("已切到前台：%s" % a.app if res.get("ok") else evidence.describe(res))
        return 0 if res.get("ok") else 1
    elif verb == "fill":
        res = _desk_act(a, "setvalue")
    elif verb == "type":
        res = _desk_act(a, "type")
    else:
        raise BadInput("桌面通道不支持 %s；可用的：click fill type read key paste scroll" % verb,
                            "VERB_UNSUPPORTED")

    if a.json:
        return out(res, as_json=True)
    print(evidence.describe(res))
    if verb == "read":
        # read 是纯读操作：没有「投递」这回事，只有「读到什么」。
        # 用 click 的投递语义去描述它，会让调用方以为读也有不确定性。
        val = res.get("value")
        if val is None and isinstance(res.get("text"), str):
            val = res.get("text")
        if val is None:
            print("  没有可读文本（元素存在但值为空）")
            return 0
        shown = val if len(str(val)) <= 2000 else str(val)[:2000] + "…"
        print("  %s" % shown)
        return 0
    d = evidence.delivery(res)
    line = "  %s" % (res.get("method") or res.get("role") or "")
    if res.get("before") != res.get("after") and res.get("before") is not None:
        line += "  %r → %r" % (res.get("before"), res.get("after"))
    line += "  投递=%s 重试=%s" % (d["state"], d["retry"])
    print(line)
    if d["state"] == "uncertain" and d["retry"] == "unsafe":
        print("  ! 动作已发出但没拿到确认。请先 look 复核界面，不要直接重放。")
        return 2
    return 0 if d["state"] == "delivered" else 1


def _web_do(a):
    verb = a.verb
    if verb == "goto":
        st = {"op": "goto", "url": a.url or a.text}
    elif verb == "press":
        st = {"op": "press", "key": a.combo}
    elif verb == "eval":
        st = {"op": "eval", "expr": a.text}
    elif verb == "wait":
        st = {"op": "wait", "expr": a.text, "timeout": a.timeout}
    elif verb == "scroll":
        st = {"op": "scroll", "dy": a.dy or 700}
    else:
        action = {"click": "click", "fill": "fill", "read": "read",
                  "hover": "hover", "type": "fill"}.get(verb)
        if not action:
            raise BadInput("网页通道不支持 %s" % verb, "VERB_UNSUPPORTED")
        if a.ref:
            surface, tok = parse_ref(a.ref)
            # --web 会把任何 ref 都送进这条分支。d:e12 进来后 tok 是 "e12"，
            # 下面 int(tok) 当场抛 ValueError，用户看到的是 "FAIL ValueError:..."，
            # 既没有错误码也没告诉他该怎么办。在这里就拦住。
            if surface == "desk":
                raise BadInput("这是桌面 ref（%s），网页通道不认；"
                               "要么去掉 --web 走桌面，要么用 look --web 拿 w:N" % a.ref,
                               "REF_MALFORMED")
            loc = {"by": "ref", "value": int(tok)}
            st = {"action": action, "locator": loc}
            st["_expect"] = (load_state().get("web", {}).get("identities", {})
                             .get(a.ref))
        elif a.text or a.role or a.css:
            loc = {"by": "auto"}
            if a.text and not a.role:
                loc = {"by": "name", "value": a.text}
            elif a.text:
                loc["text"] = a.text
            if a.role:
                loc["role"] = a.role
                loc["name"] = a.name or ""
            if a.css:
                loc["css"] = a.css
            st = {"action": action, "locator": loc}
        else:
            raise BadInput("要么给 --ref，要么给 --text/--role/--css")
        if action == "fill":
            st["value"] = a.text_value if a.text_value is not None else (a.text or "")
        if action == "read":
            st.pop("value", None)

    r = web.act_on(st, recheck=not a.fast, target=a.target,
                   url_contains=a.url_contains)
    if a.json:
        return out(r, as_json=True)
    if r.get("ok"):
        note = ""
        if "value" in r and r["value"] is not None:
            note = "  → %r" % (r["value"],)
        print("网页动作完成（层 %s）%s" % (r.get("layer") or "-", note))
        if (r.get("web") or {}).get("ref_rebound"):
            print("  ! ref 编号已被别的元素复用，已改按身份定位")
        if (r.get("web") or {}).get("rechecked"):
            print("  已按 saved-ref 身份复核：%s"
                  % ("一致" if r["web"].get("identity_match") else "不一致，已切换定位"))
        return 0
    info = evidence.classify(r.get("error"))
    print("FAIL %s（%s）%s" % (info["code"], info["kind"], info["hint"]))
    return 1


def cmd_tap(a):
    r = desk.tap(a.app, a.x, a.y, space=a.space, count=a.count)
    if a.json:
        return out(r, as_json=True)
    if r.get("ok"):
        print("点击窗口内 (%s,%s) → 屏幕 (%s,%s)  %s"
              % (a.x, a.y, r.get("point", ["?", "?"])[0], r.get("point", ["?", "?"])[1],
                 r.get("hit_role") or ""))
        print("  投递=uncertain 重试=unsafe（坐标点击拿不到应用确认，必须靠截图复核）")
        return 0
    info = evidence.classify(r.get("error"))
    print("FAIL %s（%s）%s" % (info["code"], info["kind"], info["hint"]))
    return 1


def cmd_scroll(a):
    r = desk.scroll_at(a.app, a.x, a.y, dy=a.dy, times=a.times, space=a.space)
    return out(r, "滚动 %s 次 dy=%s %s" % (a.times, a.dy, "ok" if r.get("ok") else r.get("error")), a.json)


def cmd_hover(a):
    r = desk.hover(a.app, a.x, a.y, space=a.space)
    return out(r, "悬停 (%s,%s) %s" % (a.x, a.y, "ok" if r.get("ok") else r.get("error")), a.json)


def cmd_shot(a):
    r = desk.shot(app=a.app, window=a.window, out=a.out, grid=a.grid,
                  grid_step=a.grid_step)
    if a.json:
        return out(r, as_json=True)
    if not r.get("ok"):
        info = evidence.classify(r.get("error"))
        print("FAIL %s：%s" % (info["code"], info["hint"]))
        return 1
    print("%s %r  %dx%d px  scale=%s  窗口 @%d,%d %dx%d  → %s"
          % (r.get("app"), r.get("title"), r["img_w"], r["img_h"], r.get("scale_x"),
             r["win_x"], r["win_y"], r["win_w"], r["win_h"], r["path"]))
    if r.get("grid_path"):
        print("  带网格版本：%s" % r["grid_path"])
    print("  记住：图片可能被缩放显示。点击一律用 tap 的窗口内点数，不要照抄图上像素。")
    return 0


def cmd_state(a):
    tok = require_desk_ref(a.ref)
    r = desk.state(tok, verify="strict" if a.strict else "attach")
    if a.json:
        return out(r, as_json=True)
    if not r.get("ok"):
        info = evidence.classify(r.get("error"))
        print("FAIL %s（%s）%s" % (info["code"], info["kind"], info["hint"]))
        return 1
    print("%s %r%s%s" % (r.get("role"), r.get("name") or "",
                         "  =" + repr(r["value"]) if r.get("value") else "",
                         "  [disabled]" if r.get("enabled") is False else ""))
    if r.get("evidence"):
        print("  证据：" + json.dumps(r["evidence"], ensure_ascii=False))
    return 0


def cmd_attrs(a):
    r = desk.attrs(ref=require_desk_ref(a.ref) if a.ref else None, x=a.x, y=a.y)
    if a.json:
        return out(r, as_json=True)
    if not r.get("ok"):
        print("FAIL %s" % r.get("error"))
        return 1
    print("pid=%s  共 %d 个属性" % (r.get("pid"), r.get("attribute_count", 0)))
    for k in sorted(r.get("attributes") or {}):
        print("  %-28s %s" % (k, json.dumps(r["attributes"][k], ensure_ascii=False)))
    if r.get("actions"):
        print("  actions: %s" % ", ".join(r["actions"]))
    if r.get("unreadable"):
        print("  读不出来（unknown，不是「没有」）: %s" % ", ".join(r["unreadable"]))
    return 0


# ---------------------------------------------------------------- 批量

def _desk_req(step):
    do = step.get("do")
    req = {"cmd": None}
    if do == "activate":
        req = {"cmd": "activate", "app": step.get("app")}
    elif do == "sleep":
        req = {"cmd": "sleep", "ms": int(step.get("ms", 200))}
    elif do == "click" and step.get("point"):
        p = step["point"]
        req = {"cmd": "clickat", "app": p.get("app") or step.get("app"),
               "x": p["x"], "y": p["y"], "space": p.get("space", "point"),
               "count": p.get("count", 1), "raise": True}
    elif do == "click":
        req = {"cmd": "act", "action": "click",
               "verify": "strict" if step.get("strict") else "attach"}
        for k in ("ref", "app", "role", "name", "id", "window"):
            if step.get(k):
                req[k] = step[k]
        if step.get("contains"):
            req["contains"] = True
    elif do == "fill":
        req = {"cmd": "act", "action": "setvalue", "text": step.get("text", ""),
               "verify": "strict" if step.get("strict") else "attach"}
        for k in ("ref", "app", "role", "name", "id"):
            if step.get(k):
                req[k] = step[k]
    elif do == "key":
        req = {"cmd": "keys", "key": step.get("combo") or step.get("key")}
    elif do == "paste":
        req = {"cmd": "paste", "text": step.get("text", ""), "restore": True}
    elif do == "scroll":
        if step.get("point"):
            p = step["point"]
            req = {"cmd": "scrollat", "app": p.get("app") or step.get("app"),
                   "x": p["x"], "y": p["y"], "dy": int(step.get("dy", -6)),
                   "times": int(step.get("times", 1)), "space": p.get("space", "point")}
        else:
            req = {"cmd": "act", "action": "scroll", "ref": step.get("ref"),
                   "dy": int(step.get("dy", 5))}
    elif do == "hover":
        p = step.get("point") or {}
        req = {"cmd": "moveat", "app": p.get("app") or step.get("app"),
               "x": p["x"], "y": p["y"], "space": p.get("space", "point")}
    elif do == "shot":
        req = {"cmd": "shot", "app": step.get("app"), "out": step.get("out")}
        if step.get("grid"):
            req["grid"] = True
    elif do == "look":
        req = {"cmd": "snapshot", "app": step.get("app"), "max_nodes": step.get("max", 1500)}
    elif do == "state":
        req = {"cmd": "state", "ref": step.get("ref")}
    else:
        raise BadInput("批量里不认识的桌面步骤：%s" % do, "STEP_BAD")
    return req


def _web_step(step):
    do = step.get("do")
    if do == "goto":
        return {"op": "goto", "url": step.get("url")}
    if do in ("press", "eval", "wait", "scroll", "snapshot"):
        s = {"op": do}
        s.update({k: v for k, v in step.items() if k not in ("do", "text")})
        if do in ("eval", "wait"):
            # fastlane 的字段叫 expr；步骤文件里写 text 更顺手，这里转一手
            s["expr"] = step.get("expr") or step.get("text") or ""
        return s
    action = {"click": "click", "fill": "fill", "read": "read", "hover": "hover"}.get(do)
    if not action:
        raise BadInput("批量里不认识的网页步骤：%s" % do, "STEP_BAD")

    loc = dict(step.get("locator") or {})
    if step.get("ref"):
        _, tok = parse_ref(step["ref"])
        if not loc:
            loc = {"by": "ref", "value": int(tok)}
        else:
            loc["ref"] = int(tok)
            loc.setdefault("by", "auto")
    elif not loc:
        # 按身份定位：有 role 就用 role+name，否则直接按可访问名
        if step.get("role"):
            loc = {"by": "role", "value": step["role"], "name": step.get("name") or ""}
        elif step.get("css"):
            loc = {"by": "css", "value": step["css"]}
        elif step.get("text"):
            loc = {"by": "name", "value": step["text"]}
        else:
            raise BadInput("网页步骤要么给 ref，要么给 text/role/css")

    s = {"action": action, "locator": loc}
    if action == "fill":
        # 批量里 --text 既可能是定位文字，也可能是要写的内容，所以分开命名
        s["value"] = step.get("text-value", step.get("value", ""))
    return s


def cmd_run(a):
    path = Path(a.steps).expanduser()
    if not path.is_file():
        raise BadInput("步骤文件不存在：%s" % path, "STEP_BAD")
    try:
        steps = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise BadInput("步骤文件不是合法 JSON：%s" % exc, "STEP_BAD")
    # 两种写法都收：顶层数组，或 {"steps": [...]}。文档里只示范了一种，
    # 调用方偏偏爱写另一种——为此丢一次往返不值得，认下来就是了。
    if isinstance(steps, dict) and isinstance(steps.get("steps"), list):
        steps = steps["steps"]
    if not isinstance(steps, list):
        raise BadInput('步骤文件格式不对：要 JSON 数组，或 {"steps": [ ... ]}', "STEP_BAD")

    t0 = time.perf_counter()
    results = []
    desk_buf, desk_idx = [], []

    def flush_desk():
        nonlocal desk_buf, desk_idx
        if not desk_buf:
            return
        reqs = [_desk_req(s) for s in desk_buf]
        res = desk.pipeline(reqs)
        for i, r in zip(desk_idx, res):
            v = evidence.verdict(r)
            results[i]["result"] = r
            results[i]["verdict"] = v
            results[i]["ok"] = (v != "fail")
            if v == "fail":
                results[i]["error"] = r.get("error")
        desk_buf, desk_idx = [], []

    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            raise BadInput("第 %d 步不是对象：%r" % (i + 1, step), "STEP_BAD")
        # "action" 是很自然的写法，认下来。为一个键名丢一次往返不值得。
        if not step.get("do") and step.get("action"):
            step = dict(step, do=step["action"])
        entry = {"step": i + 1, "do": step.get("do"), "ok": True, "verdict": "ok"}
        results.append(entry)
        if step.get("web") or step.get("do") in ("goto", "press", "eval", "wait"):
            flush_desk()
            try:
                r = web.act_on(_web_step(step), recheck=False,
                               target=a.target, url_contains=a.url_contains)
                entry["result"] = r
                entry["verdict"] = "ok" if r.get("ok") else "fail"
                entry["ok"] = bool(r.get("ok"))
                if not entry["ok"]:
                    entry["error"] = r.get("error")
            except Exception as exc:
                entry["ok"] = False
                entry["error"] = "%s: %s" % (type(exc).__name__, str(exc)[:160])
        else:
            desk_buf.append(step)
            desk_idx.append(i)
            if step.get("flush"):
                flush_desk()
        if not entry["ok"] and not step.get("continue"):
            break
    flush_desk()

    ok = all(r.get("ok", True) for r in results) and len(results) == len(steps)
    unverified = sum(1 for r in results if r.get("verdict") == "unverified")
    report = {"ok": ok, "count": len(results), "total": len(steps),
              "unverified": unverified,
              "elapsed_ms": round((time.perf_counter() - t0) * 1000, 1),
              "results": results}
    if a.json:
        return out(report, as_json=True)
    print("%s  %d/%d 步  %.0f ms%s" % (
        "全部完成" if ok else "中断", len(results), len(steps), report["elapsed_ms"],
        "  其中 %d 步未确认" % unverified if unverified else ""))
    for r in results:
        res = r.get("result") or {}
        mark = {"ok": "ok  ", "unverified": "unv ", "fail": "FAIL"}.get(r.get("verdict"), "?   ")
        detail = evidence.describe(res) if res else (r.get("error") or "")
        print("  %s %-2d %-8s %s" % (mark, r["step"], r.get("do"), detail))
    return 0 if ok else 1


# ---------------------------------------------------------------- 入口

class _JsonAwareParser(argparse.ArgumentParser):
    """参数写错时，如果调用方要的是 JSON，就别给他 usage 散文。

    这条比它看起来重要：机器调用方按契约解析 stdout，一旦拿到 usage 文本，
    它的解析器会抛自己的异常，现场就变成一个跟本工具毫无关系的报错。
    --json 可能在错参数后面，所以查 sys.argv 而不是查 a.json。
    """

    def error(self, message):
        if "--json" in sys.argv[1:]:
            print(json.dumps({"ok": False, "error": "ARG_MISSING", "kind": "bad_input",
                              "retry": True,
                              "hint": "参数写法不对，看 --help",
                              "detail": message}, ensure_ascii=False))
            raise SystemExit(1)
        super().error(message)


def build():
    ap = _JsonAwareParser(prog="surehand", description="看得见、点了算得清的操作层")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    ap.add_argument("--version", action="version", version="surehand %s" % skill_version())
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("up", help="拉起桌面守护进程并检查两条通道")
    p.add_argument("--launch", action="store_true", help="浏览器没开调试端口就替你起一个")
    sub.add_parser("doctor", help="环境健康检查")

    p = sub.add_parser("apps", help="列出正在运行的应用")
    p.add_argument("--filter", default="")

    p = sub.add_parser("activate", help="把某个应用切到前台")
    p.add_argument("--app", required=True)

    p = sub.add_parser("look", help="观察界面，给出通道结论与 ref")
    p.add_argument("--app", default="")
    p.add_argument("--window", default="")
    p.add_argument("--web", action="store_true")
    p.add_argument("--max", type=int, default=1500)
    p.add_argument("--no-static", action="store_true")
    p.add_argument("--from", dest="from_ref", default="",
                   help="从某个 handle/ref 继续钻取")
    p.add_argument("--depth", type=int, default=0, help="只看前 N 层，用于摸结构")
    p.add_argument("--target", default="")
    p.add_argument("--url-contains", dest="url_contains", default="")

    p = sub.add_parser("find", help="只找不动")
    p.add_argument("--text", default="")
    # do 用的 --name 在这里也认：同一个概念不该按动词换名字，
    # 否则学到 do --name 的人写 find --name 只会拿到一屏 usage。
    p.add_argument("--name", default="")
    p.add_argument("--role", default="")
    p.add_argument("--id", dest="ident", default="")
    p.add_argument("--app", default="")
    p.add_argument("--window", default="")
    p.add_argument("--contains", action="store_true")
    p.add_argument("--web", action="store_true")
    p.add_argument("--max", type=int, default=1500)
    p.add_argument("--target", default="")
    p.add_argument("--url-contains", dest="url_contains", default="")

    p = sub.add_parser("do", help="做一件事")
    p.add_argument("verb", choices=["click", "fill", "type", "read", "key", "paste",
                                    "scroll", "hover", "goto", "press", "eval", "wait",
                                    "activate"])
    p.add_argument("--ref", default="")
    p.add_argument("--app", default="")
    p.add_argument("--window", default="")
    p.add_argument("--role", default="")
    p.add_argument("--name", default="")
    p.add_argument("--id", dest="ident", default="")
    p.add_argument("--contains", action="store_true")
    p.add_argument("--text", default=None)
    p.add_argument("--text-value", dest="text_value", default=None)
    p.add_argument("--combo", default="")
    p.add_argument("--dy", type=int, default=None)
    p.add_argument("--prefer", default="auto")
    p.add_argument("--strict", action="store_true", help="整窗重数身份后再动手")
    p.add_argument("--web", action="store_true")
    p.add_argument("--fast", action="store_true", help="跳过网页 ref 身份复核（刚 look 过才用）")
    p.add_argument("--url", default="")
    p.add_argument("--css", default="")
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--target", default="")
    p.add_argument("--url-contains", dest="url_contains", default="")

    p = sub.add_parser("tap", help="窗口内相对坐标点击（视觉通道的动作）")
    p.add_argument("--app", required=True)
    p.add_argument("--x", type=float, required=True)
    p.add_argument("--y", type=float, required=True)
    p.add_argument("--space", choices=["point", "image"], default="point")
    p.add_argument("--count", type=int, default=1)

    p = sub.add_parser("scroll", help="坐标滚动（自绘列表）")
    p.add_argument("--app", required=True)
    p.add_argument("--x", type=float, required=True)
    p.add_argument("--y", type=float, required=True)
    p.add_argument("--dy", type=int, default=-6)
    p.add_argument("--times", type=int, default=1)
    p.add_argument("--space", choices=["point", "image"], default="point")

    p = sub.add_parser("hover", help="悬停")
    p.add_argument("--app", required=True)
    p.add_argument("--x", type=float, required=True)
    p.add_argument("--y", type=float, required=True)
    p.add_argument("--space", choices=["point", "image"], default="point")

    p = sub.add_parser("shot", help="截图（视觉通道的眼睛）")
    p.add_argument("--app", default="")
    p.add_argument("--window", default="")
    p.add_argument("--out", default="")
    p.add_argument("--grid", action="store_true")
    p.add_argument("--grid-step", type=int, default=100)

    p = sub.add_parser("state", help="读某个 ref 的当前状态")
    p.add_argument("--ref", required=True)
    p.add_argument("--strict", action="store_true")

    p = sub.add_parser("attrs", help="转储元素的全部 AX 属性（诊断用）")
    p.add_argument("--ref", default="")
    p.add_argument("--x", type=float, default=None)
    p.add_argument("--y", type=float, default=None)

    p = sub.add_parser("launch", help="起一个带调试端口的浏览器（独立 profile）")
    p.add_argument("--port", type=int, default=9222)
    p.add_argument("--profile", default="")
    p.add_argument("--url", default="about:blank")

    p = sub.add_parser("run", help="跑一份步骤文件")
    p.add_argument("steps")
    p.add_argument("--target", default="")
    p.add_argument("--url-contains", dest="url_contains", default="")

    # --json 放子命令后面也要认；SUPPRESS 保证它不会覆盖已有的默认值
    for sp in sub._name_parser_map.values():
        sp.add_argument("--json", action="store_true", default=argparse.SUPPRESS)

    return ap


def main(argv=None):
    a = build().parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    table = {"up": cmd_up, "doctor": cmd_doctor, "apps": cmd_apps, "look": cmd_look,
             "find": cmd_find, "do": cmd_do, "tap": cmd_tap, "scroll": cmd_scroll,
             "hover": cmd_hover, "shot": cmd_shot, "state": cmd_state,
             "attrs": cmd_attrs, "run": cmd_run, "activate": cmd_activate,
             "launch": cmd_launch}
    try:
        return table[a.cmd](a)
    except BadInput as exc:
        # RefFormatError 是它的子类，一起在这里收口：带码、带 kind、带该怎么做。
        info = evidence.classify(exc.code)
        if a.json:
            print(json.dumps({"ok": False, "error": exc.code, "kind": info["kind"],
                              "retry": info["retry"], "hint": info["hint"],
                              "detail": str(exc)}, ensure_ascii=False))
        else:
            print("FAIL %s（%s）%s" % (exc.code, info["kind"], str(exc)))
        return 1
    except SystemExit:
        raise
    except Exception as exc:
        # 到这里说明是本工具自己的缺陷，不是用户写错了什么。仍然要给码：
        # "FAIL ValueError: ..." 对调用方等于零信息——他不知道这是能重试的环境问题、
        # 是自己写错的参数，还是该来报 bug。INTERNAL 明确说是 bug，别重放。
        info = evidence.classify("INTERNAL")
        detail = "%s: %s" % (type(exc).__name__, str(exc)[:300])
        if a.json:
            print(json.dumps({"ok": False, "error": "INTERNAL", "kind": info["kind"],
                              "retry": info["retry"], "hint": info["hint"],
                              "detail": detail}, ensure_ascii=False))
        else:
            print("FAIL INTERNAL（%s）%s" % (info["kind"], info["hint"]))
            print("  %s" % detail)
        return 1


if __name__ == "__main__":
    sys.exit(main())
