#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""selftest.py —— Surehand 自测。

分三层：
  A. 纯判断层（不需要任何权限、任何外部进程）
  B. 桌面通道（需要辅助功能权限；自动用计算器当靶子）
  C. 网页通道（需要 CDP；没开就跳过，不算失败）

输出一份 JSON 报告，每项含 ok / ms / detail。设计原则：能用确定性断言的地方
一定要断言，不能断言的地方（比如「点了对不对」）就用可观测的字段去证伪。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import transport as desk   # noqa: E402
import evidence           # noqa: E402

RESULTS = []


def check(name, fn, group="A"):
    t0 = time.perf_counter()
    try:
        detail = fn()
        ok = detail.get("ok", True) if isinstance(detail, dict) else bool(detail)
    except AssertionError as exc:
        ok, detail = False, {"assert": str(exc)}
    except Exception as exc:
        ok, detail = False, {"error": "%s: %s" % (type(exc).__name__, str(exc)[:200])}
    RESULTS.append({"group": group, "name": name, "ok": bool(ok),
                    "ms": round((time.perf_counter() - t0) * 1000, 1),
                    "detail": detail if isinstance(detail, dict) else {"value": detail}})


# ---------------------------------------------------------------- A 判断层

def a_trinary():
    # 有一个 unknown，合并结果必须是 unknown，不能塌缩成 False
    assert evidence.merge_evidence("known", "unknown") == "unknown"
    assert evidence.merge_evidence("absent", "absent") == "absent"
    assert evidence.merge_evidence("absent", "known") == "known"
    # 谓词取反必须拒绝 unknown
    gate = evidence.predicate_gate({"evidence": {"enabled": "unknown"}}, "enabled")
    assert gate["value"] is None, "unknown 被当成了确定值"
    gate2 = evidence.predicate_gate({"enabled": False}, "enabled")
    assert gate2["value"] is False and gate2["evidence"] == "known"
    gate3 = evidence.predicate_gate({"evidence": {"enabled": "absent"}}, "enabled")
    assert gate3["value"] is None
    return {"merged": "unknown 保持 unknown", "gate": "unknown → None"}


def a_tokens():
    assert evidence.token_state({"ref": "e1"}) == "token"
    assert evidence.token_state({"handle": "e1"}) == "handle"
    assert evidence.token_state({}) == "none"
    assert evidence.actionable({"ref": "e1"}) is True
    assert evidence.actionable({"ref": "e1", "ambiguous": 3}) is False, "歧义节点被当成可动手"
    assert evidence.actionable({"handle": "e1"}) is False, "句柄被当成令牌"
    return {"rule": "只有 ref 且无歧义才可动手"}


def a_verdict():
    assert evidence.verdict({"ok": True, "delivery": {"state": "delivered"}}) == "ok"
    assert evidence.verdict({"ok": False, "delivery": {"state": "uncertain"}}) == "unverified"
    assert evidence.verdict({"ok": False, "delivery": {"state": "not_delivered"}}) == "fail"
    assert evidence.verdict({"ok": True}) == "ok"
    # uncertain 不能被描述成失败
    txt = evidence.describe({"ok": False, "delivery": {"state": "uncertain", "retry": "unsafe",
                                                       "witness": "event_posted"}})
    assert "未确认" in txt and "失败" not in txt, "uncertain 被描述成失败：%s" % txt
    return {"rule": "uncertain ≠ fail"}


def a_errors():
    c = evidence.classify("AMBIGUOUS:3")
    assert c["code"] == "AMBIGUOUS" and c["kind"] == "ambiguous" and c["detail"] == "3"
    o = evidence.classify("OCCLUDED")
    assert o["retry"] is False, "遮挡类错误被允许重试"
    h = evidence.classify("HANDLE_NOT_TOKEN")
    assert h["kind"] == "stale"
    return {"rule": "遮挡不授权重放"}


def a_summarize():
    wx = {"ok": True, "visited": 6, "complete": True,
          "nodes": [{"role": "AXWindow"}, {"role": "AXButton"}, {"role": "AXButton"},
                    {"role": "AXButton"}]}
    assert evidence.summarize(wx)["surface"] == "visual", "自绘界面被判成有结构"
    calc = {"ok": True, "visited": 35, "complete": True,
            "nodes": [{"role": "AXWindow", "name": "计算器"},
                      {"role": "AXButton", "id": "Seven"},
                      {"role": "AXStaticText", "value": "9"}]}
    assert evidence.summarize(calc)["surface"] == "structure", "有标识的界面被判成自绘"
    part = {"ok": True, "visited": 18, "complete": False,
            "incomplete_because": ["depth_cap:3"],
            "nodes": [{"role": "AXButton", "name": "x"}]}
    assert evidence.summarize(part)["surface"] == "partial"
    return {"cases": "visual / structure / partial"}


def a_choose():
    nodes = [{"ref": "e1", "role": "AXButton", "name": "提交"},
             {"ref": "e2", "role": "AXButton", "name": "取消"}]
    hits, why = evidence.choose(nodes, name="提交")
    assert len(hits) == 1 and hits[0]["ref"] == "e1"
    hits2, why2 = evidence.choose(nodes, role="AXButton")
    assert len(hits2) == 2 and "必须收窄" in why2, "多命中没有要求收窄"
    hits3, _ = evidence.choose(nodes, name="不存在的")
    assert hits3 == []
    return {"rule": "不做「取第一个」"}


# ---------------------------------------------------------------- B 桌面通道

def _engine_argv():
    """独立再起一个引擎的命令行。用来验证单实例：拿不到锁的必须自己退出。"""
    if desk.PLATFORM == "windows":
        return [desk._powershell(), "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File", str(desk.WCCD)]
    return [str(desk.BIN)]


def b_lease():
    argv = _engine_argv()
    if not Path(argv[-1]).is_file():
        raise AssertionError("缺少引擎 %s" % argv[-1])
    desk.start()
    before = alive_engines()
    procs = []
    for _ in range(5):
        kw = {}
        if desk.PLATFORM == "windows":
            kw["creationflags"] = 0x00000008
        else:
            kw["start_new_session"] = True
        procs.append(subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, **kw))
    deadline = time.time() + 20
    while time.time() < deadline:
        if sum(1 for p in procs if p.poll() is None) <= 1:
            break
        time.sleep(0.1)
    # 判据不是「进程数」而是「还活着的引擎数」：拿不到锁的必须自己退，
    # 靠 pgrep 数进程在不同平台上口径不一致（Windows 上宿主进程还叫 powershell）。
    alive = sum(1 for p in procs if p.poll() is None)
    assert alive <= 1, "并发启动后还有 %d 个进程在跑（应当只留 1 个）" % alive
    assert desk.alive(), "并发启动后主引擎反而不在了"
    return {"concurrent_survivors": alive, "before": before}


def alive_engines():
    return 1 if desk.alive() else 0


def b_health():
    h = desk.health()
    assert h["daemon"], "守护进程没起来"
    assert h["ax_trusted"], "缺少辅助功能权限"
    return {"version": h["version"], "frontmost": h["frontmost"],
            "screen_trusted": h["screen_trusted"]}


def b_snapshot_proof():
    app = _pick_app()
    snap = desk.snapshot(app=app_name(app))
    assert snap.get("ok"), snap.get("error")
    assert snap["complete"], "整窗遍历没走完：%s" % snap.get("incomplete_because")
    # 不唯一/未证明的节点必须没有 ref
    bad = [n for n in snap["nodes"] if n.get("ambiguous") and n.get("ref")]
    assert not bad, "有歧义节点拿到了 ref：%s" % bad[:2]
    # 发证的口径必须对得上
    issued = len([n for n in snap["nodes"] if n.get("ref")])
    assert issued == snap["refs_issued"], "refs_issued 与实际不符 %s vs %s" % (issued, snap["refs_issued"])
    # 每个 ref 节点都得有 witness 且为 1
    for n in snap["nodes"]:
        if n.get("ref"):
            assert n.get("witness") == 1, "ref 节点的 witness 不是 1：%s" % n
    return {"app": snap["app"], "visited": snap["visited"], "refs": issued,
            "withheld": snap["refs_withheld"], "ms": snap["elapsed_ms"]}


def b_handle_not_token():
    app = _pick_app()
    snap = desk.snapshot(app=app_name(app), max_depth=2)
    if snap.get("complete"):
        return {"skipped": "这个应用两层就够了，造不出未证明的节点"}
    handles = [n["handle"] for n in snap["nodes"] if n.get("handle")]
    assert handles, "未证明的快照里应该有 handle"
    r = desk.act("click", ref=handles[0])
    assert not r.get("ok") and str(r.get("error")) == "HANDLE_NOT_TOKEN", \
        "句柄被允许动手：%s" % r.get("error")
    return {"handle": handles[0], "error": r.get("error")}


def b_act_receipt():
    app = _pick_app()
    snap = desk.snapshot(app=app_name(app))
    target = None
    for n in snap["nodes"]:
        if n.get("ref") and n.get("role") == "AXButton":
            target = n
            break
    assert target, "没有可点的按钮"
    r = desk.act("click", ref=target["ref"], prefer="ax", verify="strict")
    d = evidence.delivery(r)
    assert d["state"] == "delivered", "AXPress 没有给送达回执：%s" % d
    assert d["retry"] == "unsafe"
    assert r.get("method") in ("axpress", "axpress_fallback")
    return {"ref": target["ref"], "delivery": d, "ms": r.get("elapsed_ms")}


def b_cross_process_ref():
    """ref 必须能跨进程用 —— 这是「快照一次、多处使用」的前提。"""
    app = _pick_app()
    snap = desk.snapshot(app=app_name(app))
    ref = next((n["ref"] for n in snap["nodes"] if n.get("ref") and n.get("role") == "AXButton"), None)
    assert ref, "没有可用 ref"
    code = (
        "import sys, json\n"
        "sys.path.insert(0, {here!r})\n"
        "import transport as desk\n"
        "r = desk.state({ref!r}, verify='attach')\n"
        "print(json.dumps({{'ok': r.get('ok'), 'role': r.get('role'),"
        " 'error': r.get('error')}}, ensure_ascii=False))\n"
    ).format(here=str(HERE), ref=ref)
    p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr or "")[-300:]
    r = json.loads(p.stdout.strip().splitlines()[-1])
    assert r["ok"], "另一个进程读不到这个 ref：%s" % r
    return {"ref": ref, "role": r["role"], "process": "子进程"}


def b_restricted_token():
    """身份读不全但有机器标识时，发受限令牌：只许填值，不许点击。

    这是「用点击的严格性去卡输入框」那个错误的修法。输入框的写操作走 AXSetValue，
    不经坐标、不看可见性，跟点击的风险模型不是一回事。
    """
    snap = desk.snapshot(app="文本编辑")
    if not snap.get("ok"):
        return {"skipped": "文本编辑没在跑"}
    restr = [n for n in snap["nodes"] if n.get("restricted")]
    if not restr:
        return {"skipped": "当前界面没有受限令牌节点"}
    node = restr[0]
    assert node.get("ref"), "受限令牌必须给 ref，不能只给 handle"
    allowed = set(node.get("allowed") or [])
    assert {"fill", "read"} <= allowed, "放行集合不对：%s" % allowed

    r = desk.act("click", ref=node["ref"])
    assert not r.get("ok") and str(r.get("error")) == "TOKEN_RESTRICTED", \
        "受限令牌被允许点击：%s" % r.get("error")
    assert r.get("delivery", {}).get("state") == "not_delivered", \
        "被拒的动作必须报 not_delivered，不能报 uncertain"

    # 填值必须放行；写完立刻复原，不碰用户内容
    old = (desk.act("read", ref=node["ref"]) or {}).get("value") or ""
    f = desk.act("setvalue", ref=node["ref"], text="SELFTEST-RESTRICTED")
    assert f.get("ok"), "受限令牌不被允许填值：%s" % f.get("error")
    back = desk.act("setvalue", ref=node["ref"], text=old)
    assert back.get("ok"), "复原失败，请手工检查文档内容"
    return {"ref": node["ref"], "click": "TOKEN_RESTRICTED", "fill": "delivered"}


def b_subtree_scope():
    """钻取发出的 ref 必须带上「唯一性只在子树内证过」的烙印。"""
    # 不靠运气：挨个应用、挨个容器试，直到找到一个「钻进去确实有稳定叶子」的场景。
    # 有些容器（空列表、Chrome 的标签栏）钻进去什么都没有，那不是缺陷，只是不合适当靶子。
    listing = desk.apps() or {}
    tried = 0
    for app in (listing.get("apps") or [])[:12]:
        name = app.get("name")
        if not name:
            continue
        s = desk.snapshot(app=name)
        if not s.get("ok"):
            continue
        roots = [n for n in s.get("nodes") or []
                 if n.get("ref") and n.get("role") in ("AXList", "AXOutline", "AXTable",
                                                       "AXScrollArea", "AXBrowser")]
        for root in roots[:3]:
            tried += 1
            d = desk.snapshot(app=name, from_ref=root["ref"], max_depth=3)
            if not d.get("ok"):
                continue  # 这个容器不给钻（比如刚失效），换一个
            assert str(d.get("scope", "")).startswith("subtree:"), \
                "钻取没收窄证明范围：%s" % d.get("scope")
            inner = [n for n in d.get("nodes") or []
                     if n.get("ref") and n.get("role") in ("AXButton", "AXCell", "AXStaticText",
                                                           "AXTextField", "AXImage", "AXRow")]
            r = None
            for cand in inner[:5]:
                got = desk.act("read", ref=cand["ref"], verify="attach")
                if got.get("ok"):
                    r = got
                    break
            if r is None:
                continue  # 这个容器钻进去没有能过复核的叶子，换下一个
            assert str(r.get("proven_in", "")).startswith("subtree:"), \
                "ref 没带上证明范围：%s" % r.get("proven_in")
            return {"app": name, "root": root["ref"], "scope": d.get("scope"),
                    "proven_in": r.get("proven_in")}
    return {"skipped": "试了 %d 个容器，都没有可用的叶子节点" % tried}


def b_visual_detect():
    """微信这类自绘界面必须被判成 visual，否则上层会一直试语义定位。"""
    apps = [a["name"] for a in (desk.apps().get("apps") or [])]
    target = next((n for n in apps if "微信" in n or "WeChat" in n), None)
    if not target:
        return {"skipped": "微信没在跑"}
    snap = desk.snapshot(app=target)
    s = evidence.summarize(snap)
    assert s["surface"] == "visual", "微信被判成 %s" % s["surface"]
    return {"app": target, "visited": s["visited"], "surface": s["surface"]}


def _pick_app():
    apps = [a for a in (desk.apps().get("apps") or []) if a.get("windows", 0) > 0]
    for want in ("Calculator", "计算器"):
        for a in apps:
            if want in (a.get("name") or ""):
                return a
    if not apps:
        raise AssertionError("没有带窗口的应用可测")
    return apps[0]


def app_name(a):
    return a.get("name") if isinstance(a, dict) else str(a)


# ---------------------------------------------------------------- C 网页通道

def c_health():
    import web
    h = web.health()
    if not h.get("cdp_alive"):
        return {"skipped": "CDP 未开启（不扣分）", "ok": True}
    # 只看 /json/version 是不够的：浏览器半死（GPU 或 network 服务崩了）时端口还在响应，
    # 但一个能操作的页面都没有。判据必须是「有页面」，否则这项会给出假阳性，
    # 让下一条测试去背锅。
    pages = h.get("pages") or 0
    assert pages > 0, ("CDP 端口活着但没有任何可操作页面；浏览器多半正在崩溃。"
                       "在受限环境里 Chrome 子进程 sandbox 常被拒（sandbox initialization failed），"
                       "此时只能换一台机器或换一个浏览器验收网页通道。")
    return {"browser": h.get("browser"), "pages": pages}


def c_snapshot():
    import web
    h = web.health()
    if not h.get("cdp_alive"):
        return {"skipped": "CDP 未开启"}
    # 不依赖「当前页正好有元素」：自己开一个最小页面。about:blank 上没元素，
    # 拿它当靶子会让这项测试变成运气游戏。
    page = ("data:text/html,<html><body>"
            "<input aria-label='姓名'><button id='b' onclick=\"this.textContent='done'\">提交</button>"
            "</body></html>")
    web.act_on({"op": "goto", "url": page})
    snap = web.snapshot()
    nodes = web.normalize(snap.get("nodes"))
    assert nodes, "网页上没读到可交互元素"
    assert all(n["ref"].startswith("w:") for n in nodes)
    return {"count": len(nodes), "sample": nodes[0]["ref"]}


def main():
    check("A1 三态不塌缩", a_trinary)
    check("A2 令牌与句柄分离", a_tokens)
    check("A3 三种结局", a_verdict)
    check("A4 错误分类", a_errors)
    check("A5 通道判定", a_summarize)
    check("A6 定位不取第一个", a_choose)

    check("B1 单实例租约", b_lease, "B")
    check("B2 权限与环境", b_health, "B")
    check("B3 快照发证口径", b_snapshot_proof, "B")
    check("B4 句柄不能动手", b_handle_not_token, "B")
    check("B5 动作回执", b_act_receipt, "B")
    check("B6 ref 跨进程", b_cross_process_ref, "B")
    check("B7 自绘界面判定", b_visual_detect, "B")
    check("B8 受限令牌", b_restricted_token, "B")
    check("B9 子树证明范围", b_subtree_scope, "B")

    check("C1 CDP 可用", c_health, "C")
    check("C2 网页快照", c_snapshot, "C")

    passed = sum(1 for r in RESULTS if r["ok"])
    skipped = sum(1 for r in RESULTS if (r["detail"] or {}).get("skipped"))
    report = {"ok": passed == len(RESULTS), "passed": passed, "total": len(RESULTS),
              "skipped": skipped,
              "elapsed_ms": round(sum(r["ms"] for r in RESULTS), 1),
              "results": RESULTS}
    out = Path.cwd() / "surehand-selftest.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    for r in RESULTS:
        mark = "ok  " if r["ok"] else "FAIL"
        note = ""
        if (r["detail"] or {}).get("skipped"):
            note = "  （跳过：%s）" % r["detail"]["skipped"]
        elif not r["ok"]:
            note = "  " + json.dumps(r["detail"], ensure_ascii=False)[:160]
        print("%s %-22s %6.1f ms%s" % (mark, r["name"], r["ms"], note))
    print("\n%d/%d 通过，%d 项跳过  → %s" % (passed, len(RESULTS), skipped, out))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
