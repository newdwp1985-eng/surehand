#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web.py —— 浏览器通道适配层。

底层是 browser-fastlane 的四层降级（页面内 fetch → 语义定位 → CDP 原生输入 → 视觉兜底）。
这一层只做三件底层不该管的事：

1. **跨进程的 ref 生命周期**。fastlane 的 ref 存在页面 DOM 的 data-fastlane-ref 上，
   天然跨进程；但它用来判断「ref 是否还有效」的 snapshot_url 是进程内的。
   所以新进程要么重新快照一次（我们默认这么做），要么拿到旧 ref 就得自带身份复核。
2. **身份复核后再用 ref**。ref 号是位置编号，页面一变就可能指到别的元素。
   我们记录每个 ref 的身份（文字/角色），用之前先比一遍，不一致就退回按身份找。
3. **把 fastlane 的结果翻成统一形状**，让上层不必区分桌面元素和网页元素。

调用方式是子进程。把一个浏览器会话拆成很多次调用看起来费，但每次多花的约 100 ms
换的是「不会因为残留状态点错」，这个交易值得。需要连续多步时走 batch，仍是一个进程。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
CLI = SKILL / "vendor" / "browser" / "fastlane.py"
CDP_LIB = SKILL / "vendor" / "browser" / "cdp.py"

# 启一个带调试端口的浏览器。为什么要独立 profile：Chrome/Edge 在已有实例运行时，
# 会把新命令行的参数直接忽略并交给旧实例处理——--remote-debugging-port 因此不生效。
# 想让新参数生效只能换一个 user-data-dir，代价是这个 profile 里没有你原来的登录态。
_BROWSERS = {
    "darwin": [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ],
    "win32": [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Chromium\Application\chrome.exe",
    ],
}

# macOS 上必须用 open -n 交给 launchd 起，直接 Popen 出来的 Chrome 会随调用方
# 一起被回收（实测：端口刚起来 2 秒就断）。这是 GUI 应用的会话归属问题，不是参数问题。
_MAC_APP_NAMES = {
    "/Applications/Google Chrome.app": "Google Chrome",
    "/Applications/Microsoft Edge.app": "Microsoft Edge",
    "/Applications/Chromium.app": "Chromium",
}


def browser_binary():
    for p in _BROWSERS.get(sys.platform, []):
        if Path(p).is_file():
            return p
    return ""


def launch(port=9222, profile=None, url="about:blank"):
    """起一个带调试端口的浏览器。返回结论；已经在跑就不重复起。"""
    h = health(port=port)
    if h.get("cdp_alive"):
        return {"ok": True, "already": True, "port": port, **h}
    exe = browser_binary()
    if not exe:
        return {"ok": False, "error": "NO_BROWSER",
                "hint": "没找到 Chrome / Edge / Chromium。装了 Edge 的 Windows 也在候选里。"}
    prof = Path(profile or (Path.home() / ".surehand" / "chrome-profile")).expanduser()
    prof.mkdir(parents=True, exist_ok=True)
    args = ["--remote-debugging-port=%d" % int(port),
            "--user-data-dir=%s" % prof,
            "--no-first-run", "--no-default-browser-check",
            "--disable-features=Translate", url]
    # 逃生口：某些容器/沙箱里 Chrome 的子进程 sandbox 会被内核拒绝
    # （报 sandbox initialization failed），此时需要自行加参数。默认绝不加 --no-sandbox。
    extra = os.environ.get("SUREHAND_CHROME_FLAGS", "").strip()
    if extra:
        args = extra.split() + args

    # 启动方式：直接 Popen 优先，open -na 兜底。
    # 反过来试过：macOS 上 `open -na ... --args` 在本机返回 0 却不起进程
    # （LaunchServices 把参数吞了），于是轮询 25 秒后报超时，看起来像端口被拦。
    # Popen + start_new_session 实测能活，且 stderr 抓得到，失败时能说清原因。
    log_path = Path(tempfile.mkstemp(prefix="surehand-chrome-", suffix=".log")[1])
    log_fh = open(log_path, "wb")
    proc = None
    try:
        kw = {"stdout": log_fh, "stderr": log_fh, "close_fds": True}
        if sys.platform == "win32":
            # DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB：不只要脱离控制台，
            # 还要脱离宿主所在的 Job 对象，否则宿主一退出整棵子进程树跟着被收掉。
            kw["creationflags"] = 0x00000008 | 0x01000000
        else:
            kw["start_new_session"] = True
        proc = subprocess.Popen([exe] + args, **kw)
    except Exception as exc:
        launched_error = str(exc)[:200]
    else:
        launched_error = ""
    finally:
        log_fh.close()

    def diagnose():
        try:
            tail = log_path.read_text(encoding="utf-8", errors="replace")[-2500:]
        except Exception:
            tail = ""
        low = tail.lower()
        if "sandbox initialization failed" in low or "operation not permitted" in low:
            return ("Chrome 的子进程沙箱被内核拒绝，浏览器起来就退出。"
                    "这是运行环境（容器 / 受限会话）的限制，不是命令写错。"
                    "确认你信任当前环境后，可用 SUREHAND_CHROME_FLAGS=\"--no-sandbox\" 重试。")
        if "address already in use" in low or "bind() failed" in low:
            return "调试端口已被别的进程占用，换一个 --port。"
        if "cannot create default profile" in low or "profile" in low and "lock" in low:
            return "profile 目录被占用：先关掉用同一 profile 的浏览器，或换一个 --profile 路径。"
        if "singletonlock" in low:
            return "profile 里有上次残留的单实例锁；删掉该 profile 下的 Singleton* 再试。"
        return ""

    deadline = time.time() + 25
    while time.time() < deadline:
        h = health(port=port)
        if h.get("cdp_alive"):
            try:
                log_path.unlink()
            except OSError:
                pass
            return {"ok": True, "already": False, "port": port, "profile": str(prof),
                    "binary": exe, **h}
        # 主进程已经退出就不会再好了，不必把 25 秒等满。
        if proc is not None and proc.poll() is not None:
            break
        time.sleep(0.3)

    if launched_error:
        return {"ok": False, "error": "LAUNCH_FAILED", "hint": launched_error,
                "profile": str(prof), "binary": exe, "log": str(log_path)}
    why = diagnose()
    if why:
        return {"ok": False, "error": "SANDBOX_BLOCKED" if "沙箱" in why else "LAUNCH_FAILED",
                "hint": why, "profile": str(prof), "binary": exe,
                "log": str(log_path), "log_tail": _tail(log_path)}
    return {"ok": False, "error": "CDP_TIMEOUT",
            "hint": ("浏览器进程还在，但调试端口一直没就绪。可能被安全软件拦了 "
                     "--remote-debugging-port，或这个 Chrome 版本忽略该参数（用独立 profile 再试）。"),
            "profile": str(prof), "binary": exe, "log": str(log_path),
            "log_tail": _tail(log_path)}


def _tail(path, n=1200):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")[-n:]
    except Exception:
        return ""



class WebError(Exception):
    pass


def available():
    return CLI.is_file()


def _run(args, timeout=90.0):
    """跑一次 fastlane，取它输出的那一行 JSON。诊断信息在 stderr，不干扰解析。"""
    if not CLI.is_file():
        raise WebError("找不到 %s" % CLI)
    env = dict(os.environ)
    # 本机代理会把 127.0.0.1:9222 也转出去，浏览器没监听时回 502，
    # 与「浏览器没开」无法区分。强制直连。
    np = env.get("no_proxy", "")
    for h in ("127.0.0.1", "localhost", "::1"):
        if h not in np:
            np = (np + "," if np else "") + h
    env["no_proxy"] = np
    env["NO_PROXY"] = np

    proc = subprocess.run([sys.executable, str(CLI)] + args,
                          capture_output=True, text=True, timeout=timeout, env=env)
    line = ""
    for ln in reversed((proc.stdout or "").strip().splitlines()):
        ln = ln.strip()
        if ln.startswith("{"):
            line = ln
            break
    if not line:
        tail = (proc.stderr or "").strip().splitlines()[-3:]
        raise WebError("fastlane 没有输出 JSON：%s" % (" / ".join(tail) or "无输出"))
    try:
        return json.loads(line)
    except json.JSONDecodeError as exc:
        raise WebError("fastlane 输出不是 JSON：%s" % exc)


def health(host="127.0.0.1", port=9222):
    args = ["--host", host, "--port", str(port), "doctor"]
    try:
        r = _run(args, timeout=20)
    except Exception as exc:
        return {"cdp_alive": False, "error": str(exc)[:200], "port": port}
    return {"cdp_alive": bool(r.get("ok") and r.get("cdp_alive")),
            "browser": r.get("browser"), "pages": r.get("pages"),
            "port": port, "error": r.get("error")}


def snapshot(host="127.0.0.1", port=9222, target=None, url_contains=None):
    args = ["--host", host, "--port", str(port)]
    if target:
        args += ["--target", target]
    if url_contains:
        args += ["--url-contains", url_contains]
    r = _run(args + ["snapshot"], timeout=60)
    if not r.get("ok"):
        raise WebError(r.get("error") or "snapshot 失败")
    return r


def batch(steps, host="127.0.0.1", port=9222, target=None, url_contains=None, start="L1"):
    args = ["--host", host, "--port", str(port)]
    if target:
        args += ["--target", target]
    if url_contains:
        args += ["--url-contains", url_contains]
    fd, path = tempfile.mkstemp(suffix=".json", prefix="cu-steps-")
    os.close(fd)
    try:
        Path(path).write_text(json.dumps(steps, ensure_ascii=False), encoding="utf-8")
        r = _run(args + ["batch", "--plans", path, "--start", start], timeout=180)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return r


# ---------------------------------------------------------------- 形状归一

def normalize(nodes):
    """把 fastlane 的节点翻成与桌面一致的字段名：name / value / role / ref。"""
    out = []
    for n in nodes or []:
        role = (n.get("role") or n.get("tag") or "").lower()
        # fastlane 已经把 ARIA 可访问名算好了（aria-label → placeholder → label → 文本），
        # 这里直接用，别在下面重新拼一遍，否则会把 aria-label 丢掉。
        name = (n.get("name") or n.get("label") or n.get("text")
                or n.get("placeholder") or n.get("href") or "")
        item = {
            "ref": "w:%s" % n.get("ref"),
            "role": role,
            "name": (name or "").strip()[:120],
            "tag": n.get("tag"),
            # 可读但不可操作（pre / 结果区 / 标题）。不标这个，调用方会把
            # 一个 div 当按钮去点，然后拿到 NO_ACTION_PATH 却不知道为什么。
            "actionable": bool(n.get("actionable", True)),
            "witness": 1,          # CDP 侧按选择器唯一命中即等唯一
            "evidence": {},
        }
        if n.get("value"):
            item["value"] = str(n["value"])[:300]
        if n.get("text"):
            item["text"] = str(n["text"])[:300]
        if n.get("href"):
            item["href"] = n["href"]
        attrs = n.get("attrs") or {}
        if attrs.get("disabled") in (True, "true"):
            item["enabled"] = False
        out.append(item)
    return out


def identity_of(node):
    """用于跨进程复核的最小身份：角色 + 可见文字。"""
    return {"role": node.get("role") or "", "name": node.get("name") or ""}


def locator_for(node, ref_int=None):
    """优先按 ref，ref 不可信时靠身份链兜底。

    身份链的顺序按可靠性排：可访问名（name）→ 角色+名 → 可见文字。
    text 只匹配 textContent，对输入框这类没有文字的控件是无效的，
    所以不能拿它当第一顺位。
    """
    loc = {"by": "auto"}
    if ref_int is not None:
        loc["ref"] = int(ref_int)
    if node.get("name"):
        loc["text"] = node["name"]      # auto 链里的 by=text 兜底
    if node.get("role"):
        loc["role"] = node["role"]
        loc["name"] = node.get("name") or ""
    if not loc.get("ref") and not loc.get("text") and not loc.get("role"):
        loc["css"] = "body"
    return loc


def identity_locator(node):
    """不带 ref 的纯身份定位，给跨进程复用时用。"""
    if node.get("name"):
        return {"by": "name", "value": node["name"]}
    if node.get("role"):
        return {"by": "role", "value": node["role"]}
    return {"by": "css", "value": "body"}


def act_on(step, host="127.0.0.1", port=9222, target=None, url_contains=None,
           recheck=True):
    """在网页上做一个动作。

    recheck=True 时先单独快照一次核对身份，再带着快照做动作 —— 两个进程，
    换来的是「ref 号没指错元素」这个保证。调用方刚刚 look 过的话可以关掉。
    """
    kw = dict(host=host, port=port, target=target, url_contains=url_contains)
    verdict = {"rechecked": False}
    loc = step.get("locator") or {}
    want = step.pop("_expect", None)
    use_ref = (loc.get("by") == "ref" and loc.get("value") is not None)
    if recheck and use_ref:
        try:
            snap = snapshot(**kw)
            nodes = normalize(snap.get("nodes"))
            got = None
            for n in nodes:
                if n["ref"] == "w:%s" % loc["value"]:
                    got = n
                    break
            if want:
                same = bool(got) and (identity_of(got)["name"] == want.get("name")
                                      and identity_of(got)["role"] == want.get("role"))
                verdict["rechecked"] = True
                verdict["identity_match"] = same
                if not same:
                    # 编号被复用了：丢掉 ref，只按身份找
                    verdict["ref_rebound"] = True
                    step["locator"] = identity_locator(want)
        except Exception as exc:
            verdict["recheck_error"] = str(exc)[:160]

    steps = [{"op": "snapshot"}, step]
    r = batch(steps, **kw)
    results = r.get("results") or []
    last = results[-1] if results else {}
    out = dict(last)
    out["web"] = verdict
    out["ok"] = bool(r.get("ok")) and bool(last.get("ok", True))
    if not out.get("ok") and not out.get("error"):
        for item in results:
            if not item.get("ok"):
                out["error"] = item.get("error") or "WEB_STEP_FAILED"
                break
    # read 的答案是动作的产物，必须提到顶层。留在 attempts[].detail 里，
    # 调用方拿到的就只是「完成」两个字——读到了却不告诉他，等于没读。
    if step.get("action") == "read":
        val = None
        for attempt in (last.get("attempts") or []):
            detail = attempt.get("detail") or {}
            if detail.get("result") is not None:
                val = detail.get("result")
                break
            if detail.get("value") is not None:
                val = detail.get("value")
                break
        if val is None:
            val = last.get("result")
        if val is None:
            val = (last.get("hit") or {}).get("text")
        if val is not None:
            out["value"] = val
    return out


if __name__ == "__main__":
    print(json.dumps(health(), ensure_ascii=False, indent=2))
