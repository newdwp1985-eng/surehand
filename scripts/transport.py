#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""transport.py —— 桌面通道客户端，跨平台。

两个平台，端点在传输层不同，往上完全一致：

  macOS    AF_UNIX  /tmp/mccd-<uid>.sock       由内核 uid 权限保护
  Windows  TCP 回环 127.0.0.1:<随机端口>        由端点文件里的令牌保护

为什么 Windows 不用命名管道：Python 对命名管道的读写不做消息边界，
也没有可靠的 select；而回环 TCP 两端都是标准流，协议代码可以一字不改。
代价是本机任何进程都能尝试连接，所以握手必须验令牌，且令牌文件只对当前
用户可读。

协议始终是一行一个 JSON 请求、一行一个 JSON 响应。同一连接内的请求严格
按序执行，不同连接之间互不阻塞。
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLATFORM = "windows" if sys.platform.startswith("win") else (
    "macos" if sys.platform == "darwin" else "unsupported")

# ---- macOS 端点
BIN = ROOT / "engine" / "macos" / "bin" / "mccd"
BUILD = ROOT / "engine" / "macos" / "build.sh"
SOCK = ("/tmp/mccd-%d.sock" % os.getuid()) if PLATFORM == "macos" else ""

# ---- Windows 端点
WCCD = ROOT / "engine" / "windows" / "wccd.ps1"
ENDPOINT = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "surehand" / "wccd.json"

LOG = Path(os.environ.get("TMPDIR") or "/tmp") / "surehand-engine.log"

DEFAULT_TIMEOUT = 60.0
START_DEADLINE = 20.0


class DeskError(Exception):
    pass


def skill_version():
    """版本号只认 SKILL.md 的 frontmatter。

    放在 transport 这一层，是因为「引擎该不该换」要在这里判断；
    cli 的 --version 与 doctor 也复用它，避免两处各写一个。
    """
    try:
        text = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    except OSError:
        return ""
    for line in text.splitlines()[:20]:
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().strip('"\'')
    return ""


# ---------------------------------------------------------------- 端点

def endpoint_info():
    """给 doctor 用，不触发启动。"""
    if PLATFORM == "macos":
        return {"kind": "unix", "path": SOCK, "engine": str(BIN),
                "engine_exists": BIN.is_file()}
    if PLATFORM == "windows":
        try:
            ep = _win_endpoint()
            port = ep.get("port")
        except DeskError:
            port = None
        return {"kind": "tcp", "host": "127.0.0.1", "port": port,
                "engine": str(WCCD), "engine_exists": WCCD.is_file(),
                "endpoint_file": str(ENDPOINT)}
    return {"kind": "none", "engine": "", "engine_exists": False}


def _win_endpoint():
    try:
        ep = json.loads(ENDPOINT.read_text(encoding="utf-8"))
    except Exception:
        raise DeskError("没有端点文件 %s：引擎没启动过" % ENDPOINT)
    if not ep.get("port") or not ep.get("token"):
        raise DeskError("端点文件不完整：%s" % ENDPOINT)
    return ep


# ---------------------------------------------------------------- 连接

class Session:
    """一条已握手的会话。"""

    def __init__(self, sock, stream):
        self.sock = sock
        self.stream = stream

    def send(self, obj):
        self.stream.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
        self.stream.flush()

    def readline(self):
        line = self.stream.readline()
        if not line:
            return None
        return json.loads(line.decode("utf-8"))

    def call(self, obj):
        self.send(obj)
        return self.readline()

    def close(self):
        try:
            self.stream.close()
        finally:
            try:
                self.sock.close()
            except Exception:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def _open(timeout=DEFAULT_TIMEOUT):
    if PLATFORM == "macos":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCK)
        return Session(s, s.makefile("rwb"))
    if PLATFORM == "windows":
        ep = _win_endpoint()
        s = socket.create_connection(("127.0.0.1", int(ep["port"])), timeout)
        s.settimeout(timeout)
        ses = Session(s, s.makefile("rwb"))
        ses.send({"token": ep["token"]})
        ack = ses.readline()
        if not ack or not ack.get("ok"):
            ses.close()
            raise DeskError("握手被拒：%s" % ((ack or {}).get("error") or "无响应"))
        return ses
    raise DeskError("不支持的平台：%s" % sys.platform)


def probe(timeout=2.0):
    """真问一句 ping。只 connect 不算数：内核会替你完成握手，对面可能根本没在听。"""
    try:
        with _open(timeout) as ses:
            return ses.call({"cmd": "ping"})
    except Exception:
        return None


def alive():
    r = probe()
    return bool(r and r.get("ok"))


# ---------------------------------------------------------------- 启动

def _ensure_macos_bin():
    if BIN.is_file():
        return
    if not BUILD.is_file():
        raise DeskError("缺少引擎 %s，也找不到构建脚本" % BIN)
    proc = subprocess.run([str(BUILD)], capture_output=True, timeout=300)
    if proc.returncode != 0 or not BIN.is_file():
        raise DeskError("引擎构建失败：%s" % (
            (proc.stderr or b"").decode("utf-8", "replace").strip()[-400:] or "无输出"))
    try:
        os.chmod(BIN, 0o755)
    except Exception:
        pass


def _spawn(argv, env=None):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    log = open(LOG, "ab")
    kw = {"stdout": log, "stderr": log, "close_fds": True}
    if PLATFORM == "windows":
        # 不弹控制台；脱离父进程组，避免调用方退出时把引擎带走
        kw["creationflags"] = 0x00000008 | 0x00000200
    else:
        kw["start_new_session"] = True
    return subprocess.Popen(argv, env=env, **kw)


def _powershell():
    from shutil import which
    for cand in ("powershell.exe", "pwsh.exe", "powershell", "pwsh"):
        p = which(cand)
        if p:
            return p
    raise DeskError("找不到 PowerShell")


def daemon_version():
    """正在跑的那个引擎自报的版本。连不上就返回空串。

    用 ping 而不是 health：引擎没有 health 这个命令，
    猜错名字的后果是「永远读到空版本」，于是换引擎的逻辑静默失效——
    这正是它要防的那类错。
    """
    return str((probe(3.0) or {}).get("version") or "")


SWAP = ROOT / ".engine.swap"


def _semver_lt(a, b):
    """a 是否比 b 旧。比不出来就当「不旧」，宁可不换也不乱换。"""
    def key(v):
        parts = []
        for p in str(v).split("."):
            digits = "".join(c for c in p if c.isdigit())
            parts.append(int(digits) if digits else 0)
        return tuple((parts + [0, 0, 0])[:3])
    try:
        return key(a) < key(b)
    except Exception:
        return False


def _swap_marker():
    try:
        return SWAP.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _set_swap_marker(v):
    try:
        SWAP.write_text(v, encoding="utf-8")
    except Exception:
        pass


def _retire_engine():
    """让旧引擎退场。先礼后兵：shutdown 优雅退出，等不到再发信号。"""
    pid = int((probe(3.0) or {}).get("pid") or 0)
    try:
        with _open(3.0) as ses:
            ses.call({"cmd": "shutdown"})
    except Exception:
        pass
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if not alive():
            return True
        time.sleep(0.05)
    if pid > 0:
        try:
            os.kill(pid, 15)
            time.sleep(0.3)
        except Exception:
            pass
    return not alive()


def start(quiet=True):
    """确保引擎在跑，且跑的是当前这份技能的引擎。

    引擎是常驻的，握手又不校验版本。升级技能之后旧进程还在，
    新 CLI 会静默地用着旧引擎——新错误码它不认识、刚修好的语义它照旧。
    用户什么都没做错，只是「更新了一下」。所以版本对不上就换掉它。
    """
    if alive():
        have, want = daemon_version(), skill_version()
        if not (have and want) or have == want:
            return False
        # 直接写 stderr：这是「你刚更新的东西没生效」的唯一提示，
        # 藏着不说比不修更糟。--json 时 stdout 仍然只有一行 JSON。
        if not _semver_lt(have, want):
            # 引擎比技能新：多半是这台机器上还有另一份更新的安装。
            # 换掉它反而倒退，只提示。
            print("引擎是 %s，技能是 %s；引擎更新，继续用它（两份安装不同步？）"
                  % (have, want), file=sys.stderr)
            return False
        if _swap_marker() == want:
            # 换过一次还是对不上，说明源码与 SKILL.md 本来就不一致。
            # 再换就是每次调用重启一次引擎，比问题本身更糟。
            print("引擎仍是 %s（技能 %s）；已尝试更换未成功，"
                  "请确认 engine 源码与 SKILL.md 版本一致" % (have, want), file=sys.stderr)
            return False
        print("引擎版本 %s 与技能 %s 不一致，换用新引擎" % (have, want), file=sys.stderr)
        _set_swap_marker(want)
        if not _retire_engine():
            raise DeskError("旧引擎（%s）退不掉，请手动结束 pid 后重试" % have)
    if PLATFORM == "macos":
        _ensure_macos_bin()
        proc = _spawn([str(BIN)])
    elif PLATFORM == "windows":
        if not WCCD.is_file():
            raise DeskError("缺少引擎 %s" % WCCD)
        proc = _spawn([_powershell(), "-NoProfile", "-NonInteractive",
                       "-ExecutionPolicy", "Bypass", "-File", str(WCCD)])
    else:
        raise DeskError("不支持的平台：%s" % sys.platform)

    deadline = time.time() + START_DEADLINE
    while time.time() < deadline:
        if alive():
            return True
        if proc.poll() not in (None, 0):
            break
        time.sleep(0.05)
    if alive():
        return True
    tail = ""
    try:
        tail = LOG.read_text(encoding="utf-8", errors="replace")[-600:]
    except Exception:
        pass
    raise DeskError("引擎起不来（见 %s）%s" % (LOG, ("\n" + tail) if tail else ""))


def stop():
    try:
        with _open(5.0) as ses:
            ses.call({"cmd": "shutdown"})
    except Exception:
        pass
    if PLATFORM == "windows":
        try:
            ENDPOINT.unlink()
        except Exception:
            pass


# ---------------------------------------------------------------- 调用

def call(req, timeout=DEFAULT_TIMEOUT):
    start()
    with _open(timeout) as ses:
        r = ses.call(req)
    if r is None:
        raise DeskError("引擎无响应")
    return r


def pipeline(reqs, timeout=180.0):
    """一条连接跑完整串，省掉每次的建连税。"""
    if not reqs:
        return []
    start()
    out = []
    with _open(timeout) as ses:
        for r in reqs:
            ses.send(r)
        for _ in reqs:
            got = ses.readline()
            if got is None:
                break
            out.append(got)
    return out


# ---------------------------------------------------------------- 角色名归一化

# 两个平台的角色命名体系不一样：macOS 是 AXButton / AXTextField，UIA 是 button / edit。
# 使用者的书写习惯只有一套，所以这里做双向翻译——写 AXButton 或 button 都能落到位。
# 规范键取 macOS 名的去前缀小写形式（button、textfield…），因为文档一直这么写。
_AX_NAME = {
    "button": "AXButton", "textfield": "AXTextField", "textarea": "AXTextArea",
    "statictext": "AXStaticText", "window": "AXWindow", "checkbox": "AXCheckBox",
    "radiobutton": "AXRadioButton", "combobox": "AXComboBox", "list": "AXList",
    "menu": "AXMenu", "menuitem": "AXMenuItem", "tabgroup": "AXTabGroup",
    "group": "AXGroup", "image": "AXImage", "link": "AXLink", "slider": "AXSlider",
    "scrollarea": "AXScrollArea", "table": "AXTable", "row": "AXRow", "cell": "AXCell",
    "outline": "AXOutline", "toolbar": "AXToolBar", "popupbutton": "AXPopUpButton",
    "progressindicator": "AXProgressIndicator", "webarea": "AXWebArea",
    "splitter": "AXSplitter", "sheet": "AXSheet", "drawer": "AXDrawer",
}
_UIA_NAME = {
    "button": "button", "textfield": "edit", "textarea": "document",
    "statictext": "text", "window": "window", "checkbox": "checkbox",
    "radiobutton": "radiobutton", "combobox": "combobox", "list": "list",
    "menuitem": "menuitem", "tabgroup": "tab", "group": "group", "image": "image",
    "link": "hyperlink", "slider": "slider", "scrollarea": "pane", "table": "table",
    "row": "dataitem", "cell": "dataitem", "outline": "tree", "toolbar": "toolbar",
    "popupbutton": "splitbutton", "progressindicator": "progressbar",
    "webarea": "document", "splitter": "pane", "sheet": "pane", "drawer": "pane",
}


def norm_role(role, platform=None):
    """把任意写法翻成当前平台引擎认的名字。空值原样返回。"""
    if not role:
        return role
    p = platform or PLATFORM
    key = role.strip().lower()
    if key.startswith("ax"):
        key = key[2:]
    if p == "windows":
        return _UIA_NAME.get(key, key)
    if p == "macos":
        if key in _AX_NAME:
            return _AX_NAME[key]
        return "AX" + key[:1].upper() + key[1:]
    return role


def canon_role(role):
    """把平台名收敛到规范键，用于跨平台比较与显示。"""
    if not role:
        return ""
    key = role.strip().lower()
    if key.startswith("ax"):
        key = key[2:]
    for canon, uia in _UIA_NAME.items():
        if key == uia:
            return canon
    return key


# ---------------------------------------------------------------- 语义包装

def snapshot(app=None, window=None, max_nodes=1500, include_static=True,
             from_ref=None, max_depth=None):
    req = {"cmd": "snapshot", "max_nodes": max_nodes, "include_static": include_static}
    if app:
        req["app"] = app
    if window:
        req["window"] = window
    if from_ref:
        req["from"] = from_ref
    if max_depth:
        req["max_depth"] = max_depth
    return call(req, timeout=300)


def act(action="click", ref=None, app=None, role=None, name=None, ident=None,
        text=None, key=None, dy=None, prefer="auto", verify="attach",
        contains=False, window=None):
    req = {"cmd": "act", "action": action, "verbose": True}
    for k, v in (("ref", ref), ("app", app), ("window", window),
                 ("role", norm_role(role)), ("name", name), ("id", ident),
                 ("text", text), ("key", key),
                 ("prefer", prefer), ("verify", verify)):
        # text 允许空串：清空输入框是合法动作（填表前先清旧值），
        # 被当成「没给」会让调用方只能删字符，效率和正确性都掉一档。
        if k == "text":
            if v is not None:
                req[k] = v
        elif v not in (None, ""):
            req[k] = v
    if contains:
        req["contains"] = True
    if dy is not None:
        req["dy"] = dy
    return call(req)


def state(ref, verify="attach"):
    return call({"cmd": "state", "ref": ref, "verify": verify})


def attrs(ref=None, x=None, y=None):
    req = {"cmd": "attrs"}
    if ref:
        req["ref"] = ref
    else:
        req.update({"x": x, "y": y})
    return call(req)


def windows(app=None):
    req = {"cmd": "windows"}
    if app:
        req["app"] = app
    return call(req)


def shot(app=None, window=None, out=None, grid=False, grid_step=100):
    req = {"cmd": "shot"}
    if app:
        req["app"] = app
    if window:
        req["window"] = window
    if out:
        req["out"] = out
    if grid:
        req["grid"] = True
        req["grid_step"] = grid_step
    return call(req, timeout=120)


def tap(app, x, y, space="point", count=1):
    """窗口内相对坐标点击。坐标由窗口几何现算，不读图，免疫截图缩放。"""
    return call({"cmd": "clickat", "app": app, "x": x, "y": y,
                 "space": space, "count": count, "raise": True})


def scroll_at(app, x, y, dy=-6, times=1, space="point"):
    return call({"cmd": "scrollat", "app": app, "x": x, "y": y,
                 "dy": dy, "times": times, "space": space, "raise": True})


def hover(app, x, y, space="point"):
    return call({"cmd": "moveat", "app": app, "x": x, "y": y, "space": space, "raise": True})


def activate(app):
    return call({"cmd": "activate", "app": app})


def paste(text, restore=True):
    return call({"cmd": "paste", "text": text, "restore": restore}, timeout=120)


def keys(combo):
    return call({"cmd": "keys", "key": combo})


def apps():
    return call({"cmd": "apps"})


def health():
    r = probe()
    return {"daemon": bool(r and r.get("ok")),
            "platform": PLATFORM,
            "version": (r or {}).get("version", ""),
            "pid": (r or {}).get("pid", 0),
            "ax_trusted": bool((r or {}).get("ax_trusted")),
            "screen_trusted": bool((r or {}).get("screen_trusted")),
            "frontmost": (r or {}).get("frontmost", ""),
            "endpoint": endpoint_info(),
            "log": str(LOG)}


if __name__ == "__main__":
    print(json.dumps(health(), ensure_ascii=False, indent=2))
