#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mcp_server.py —— 把 Surehand 包成一个 MCP server。

为什么需要这一层：技能文档（SKILL.md）只有认识这种格式的宿主会读。Claude Code、
Cursor、Codex、DeepSeek Harness 这些客户端共同认的是 MCP。包一层之后，同一套
观察与动作能力对它们全部可用，不必逐个移植。

协议实现只做管道，不含判断逻辑：每个工具都转成一次 CLI 调用（--json），
把结果原样交给客户端。判断留在 evidence.py 一处，避免两份实现漂移。

启动：  python3 scripts/mcp_server.py
注册：  见 README 的「接进任意 agent」一节。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = Path(__file__).resolve().parent / "cli.py"


def _skill_version():
    """版本号只认 SKILL.md 的 frontmatter。写死一个常量，迟早和引擎、
    CLI 各说各话；而握手时自报的版本正是客户端用来判断「要不要升级」的依据。"""
    try:
        text = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    except OSError:
        return "unknown"
    for line in text.splitlines()[:20]:
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().strip('"\'')
    return "unknown"


VERSION = _skill_version()
PROTOCOL = "2025-06-18"

# 工具调用可能很慢（整窗遍历、等界面变化），给足时间但不无限等。
DEFAULT_TIMEOUT = 180


def log(msg):
    """调试信息一律走 stderr。stdout 是协议通道，写脏话就断连。"""
    sys.stderr.write("[surehand-mcp] %s\n" % msg)
    sys.stderr.flush()


def run_cli(args, timeout=DEFAULT_TIMEOUT):
    """跑一次 CLI，拿它最后一行 JSON。CLI 的诊断在 stderr，不干扰解析。"""
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    try:
        proc = subprocess.run([sys.executable, str(CLI), "--json"] + [str(a) for a in args],
                              capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return False, {"ok": False, "error": "TIMEOUT",
                       "hint": "命令超过 %d 秒；先 look 看界面停在哪一步" % timeout}
    text = (proc.stdout or "").strip()
    data = None
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                data = json.loads(line)
            except ValueError:
                data = None
            if data is not None:
                break
    if data is None:
        data = {"ok": False, "error": "NO_JSON",
                "raw": text[:800], "stderr": (proc.stderr or "")[:800]}
    ok = bool(data.get("ok")) and proc.returncode not in (1, 2)
    if proc.returncode == 2:
        # 2 = 不确定。不是成功，但也不等于失败，调用方必须看 delivery。
        ok = False
        data.setdefault("delivery", {"state": "uncertain", "retry": "unsafe"})
    return ok, data


# --------------------------------------------------------------------- 工具表
# 描述写给模型看，所以每一条都说明「什么时候用」，而不是「它做了什么」。

def tool_defs():
    app = {"type": "string", "description": "应用名，如 微信 / Calculator / TextEdit"}
    ref = {"type": "string", "description": "令牌，如 d:e12（桌面）或 w:3（网页）。只从最近一次 look 拿"}
    role = {"type": "string", "description": "角色名，如 AXButton / button / textbox；与 name 或 id 配合"}
    name = {"type": "string", "description": "元素可见名/标题"}
    ident = {"type": "string", "description": "机器标识（AXIdentifier / AutomationId），比名字稳"}
    text = {"type": "string", "description": "要写入或粘贴的文字"}
    return [
        {
            "name": "surehand_doctor",
            "description": "环境体检：引擎是否活着、辅助功能与屏幕录制权限、浏览器调试端口、仓库是否完整。"
                           "会话开始时先调它，能省掉后面一半的疑难。",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "surehand_apps",
            "description": "列出正在运行且可访问的应用。用它确认应用名怎么写，避免 APP_NOT_FOUND。",
            "inputSchema": {"type": "object", "properties": {
                "filter": {"type": "string", "description": "按名字过滤，不区分大小写"}},
                "additionalProperties": False},
        },
        {
            "name": "surehand_activate",
            "description": "把某个应用切到前台。点击之前几乎总要先做这一步："
                           "后台窗口的坐标点击会落到别处。",
            "inputSchema": {"type": "object", "properties": {"app": app}, "required": ["app"],
                            "additionalProperties": False},
        },
        {
            "name": "surehand_look",
            "description": "观察界面并拿到令牌。桌面元素走可访问性树（macOS AX / Windows UIA），"
                           "网页走 CDP。返回里会说明这次是结构面还是视觉面（自绘界面读不到元素时），"
                           "以及哪些是能动手的令牌、哪些只能看。动手前必须先 look。",
            "inputSchema": {"type": "object", "properties": {
                "app": app,
                "window": {"type": "string", "description": "窗口标题包含的片段，多窗口时收窄"},
                "web": {"type": "boolean", "description": "true 则观察浏览器当前页"},
                "depth": {"type": "integer", "description": "限制遍历深度；大树先用 3 摸骨架"},
                "from_ref": {"type": "string", "description": "从某个令牌所在子树往下看，如 d:e91"},
                "max": {"type": "integer", "description": "节点上限，默认 1500"}},
                "additionalProperties": False},
        },
        {
            "name": "surehand_find",
            "description": "只找不动：按角色/名字/标识定位元素，返回命中集合与结论。"
                           "命中多个会明确说「必须收窄」，不会替你选一个。",
            "inputSchema": {"type": "object", "properties": {
                "app": app, "role": role, "name": name, "id": ident,
                "contains": {"type": "boolean", "description": "名字按包含匹配而不是全等"},
                "web": {"type": "boolean", "description": "true 则在网页里找"}},
                "additionalProperties": False},
        },
        {
            "name": "surehand_do",
            "description": "做一件事。返回值里 delivery.state 是权威：delivered 才算成，"
                           "uncertain 表示「已发出但没拿到确认」，必须再 look 复核，不要直接重放。"
                           "read 会直接给出读到的文本。",
            "inputSchema": {"type": "object", "properties": {
                "verb": {"type": "string", "enum": ["click", "fill", "read", "type", "key",
                                                     "paste", "scroll"],
                         "description": "click=点，fill=设值，read=读文本，type=模拟键入，"
                                        "key=组合键，paste=剪贴板粘贴，scroll=滚动"},
                "ref": ref, "app": app, "role": role, "name": name, "id": ident,
                "text": text,
                "key": {"type": "string", "description": "组合键，如 cmd+s / ctrl+a / return"},
                "prefer": {"type": "string", "enum": ["auto", "ax", "cg"],
                           "description": "auto 默认：优先应用层动作拿确定回执，不支持才降级坐标"},
                "strict": {"type": "boolean", "description": "复核更严：要求整窗唯一且字段读全"}},
                "required": ["verb"], "additionalProperties": False},
        },
        {
            "name": "surehand_tap",
            "description": "按窗口内相对点数点击。视觉通道（自绘界面、读不到元素的窗口）专用。"
                           "坐标是窗口内的点，不是截图里的像素——截图可能被缩放。",
            "inputSchema": {"type": "object", "properties": {
                "app": app, "x": {"type": "number"}, "y": {"type": "number"},
                "count": {"type": "integer", "description": "点击次数，2 即双击"}},
                "required": ["app", "x", "y"], "additionalProperties": False},
        },
        {
            "name": "surehand_shot",
            "description": "截取窗口或整屏，返回图片路径与换算依据（scale / 窗口原点）。"
                           "视觉通道用它拿几何；点击仍要用 tap 的点数，不要照抄图片像素。",
            "inputSchema": {"type": "object", "properties": {
                "app": app, "window": {"type": "string"},
                "out": {"type": "string", "description": "保存路径，默认临时文件"},
                "grid": {"type": "boolean", "description": "叠一层坐标网格，便于读位置"}},
                "additionalProperties": False},
        },
        {
            "name": "surehand_state",
            "description": "读某个令牌指向元素的当前状态（角色、名字、值、启用、几何、可用动作）。"
                           "用于动作前后的复核，比整窗 look 便宜得多。",
            "inputSchema": {"type": "object", "properties": {"ref": ref, "web": {"type": "boolean"}},
                            "required": ["ref"], "additionalProperties": False},
        },
        {
            "name": "surehand_web",
            "description": "网页动作。goto 打开地址，click/fill/read 按 ref 或语义定位，"
                           "press 发组合键，eval 执行表达式，wait 等条件成立，scroll 滚动。",
            "inputSchema": {"type": "object", "properties": {
                "op": {"type": "string", "enum": ["goto", "click", "fill", "read", "press",
                                                   "eval", "wait", "scroll"]},
                "url": {"type": "string"},
                "ref": {"type": "string", "description": "网页令牌，如 w:3"},
                "role": role, "name": name,
                "css": {"type": "string", "description": "CSS 选择器，前两种定位都不成就用它"},
                "text": {"type": "string", "description": "fill 的值 / eval 的表达式 / wait 的条件"},
                "key": {"type": "string", "description": "press 的组合键"},
                "dy": {"type": "integer", "description": "scroll 的纵向像素，正数向下"},
                "timeout": {"type": "number", "description": "wait 的上限秒数"}},
                "required": ["op"], "additionalProperties": False},
        },
        {
            "name": "surehand_launch_browser",
            "description": "起一个带调试端口的浏览器实例（独立 profile）。"
                           "已经开着但没开调试端口的浏览器无法事后补开，只能用它另起一个。",
            "inputSchema": {"type": "object", "properties": {
                "port": {"type": "integer", "default": 9222},
                "profile": {"type": "string", "description": "profile 目录，默认 ~/.surehand/chrome-profile"},
                "url": {"type": "string"}},
                "additionalProperties": False},
        },
        {
            "name": "surehand_run",
            "description": "跑一份多步计划文件（JSON）。适合先看后动的连贯流程，"
                           "比逐条调用少一半进程开销。",
            "inputSchema": {"type": "object", "properties": {
                "path": {"type": "string", "description": "步骤文件路径"}},
                "required": ["path"], "additionalProperties": False},
        },
    ]


# ------------------------------------------------------------------ 工具 → CLI

def build_argv(name, a):
    """把工具参数翻成 CLI 参数。保持一一对应，方便照着文档手敲同样的命令。"""
    if name == "surehand_doctor":
        return ["doctor"]
    if name == "surehand_apps":
        return ["apps"] + (["--filter", a["filter"]] if a.get("filter") else [])
    if name == "surehand_activate":
        return ["activate", "--app", a["app"]]
    if name == "surehand_look":
        argv = ["look"]
        for k in ("app", "window"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        if a.get("from_ref"):
            argv += ["--from", a["from_ref"]]
        if a.get("depth") is not None:
            argv += ["--depth", a["depth"]]
        if a.get("max") is not None:
            argv += ["--max", a["max"]]
        if a.get("web"):
            argv.append("--web")
        return argv
    if name == "surehand_find":
        argv = ["find"]
        for k in ("app", "role", "id"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        if a.get("name"):
            argv += ["--text", a["name"]]
        if a.get("contains"):
            argv.append("--contains")
        if a.get("web"):
            argv.append("--web")
        return argv
    if name == "surehand_do":
        argv = ["do", a["verb"]]
        if a.get("ref"):
            argv += ["--ref", a["ref"]]
        for k in ("app", "role", "name", "id"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        if a.get("text") is not None:
            argv += ["--text", a["text"]]
        if a.get("key"):
            argv += ["--combo", a["key"]]
        if a.get("prefer"):
            argv += ["--prefer", a["prefer"]]
        if a.get("strict"):
            argv.append("--strict")
        return argv
    if name == "surehand_tap":
        argv = ["tap", "--app", a["app"], "--x", a["x"], "--y", a["y"]]
        if a.get("count"):
            argv += ["--count", a["count"]]
        return argv
    if name == "surehand_shot":
        argv = ["shot"]
        for k in ("app", "window", "out"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        if a.get("grid"):
            argv.append("--grid")
        return argv
    if name == "surehand_state":
        return ["state", "--ref", a["ref"]]
    if name == "surehand_web":
        op = a["op"]
        argv = ["do", op]
        if a.get("url"):
            argv += ["--url", a["url"]]
        if a.get("ref"):
            argv += ["--ref", a["ref"]]
        for k in ("role", "css"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        if a.get("name"):
            argv += ["--text", a["name"]]
        if a.get("text") is not None:
            argv += ["--text", a["text"]]
        if a.get("key"):
            argv += ["--combo", a["key"]]
        if a.get("dy") is not None:
            argv += ["--dy", a["dy"]]
        if a.get("timeout") is not None:
            argv += ["--timeout", a["timeout"]]
        argv.append("--web")
        return argv
    if name == "surehand_launch_browser":
        argv = ["launch"]
        if a.get("port"):
            argv += ["--port", a["port"]]
        for k in ("profile", "url"):
            if a.get(k):
                argv += ["--" + k, a[k]]
        return argv
    if name == "surehand_run":
        return ["run", a["path"]]
    raise KeyError(name)


def text_of(data):
    """给模型看的一行结论。优先说人话，附上结构化原文。"""
    if not isinstance(data, dict):
        return json.dumps(data, ensure_ascii=False)[:4000]
    delivery = data.get("delivery") or {}
    head = []
    if data.get("error"):
        head.append("错误 %s" % data["error"])
        if data.get("hint"):
            head.append(str(data["hint"])[:300])
    if delivery.get("state"):
        head.append("投递=%s 重试=%s" % (delivery.get("state"), delivery.get("retry")))
    if data.get("value") is not None:
        head.append("值=%s" % str(data["value"])[:1000])
    body = json.dumps(data, ensure_ascii=False)
    if len(body) > 12000:
        body = body[:12000] + "…（已截断，完整内容见 structuredContent）"
    return ("\n".join(head) + "\n\n" if head else "") + body


def call_tool(name, args):
    argv = build_argv(name, args or {})
    ok, data = run_cli(argv)
    is_error = not ok
    # 不确定不是错误，但也不能当成功：单独标出来，让调用方去复核。
    if isinstance(data, dict) and (data.get("delivery") or {}).get("state") == "uncertain":
        is_error = True
    return {
        "content": [{"type": "text", "text": text_of(data)}],
        "structuredContent": data if isinstance(data, dict) else {"result": data},
        "isError": is_error,
    }


# ------------------------------------------------------------------ JSON-RPC

def reply(msg_id, result=None, error=None):
    payload = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(req):
    method = req.get("method")
    msg_id = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        want = params.get("protocolVersion") or PROTOCOL
        reply(msg_id, {
            "protocolVersion": want,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "surehand", "version": VERSION},
            "instructions": ("先 surehand_look 观察，再 surehand_do 动手。"
                             "令牌只从最近一次观察拿，旧令牌会明确失效而不是被复用。"
                             "动作结果看 delivery.state：delivered 才算成，"
                             "uncertain 必须再 look 复核。"),
        })
        return
    if method in ("notifications/initialized", "initialized"):
        return                                    # 通知不需要回复
    if method == "ping":
        reply(msg_id, {})
        return
    if method == "tools/list":
        reply(msg_id, {"tools": tool_defs()})
        return
    if method == "tools/call":
        name = params.get("name")
        known = {t["name"] for t in tool_defs()}
        if name not in known:
            reply(msg_id, error={"code": -32602, "message": "未知工具：%s" % name})
            return
        try:
            reply(msg_id, call_tool(name, params.get("arguments") or {}))
        except Exception as exc:                   # 工具内部的意外不能拖垮整个 server
            log("工具 %s 抛异常：%r" % (name, exc))
            reply(msg_id, error={"code": -32603, "message": "%s: %s" % (type(exc).__name__, exc)})
        return
    if msg_id is None:
        return                                    # 其余通知一律忽略
    reply(msg_id, error={"code": -32601, "message": "不支持的方法：%s" % method})


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass
    log("ready, version=%s, cli=%s" % (VERSION, CLI))
    for line in sys.stdin.buffer:
        line = line.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            reply(None, error={"code": -32700, "message": "不是合法 JSON"})
            continue
        if isinstance(req, list):                 # 批量请求
            for one in req:
                handle(one)
        else:
            handle(req)
    return 0


if __name__ == "__main__":
    sys.exit(main())
