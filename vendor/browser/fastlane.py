#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fastlane.py —— 浏览器操作四层加速编排器 v2（零第三方依赖）。

四层自上而下，能停在上层就不往下走：
  L1 页面内 fetch 直调接口，credentials:'include' 复用浏览器登录态
  L2 语义 DOM 定位 + 可访问性快照（ref / text / role / css / label / placeholder / tag）
  L3 长连接复用同一条 CDP WebSocket，发原生输入事件
  L4 视觉兜底，仅允许落在 Canvas / 自绘控件矩形内的坐标

v2 结合 browser-automation 规格后新增：
  - ref 快照：snapshot 给可交互元素编号，后续按 ref 直接定位，跳过全量遍历
  - 定位优先级链：auto 按 ref → text → role → css 逐层尝试
  - 真实抓包：注入 fetch / XHR 拦截器，记录请求体、状态码与响应体
  - 遮挡与 disabled 检测：命中元素不可点时明确报错，不静默点偏
  - 批量 op：goto / wait / sleep / eval / press / scroll / hover / select /
    snapshot / capture / probe 与四层动作在同一条连接上混排

传输层以只读方式复用 browser-automation-cdp 的 cdp.py（Python 标准库
WebSocket 客户端），不修改任何现有技能文件。

标准输出恒为一行 JSON；诊断信息走标准错误。
退出码：0 成功；1 动作失败或环境不可达。
"""

import argparse
import base64
import importlib.util
import json
import os
import platform
import sys
import time
from pathlib import Path


def force_direct_local():
    """CDP 全部走 127.0.0.1，强制绕过环境里的 HTTP 代理。

    代理转发本地端口时，浏览器短暂未监听会被回成 502 Bad Gateway，
    与「浏览器没启动」无法区分，会让上层误判并重复启动浏览器。
    """
    hosts = ["127.0.0.1", "localhost", "::1"]
    current = os.environ.get("no_proxy") or os.environ.get("NO_PROXY") or ""
    parts = [p.strip() for p in current.split(",") if p.strip()]
    for host in hosts:
        if host not in parts:
            parts.append(host)
    value = ",".join(parts)
    os.environ["no_proxy"] = value
    os.environ["NO_PROXY"] = value


force_direct_local()

CDP_LIB = (
    Path.home()
    / ".workbuddy"
    / "skills"
    / "browser-automation-cdp"
    / "scripts"
    / "cdp.py"
)

LAYERS = ["L1", "L2", "L3", "L4"]
TIME_BUDGET = {"L1": 3.0, "L2": 5.0, "L3": 5.0, "L4": 15.0}
ACTION_ALIAS = {"click": "click", "type": "fill", "fill": "fill",
                "read": "read", "select": "select"}
KEYMAP = {
    "Enter": (13, "Enter", "Enter"), "Tab": (9, "Tab", "Tab"),
    "Escape": (27, "Escape", "Escape"), "Backspace": (8, "Backspace", "Backspace"),
    "ArrowDown": (40, "ArrowDown", "ArrowDown"), "ArrowUp": (38, "ArrowUp", "ArrowUp"),
    "ArrowLeft": (37, "ArrowLeft", "ArrowLeft"), "ArrowRight": (39, "ArrowRight", "ArrowRight"),
    "Space": (32, " ", "Space"),
}


class FastlaneError(Exception):
    """编排层错误。"""


def load_cdp_module():
    if not CDP_LIB.is_file():
        raise FastlaneError(
            "缺少 CDP 传输层 %s。请先安装 browser-automation-cdp 技能。" % CDP_LIB
        )
    spec = importlib.util.spec_from_file_location("_fastlane_cdp_lib", str(CDP_LIB))
    if spec is None or spec.loader is None:
        raise FastlaneError("无法加载 CDP 传输层")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------
# 页面内 JS 片段。用独立占位符替换，避免与 JS 自身的 % 和 {} 冲突。
# --------------------------------------------------------------------------
HELPERS = r"""
  const norm = s => String(s == null ? '' : s).replace(/\s+/g, ' ').trim().toLowerCase();
  const roleOf = el => {
    const tag = el.tagName.toUpperCase();
    const explicit = el.getAttribute('role');
    if (explicit) return explicit;
    if (tag === 'BUTTON') return 'button';
    if (tag === 'A') return el.getAttribute('href') ? 'link' : 'generic';
    if (tag === 'SELECT') return 'combobox';
    if (tag === 'TEXTAREA') return 'textbox';
    if (tag === 'INPUT') {
      const t = (el.type || 'text').toLowerCase();
      if (t === 'checkbox') return 'checkbox';
      if (t === 'radio') return 'radio';
      if (t === 'button' || t === 'submit' || t === 'reset') return 'button';
      return 'textbox';
    }
    return 'generic';
  };
  const nameOf = el => {
    let n = el.getAttribute('aria-label') || el.getAttribute('placeholder') || '';
    if (!n && el.labels && el.labels.length) n = el.labels[0].innerText || '';
    if (!n) n = el.innerText || el.value || el.getAttribute('title') || '';
    return String(n).replace(/\s+/g, ' ').trim().slice(0, 120);
  };
  const visible = el => {
    const r = el.getBoundingClientRect();
    return r.width >= 1 && r.height >= 1;
  };
  const nodes = () => Array.from(document.querySelectorAll(
    'a,button,input,textarea,select,[role],[tabindex],[contenteditable="true"]'
  )).filter(visible);
  const rectOf = el => {
    const r = el.getBoundingClientRect();
    return {
      x: Math.round(r.x + r.width / 2),
      y: Math.round(r.y + r.height / 2),
      rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)]
    };
  };
  const describe = el => {
    document.querySelectorAll('[data-fastlane-hit]').forEach(e => e.removeAttribute('data-fastlane-hit'));
    const r = el.getBoundingClientRect();
    const cx = Math.round(r.x + r.width / 2), cy = Math.round(r.y + r.height / 2);
    const top = document.elementFromPoint(cx, cy);
    const covered = !!top && top !== el && !el.contains(top);
    const disabled = el.disabled === true || el.getAttribute('aria-disabled') === 'true';
    el.setAttribute('data-fastlane-hit', '1');
    return Object.assign({
      count: 1,
      tag: el.tagName.toLowerCase(),
      role: roleOf(el),
      name: nameOf(el),
      ref: el.getAttribute('data-fastlane-ref'),
      covered: covered,
      disabled: disabled,
      topTag: top ? top.tagName.toLowerCase() : null
    }, rectOf(el));
  };
"""

SNAPSHOT_EXPR = r"""
(() => {
__HELPERS__
  return nodes().map((el, i) => {
    el.setAttribute('data-fastlane-ref', String(i + 1));
    return Object.assign({
      ref: i + 1,
      tag: el.tagName.toLowerCase(),
      role: roleOf(el),
      name: nameOf(el),
      value: (el.value === undefined ? null : el.value),
      href: el.getAttribute('href') || null
    }, rectOf(el));
  });
})()
""".replace("__HELPERS__", HELPERS)

REF_LOCATE_EXPR = r"""
(() => {
__HELPERS__
  const el = document.querySelector('[data-fastlane-ref="' + __N__ + '"]');
  return el ? describe(el) : {count: 0, stale: true};
})()
""".replace("__HELPERS__", HELPERS)

LOCATE_EXPR = r"""
(() => {
__HELPERS__
  const spec = __SPEC__;
  if (spec.by === 'css') {
    const el = document.querySelector(spec.value);
    return el ? describe(el) : {count: 0};
  }
  const want = norm(spec.value);
  const hits = nodes().filter(el => {
    const role = norm(roleOf(el));
    const name = norm(nameOf(el));
    const ph = norm(el.getAttribute('placeholder'));
    let label = '';
    if (el.labels && el.labels.length) label = norm(el.labels[0].innerText || '');
    const text = norm(el.innerText || el.value || '');
    const tag = norm(el.tagName);
    switch (spec.by) {
      case 'role': return role === want && (!spec.name || name.indexOf(norm(spec.name)) >= 0);
      case 'name': return name.indexOf(want) >= 0;
      case 'text': return text.indexOf(want) >= 0;
      case 'label': return label.indexOf(want) >= 0;
      case 'placeholder': return ph.indexOf(want) >= 0;
      case 'tag': return tag === want;
      default: return false;
    }
  });
  if (hits.length !== 1) {
    return {
      count: hits.length,
      preview: hits.slice(0, 3).map(e => ({role: roleOf(e), name: nameOf(e)}))
    };
  }
  return describe(hits[0]);
})()
""".replace("__HELPERS__", HELPERS)

CLICK_EXPR = r"""
(() => {
  const el = document.querySelector('[data-fastlane-hit]');
  if (!el) return 'NOT_FOUND';
  el.scrollIntoView({block: 'center'});
  el.click();
  return 'OK';
})()
"""

FILL_EXPR = r"""
(() => {
  const el = document.querySelector('[data-fastlane-hit]');
  if (!el) return 'NOT_FOUND';
  const tag = el.tagName.toUpperCase();
  const editable = el.getAttribute('contenteditable') === 'true';
  if (tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT' && !editable) return 'NOT_INPUT:' + tag;
  el.scrollIntoView({block: 'center'});
  el.focus();
  const val = __TEXT__;
  if (editable) {
    el.textContent = val;
  } else {
    const proto = tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype
      : (tag === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, val); else el.value = val;
  }
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return 'OK';
})()
"""

READ_EXPR = r"""
(() => {
  const el = document.querySelector('[data-fastlane-hit]');
  return el ? (el.innerText || el.value || '') : null;
})()
"""

API_EXPR = r"""
(async () => {
  const opt = {method: __METHOD__, credentials: 'include', headers: __HEADERS__};
  const body = __BODY__;
  if (body !== null && opt.method !== 'GET' && opt.method !== 'HEAD') {
    if (typeof body === 'object' && !Object.keys(opt.headers).some(h => h.toLowerCase() === 'content-type')) {
      opt.headers['Content-Type'] = 'application/json';
    }
    opt.body = (typeof body === 'string') ? body : JSON.stringify(body);
  }
  const r = await fetch(__URL__, opt);
  const text = await r.text();
  return {status: r.status, ok: r.ok, url: r.url, body: String(text).slice(0, 2000)};
})()
"""

SNIFF_EXPR = r"""
(() => performance.getEntriesByType('resource')
  .filter(e => e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest')
  .map(e => ({
    name: e.name,
    initiatorType: e.initiatorType,
    duration: Number(e.duration.toFixed(1)),
    transferSize: e.transferSize
  })).slice(-40))()
"""

CAPTURE_INJECT_EXPR = r"""
(() => {
  if (window.__FL_NET_INSTALLED) return {installed: false, reason: 'already'};
  window.__FL_NET = [];
  const push = e => { if (window.__FL_NET.length < 120) window.__FL_NET.push(e); };
  const origFetch = window.fetch;
  window.fetch = function(input, init) {
    const url = typeof input === 'string' ? input : ((input && input.url) || '');
    const method = (init && init.method) || (input && input.method) || 'GET';
    const body = (init && init.body !== undefined) ? init.body : null;
    const rec = {
      kind: 'fetch', url: String(url), method: String(method).toUpperCase(),
      body: body == null ? null : String(body).slice(0, 2000),
      status: null, response: null, ms: null
    };
    push(rec);
    const t0 = performance.now();
    return origFetch.apply(this, arguments).then(r => {
      rec.status = r.status;
      rec.ms = Math.round(performance.now() - t0);
      try {
        r.clone().text().then(t => { rec.response = String(t).slice(0, 2000); }).catch(() => {});
      } catch (e) {}
      return r;
    });
  };
  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) {
    this.__fl_m = m; this.__fl_u = u;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(b) {
    const rec = {
      kind: 'xhr', url: String(this.__fl_u || ''),
      method: String(this.__fl_m || 'GET').toUpperCase(),
      body: b == null ? null : String(b).slice(0, 2000),
      status: null, response: null, ms: null
    };
    push(rec);
    const t0 = performance.now();
    this.addEventListener('loadend', () => {
      rec.status = this.status;
      rec.ms = Math.round(performance.now() - t0);
      try { rec.response = String(this.responseText || '').slice(0, 2000); } catch (e) {}
    });
    return origSend.apply(this, arguments);
  };
  window.__FL_NET_INSTALLED = true;
  return {installed: true};
})()
"""

CAPTURE_READ_EXPR = r"""
(() => {
  const a = window.__FL_NET || [];
  window.__FL_NET = [];
  return a;
})()
"""

PROBE_EXPR = r"""
(() => {
  const el = document.elementFromPoint(__X__, __Y__);
  if (!el) return null;
  return {
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role'),
    name: el.getAttribute('aria-label') || String(el.innerText || '').trim().slice(0, 60),
    outer: el.outerHTML.slice(0, 300)
  };
})()
"""

SCROLL_EXPR = r"""
(() => {
  window.scrollBy(0, __DY__);
  return {scrollY: Math.round(window.scrollY)};
})()
"""

VISION_GUARD_EXPR = r"""
(() => {
__HELPERS__
  const x = __X__, y = __Y__;
  const cs = Array.from(document.querySelectorAll('canvas,[data-selfdrawn]'));
  if (!cs.length) return {allowed: false, reason: '页面没有 Canvas 或自绘控件，禁止降级到视觉层'};
  const hit = cs.find(c => {
    const r = c.getBoundingClientRect();
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
  });
  if (!hit) return {allowed: false, reason: '坐标不在 Canvas / 自绘控件矩形内'};
  return {allowed: true, reason: 'canvas', tag: hit.tagName.toLowerCase()};
})()
""".replace("__HELPERS__", HELPERS)


def js_literal(value):
    return json.dumps(value, ensure_ascii=False)


class Fastlane:
    """持有单条 CDP 长连接，四层与批量动作都在同一连接上执行。"""

    def __init__(self, host="127.0.0.1", port=9222, timeout=15.0,
                 target=None, url_contains=None):
        lib = load_cdp_module()
        self.client = lib.CDPClient(host=host, port=port, timeout=timeout)
        # 浏览器刚启动时页面 target 可能正在重建，有限重连三次即可稳定
        last_error = None
        for attempt in range(3):
            try:
                page = self.client.ensure_page(target=target, url_contains=url_contains)
                self.target_id = page.get("id")
                self.client.send("Page.enable")
                self.client.send("Runtime.enable")
                last_error = None
                break
            except Exception as exc:
                last_error = exc
                self.client.close()
                time.sleep(0.3 * (attempt + 1))
        if last_error is not None:
            raise FastlaneError("CDP 页面连接未就绪（重试 3 次）：%s" % last_error)
        self._snapshot_url = None

    def close(self):
        self.client.close()

    def js(self, expression, await_promise=False, timeout=None):
        result = self.client.send(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": bool(await_promise),
                "userGesture": True,
            },
            timeout=timeout,
        )
        details = result.get("exceptionDetails")
        if details:
            desc = (details.get("exception") or {}).get("description") or details.get("text")
            raise FastlaneError("JS 异常：%s" % desc)
        return result.get("result", {}).get("value")

    # ---------- 公共动作 ----------
    def navigate(self, url, timeout=20.0):
        if not self.client.navigate(url, timeout=timeout):
            raise FastlaneError("导航未就绪：%s" % url)
        self._snapshot_url = None  # 页面换了，ref 全部作废
        return {"url": self.js("location.href"), "title": self.js("document.title")}

    def sniff(self, url=None):
        if url:
            self.navigate(url)
        entries = self.js(SNIFF_EXPR) or []
        return {"count": len(entries), "requests": entries}

    def snapshot(self):
        nodes = self.js(SNAPSHOT_EXPR) or []
        self._snapshot_url = self.js("location.href")
        return {"count": len(nodes), "nodes": nodes, "ref_valid_at": self._snapshot_url}

    def verify(self, expression):
        if not expression:
            return True
        try:
            return bool(self.js(expression, timeout=3.0))
        except Exception:
            return False

    def wait(self, expression, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.verify(expression):
                return True
            time.sleep(0.05)
        return False

    def capture(self, ms=1500, trigger=None):
        """注入拦截器 → 可选触发一个动作 → 观察窗口 → 取回请求与响应。"""
        self.js(CAPTURE_INJECT_EXPR)
        triggered = None
        if trigger:
            triggered = self.act(trigger)
        time.sleep(max(0.0, ms) / 1000.0)
        entries = self.js(CAPTURE_READ_EXPR) or []
        return {"count": len(entries), "requests": entries,
                "window_ms": ms, "trigger": triggered}

    def probe(self, x, y):
        expr = PROBE_EXPR.replace("__X__", str(int(x))).replace("__Y__", str(int(y)))
        return self.js(expr)

    def press(self, key):
        code, k, c = KEYMAP.get(key, (0, key, key))
        for kind in ("keyDown", "keyUp"):
            self.client.send(
                "Input.dispatchKeyEvent",
                {"type": kind, "key": k, "code": c,
                 "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code},
                timeout=TIME_BUDGET["L3"],
            )
        return {"key": key}

    def scroll(self, dy):
        return self.js(SCROLL_EXPR.replace("__DY__", str(int(dy))),
                       timeout=TIME_BUDGET["L2"])

    def hover(self, x, y):
        self.client.send(
            "Input.dispatchMouseEvent",
            {"type": "mouseMoved", "x": int(x), "y": int(y),
             "button": "none", "clickCount": 0},
            timeout=TIME_BUDGET["L3"],
        )
        return {"x": int(x), "y": int(y)}

    # ---------- 定位 ----------
    def _locate_one(self, spec):
        by = spec.get("by")
        if by == "ref":
            if self._snapshot_url is None:
                raise FastlaneError("REF_STALE: 尚未 snapshot，ref 不可用")
            if self.js("location.href") != self._snapshot_url:
                raise FastlaneError("REF_STALE: 页面已跳转，ref 全部失效，请重新 snapshot")
            expr = REF_LOCATE_EXPR.replace("__N__", str(int(spec["value"])))
            hit = self.js(expr, timeout=TIME_BUDGET["L2"])
            if not hit or hit.get("count") != 1:
                raise FastlaneError("REF_STALE: ref %s 在当前 DOM 已不存在" % spec["value"])
        else:
            if not by or spec.get("value") is None:
                raise FastlaneError("locator 缺少 by 或 value")
            expr = LOCATE_EXPR.replace("__SPEC__", js_literal(spec))
            hit = self.js(expr, timeout=TIME_BUDGET["L2"])
            if not hit or hit.get("count") != 1:
                raise FastlaneError(
                    "定位命中 %s 个（要求恰好 1 个）：%s"
                    % ((hit or {}).get("count"), (hit or {}).get("preview"))
                )
        if hit.get("covered"):
            raise FastlaneError("元素被 %s 遮挡，拒绝操作" % hit.get("topTag"))
        if hit.get("disabled"):
            raise FastlaneError("元素处于 disabled 状态，拒绝操作")
        return hit

    def _locate(self, plan):
        loc = plan.get("locator")
        if not loc:
            return None
        by = (loc.get("by") or "auto").lower()
        if by != "auto":
            return self._locate_one(dict(loc, by=by))
        chain = []
        if loc.get("ref") is not None:
            chain.append({"by": "ref", "value": loc["ref"]})
        if loc.get("text"):
            chain.append({"by": "text", "value": loc["text"]})
        if loc.get("role"):
            chain.append({"by": "role", "value": loc["role"], "name": loc.get("name")})
        if loc.get("css"):
            chain.append({"by": "css", "value": loc["css"]})
        if not chain:
            raise FastlaneError("auto 定位链为空：请提供 ref / text / role / css 之一")
        errors = []
        for spec in chain:
            try:
                hit = self._locate_one(spec)
                hit["used"] = spec["by"]
                return hit
            except FastlaneError as exc:
                errors.append("%s:%s" % (spec["by"], str(exc)[:80]))
        raise FastlaneError("auto 定位链全部失败：" + " | ".join(errors))

    def _native_click(self, x, y, budget=None):
        budget = budget or TIME_BUDGET["L3"]
        for kind in ("mouseMoved", "mousePressed", "mouseReleased"):
            params = {
                "type": kind,
                "x": int(x),
                "y": int(y),
                "button": "none" if kind == "mouseMoved" else "left",
                "clickCount": 0 if kind == "mouseMoved" else 1,
            }
            self.client.send("Input.dispatchMouseEvent", params, timeout=budget)

    # ---------- 四层实现 ----------
    def _l1(self, plan):
        api = plan.get("api")
        if not api:
            return None
        headers = dict(api.get("headers") or {})
        # BODY 最后替换：避免请求体里出现的占位符字样被后续替换误伤
        expr = (
            API_EXPR
            .replace("__METHOD__", js_literal(api.get("method", "GET")))
            .replace("__HEADERS__", js_literal(headers))
            .replace("__URL__", js_literal(api.get("url")))
            .replace("__BODY__", js_literal(api.get("body")))
        )
        res = self.js(expr, await_promise=True, timeout=TIME_BUDGET["L1"])
        if not isinstance(res, dict):
            raise FastlaneError("L1 返回结构异常：%r" % (res,))
        status = res.get("status", 0)
        if not (200 <= status < 300):
            raise FastlaneError("L1 HTTP %s" % status)
        expect = api.get("expect")
        if expect and str(expect) not in str(res.get("body", "")):
            raise FastlaneError("L1 响应不含期望内容 %r" % expect)
        return {"status": status, "url": res.get("url"), "body": str(res.get("body", ""))[:500]}

    def _l2(self, plan):
        hit = self._locate(plan)
        if hit is None:
            return None
        action = plan.get("action", "click")
        if action == "click":
            expr = CLICK_EXPR
        elif action in ("fill", "select"):
            value = plan.get("value", plan.get("text", ""))
            expr = FILL_EXPR.replace("__TEXT__", js_literal(value))
        elif action == "read":
            expr = READ_EXPR
        else:
            raise FastlaneError("未知 action：%s" % action)
        out = self.js(expr, timeout=TIME_BUDGET["L2"])
        if isinstance(out, str) and out.startswith(("NOT_FOUND", "NOT_INPUT")):
            raise FastlaneError("L2 动作失败：%s" % out)
        return {"action": action, "hit": hit, "result": out}

    def _l3(self, plan):
        # 重新定位：L2 可能已滚动页面，坐标必须取当前视口值
        hit = self._locate(plan)
        if hit is None:
            return None
        x, y = hit["x"], hit["y"]
        self._native_click(x, y)
        action = plan.get("action", "click")
        if action in ("fill", "select"):
            value = str(plan.get("value", plan.get("text", "")))
            self.client.send("Input.insertText", {"text": value},
                             timeout=TIME_BUDGET["L3"])
            if plan.get("enter"):
                self.press("Enter")
        return {"action": action, "x": x, "y": y, "hit": hit}

    def _l4(self, plan, shot=None):
        vis = plan.get("vision")
        if not vis:
            return None
        x, y = int(vis["x"]), int(vis["y"])
        guard_expr = (
            VISION_GUARD_EXPR
            .replace("__X__", str(x))
            .replace("__Y__", str(y))
        )
        guard = self.js(guard_expr, timeout=3.0) or {}
        if not guard.get("allowed"):
            raise FastlaneError("L4 守卫拒绝：%s" % guard.get("reason"))
        saved = None
        if shot:
            data = self.client.send(
                "Page.captureScreenshot", {"format": "png"},
                timeout=TIME_BUDGET["L4"],
            ).get("data")
            if data:
                out = Path(shot).expanduser()
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(base64.b64decode(data))
                saved = str(out)
        self._native_click(x, y, budget=TIME_BUDGET["L4"])
        return {"x": x, "y": y, "guard": guard, "shot": saved}

    # ---------- 单向降级编排 ----------
    def act(self, plan, start="L1", shot=None):
        order = LAYERS[LAYERS.index(start):]
        attempts = []
        handlers = {
            "L1": lambda: self._l1(plan),
            "L2": lambda: self._l2(plan),
            "L3": lambda: self._l3(plan),
            "L4": lambda: self._l4(plan, shot),
        }
        for layer in order:
            t0 = time.perf_counter()
            record = {"layer": layer}
            try:
                detail = handlers[layer]()
                if detail is None:
                    record.update({"ok": False, "reason": "not_applicable"})
                elif self.verify(plan.get("verify")):
                    record.update({"ok": True, "reason": "verified", "detail": detail})
                else:
                    record.update({"ok": False, "reason": "verify_failed", "detail": detail})
            except Exception as exc:
                record.update({
                    "ok": False,
                    "reason": "error",
                    "error": "%s: %s" % (type(exc).__name__, str(exc)[:240]),
                })
            record["elapsed_ms"] = round((time.perf_counter() - t0) * 1000, 1)
            attempts.append(record)
            if record["ok"]:
                break
        succeeded = bool(attempts and attempts[-1]["ok"])
        return {
            "name": plan.get("name"),
            "ok": succeeded,
            "layer": attempts[-1]["layer"] if succeeded else None,
            "elapsed_ms": round(sum(a["elapsed_ms"] for a in attempts), 1),
            "verified": bool(plan.get("verify")),
            "attempts": attempts,
        }


def execute_step(fl, step, start="L1", shot=None):
    """批量执行的一步：四层动作与辅助 op 混排，共用同一条连接。"""
    op = step.get("op")
    if op is None or op in ACTION_ALIAS:
        plan = dict(step)
        if op in ACTION_ALIAS:
            plan["action"] = ACTION_ALIAS[op]
        return fl.act(plan, start=start, shot=shot)
    if op == "goto":
        return {"ok": True, "op": op, "layer": "L2", **fl.navigate(step["url"])}
    if op == "snapshot":
        return {"ok": True, "op": op, "layer": "L2", **fl.snapshot()}
    if op == "wait":
        return {"ok": fl.wait(step["expr"], float(step.get("timeout", 5.0))),
                "op": op, "layer": "L2"}
    if op == "sleep":
        time.sleep(float(step.get("seconds", 0.2)))
        return {"ok": True, "op": op, "layer": "L2"}
    if op == "eval":
        return {"ok": True, "op": op, "layer": "L2", "value": fl.js(step["expr"])}
    if op == "press":
        return {"ok": True, "op": op, "layer": "L3", **fl.press(step["key"])}
    if op == "scroll":
        return {"ok": True, "op": op, "layer": "L2", **fl.scroll(int(step.get("dy", 700)))}
    if op == "hover":
        hit = fl._locate(step) or {}
        if not hit.get("x"):
            raise FastlaneError("hover 需要 locator 提供坐标")
        return {"ok": True, "op": op, "layer": "L3", **fl.hover(hit["x"], hit["y"])}
    if op == "capture":
        return {"ok": True, "op": op, "layer": "L1",
                **fl.capture(int(step.get("ms", 300)), step.get("trigger"))}
    if op == "probe":
        return {"ok": True, "op": op, "layer": "L4",
                "probe": fl.probe(int(step["x"]), int(step["y"]))}
    raise FastlaneError("未知 op：%s" % op)


def cmd_doctor(args):
    out = {
        "ok": True,
        "python": platform.python_version(),
        "cdp_lib": str(CDP_LIB),
        "cdp_lib_exists": CDP_LIB.is_file(),
        "version": "fastlane 2.0",
    }
    if not CDP_LIB.is_file():
        out.update({"ok": False, "error": "缺少 CDP 传输层"})
        return out
    client = load_cdp_module().CDPClient(host=args.host, port=args.port, timeout=5)
    try:
        info = client.version()
        out.update({
            "cdp_alive": True,
            "browser": info.get("Browser"),
            "pages": len(client.list_pages()),
        })
    except Exception as exc:
        out.update({"ok": False, "cdp_alive": False, "error": str(exc)[:240]})
    return out


def read_json(path, label):
    p = Path(path).expanduser()
    if not p.is_file():
        raise FastlaneError("%s 不存在：%s" % (label, p))
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise FastlaneError("%s 不是合法 JSON：%s" % (label, exc))


def build_parser():
    parser = argparse.ArgumentParser(
        prog="fastlane.py",
        description="浏览器操作四层加速编排器 v2（ref 快照 / 语义定位 / 原生输入 / Canvas 兜底）",
    )
    parser.add_argument("--host", default="127.0.0.1", help="CDP 主机")
    parser.add_argument("--port", type=int, default=9222, help="CDP 端口，默认 9222")
    parser.add_argument("--target", help="指定标签页 targetId")
    parser.add_argument("--url-contains", help="按 URL 关键字挑选标签页")
    parser.add_argument("--timeout", type=float, default=15.0, help="CDP 单命令默认超时秒数")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="环境自检")
    p = sub.add_parser("navigate", help="打开页面")
    p.add_argument("--url", required=True)
    p = sub.add_parser("sniff", help="发现页面调用过的接口")
    p.add_argument("--url", help="可选：先导航到该地址")
    sub.add_parser("snapshot", help="输出带 ref 的可访问性快照")
    p = sub.add_parser("capture", help="抓真实请求（含请求体与响应体）")
    p.add_argument("--ms", type=int, default=1500, help="观察窗口毫秒数")
    p.add_argument("--trigger", help="可选：触发动作的 plan.json")
    p = sub.add_parser("probe", help="反查某坐标上的元素")
    p.add_argument("--x", type=int, required=True)
    p.add_argument("--y", type=int, required=True)
    p = sub.add_parser("act", help="执行一个动作，自动降级")
    p.add_argument("--plan", required=True, help="plan.json 路径")
    p.add_argument("--start", choices=LAYERS, default="L1")
    p.add_argument("--shot", help="L4 时把截图保存到该路径")
    p = sub.add_parser("batch", help="多个步骤共用一条长连接")
    p.add_argument("--plans", required=True, help="steps.json 路径（数组）")
    p.add_argument("--start", choices=LAYERS, default="L1")
    return parser


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    args = build_parser().parse_args(argv)
    try:
        if args.cmd == "doctor":
            result = cmd_doctor(args)
        else:
            fl = Fastlane(
                host=args.host, port=args.port, timeout=args.timeout,
                target=args.target, url_contains=args.url_contains,
            )
            try:
                if args.cmd == "navigate":
                    result = dict(ok=True, **fl.navigate(args.url))
                elif args.cmd == "sniff":
                    result = dict(ok=True, **fl.sniff(args.url))
                elif args.cmd == "snapshot":
                    result = dict(ok=True, **fl.snapshot())
                elif args.cmd == "capture":
                    trigger = read_json(args.trigger, "trigger") if args.trigger else None
                    result = dict(ok=True, **fl.capture(args.ms, trigger))
                elif args.cmd == "probe":
                    result = dict(ok=True, probe=fl.probe(args.x, args.y))
                elif args.cmd == "act":
                    result = fl.act(read_json(args.plan, "plan"), start=args.start, shot=args.shot)
                elif args.cmd == "batch":
                    steps = read_json(args.plans, "steps")
                    if not isinstance(steps, list):
                        raise FastlaneError("steps.json 必须是数组")
                    t0 = time.perf_counter()
                    results = []
                    for i, step in enumerate(steps, 1):
                        s0 = time.perf_counter()
                        try:
                            item = execute_step(fl, step, start=args.start)
                        except Exception as exc:
                            item = {"ok": False, "error": "%s: %s" % (type(exc).__name__, str(exc)[:240])}
                        item["step"] = i
                        item["step_ms"] = round((time.perf_counter() - s0) * 1000, 1)
                        results.append(item)
                        if not item.get("ok") and not step.get("continue"):
                            break
                    result = {
                        "ok": all(r.get("ok") for r in results) and len(results) == len(steps),
                        "count": len(results),
                        "elapsed_ms": round((time.perf_counter() - t0) * 1000, 1),
                        "results": results,
                    }
                else:
                    raise FastlaneError("未知命令：%s" % args.cmd)
            finally:
                fl.close()
    except Exception as exc:
        print(json.dumps(
            {"ok": False, "error": "%s: %s" % (type(exc).__name__, str(exc)[:400])},
            ensure_ascii=False,
        ))
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") is not False else 1


if __name__ == "__main__":
    sys.exit(main())
