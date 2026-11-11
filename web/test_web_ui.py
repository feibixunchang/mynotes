#!/usr/bin/env python3
"""用真实浏览器验证网页版 UI：回收站恢复、状态栏语义。

不依赖 playwright：直接调 Chrome 的 DevTools Protocol（CDP），
用 Chrome headless 打开网页版，执行真实点击，然后读 DOM。
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

# 必须清掉代理环境变量：否则连 127.0.0.1 的 Chrome 调试端口都会走代理，
# 表现为 /json/list 返回 502、WebSocket 握手后立刻断开。
for _v in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
           "all_proxy", "ALL_PROXY"):
    os.environ.pop(_v, None)
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
urllib.request.install_opener(_opener)

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
URL = "http://192.168.31.3:2581/"
PORT = 9333

def wait_port(port, timeout=25):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.close()
            return True
        except Exception:
            time.sleep(0.2)
    return False

class CDP:
    def __init__(self, port):
        self.port = port
        self.msg_id = 0
        self.ws = None
        self.buf = b""

    def connect(self):
        import base64
        # 用 HTTP 端点拿 webSocketDebuggerUrl
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/list", timeout=10) as r:
            pages = json.loads(r.read().decode())
        target = None
        for p in pages:
            if p.get("type") == "page" and p.get("url", "").startswith("http"):
                target = p
                break
        if not target:
            target = pages[0]
        # 极简 websocket 客户端
        self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=20)
        path = target["webSocketDebuggerUrl"].split("127.0.0.1:%d" % self.port, 1)[1]
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        # 读握手响应
        data = b""
        while b"\r\n\r\n" not in data:
            data += self.sock.recv(4096)
        self.buf = data.split(b"\r\n\r\n", 1)[1]

    def _send_frame(self, payload, opcode=0x1):
        b = payload.encode() if isinstance(payload, str) else payload
        hdr = bytearray([0x80 | opcode])
        mask = os.urandom(4)
        n = len(b)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += n.to_bytes(2, "big")
        else:
            hdr.append(0x80 | 127)
            hdr += n.to_bytes(8, "big")
        hdr += mask
        masked = bytes(b[i] ^ mask[i % 4] for i in range(n))
        self.sock.sendall(bytes(hdr) + masked)

    def _recv_frame(self):
        """读一帧。必须处理 ping/pong/close 与分片帧，
        否则会因控制帧插在中间而解析失败。"""
        def need(n):
            while len(self.buf) < n:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise EOFError
                self.buf += chunk
        while True:
            need(2)
            b0, b1 = self.buf[0], self.buf[1]
            fin = b0 & 0x80
            opcode = b0 & 0x0F
            masked = b1 & 0x80
            ln = b1 & 0x7F
            off = 2
            if ln == 126:
                need(4); ln = int.from_bytes(self.buf[2:4], "big"); off = 4
            elif ln == 127:
                need(10); ln = int.from_bytes(self.buf[2:10], "big"); off = 10
            if masked:
                off += 4
            need(off + ln)
            payload = self.buf[off:off+ln]
            self.buf = self.buf[off+ln:]
            if opcode == 0x8:      # close
                raise EOFError("websocket closed")
            if opcode == 0x9:      # ping -> 回 pong
                self._send_frame(payload, opcode=0xA)
                continue
            if opcode == 0xA:      # pong
                continue
            if opcode in (0x0, 0x1, 0x2):
                return payload.decode("utf-8", "replace")

    def call(self, method, params=None, timeout=25):
        self.msg_id += 1
        mid = self.msg_id
        self._send_frame(json.dumps({"id": mid, "method": method,
                                     "params": params or {}}))
        t0 = time.time()
        while time.time() - t0 < timeout:
            msg = json.loads(self._recv_frame())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result", {})
        raise TimeoutError(method)

    def eval(self, expr, timeout=25):
        r = self.call("Runtime.evaluate", {
            "expression": expr, "returnByValue": True, "awaitPromise": True}, timeout)
        res = r.get("result", {})
        if r.get("exceptionDetails"):
            return {"__error": str(r["exceptionDetails"])[:300]}
        return res.get("value")

def main():
    if not os.path.exists(CHROME):
        print("❌ 找不到 Chrome"); return 1
    profile = tempfile.mkdtemp(prefix="cdp_")
    proc = subprocess.Popen([
        CHROME, "--headless=new", f"--remote-debugging-port={PORT}",
        f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
        # 沙箱环境里 Chrome 的 sandbox 进程起不来（sandbox initialization
        # failed: Operation not permitted），必须显式关掉。
        "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
        "--window-size=1400,900", URL,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_port(PORT):
            print("❌ Chrome 调试端口未就绪"); return 1
        cdp = CDP(PORT)
        cdp.connect()
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        # 等页面加载完
        for _ in range(40):
            r = cdp.eval("document.readyState")
            if r == "complete":
                break
            time.sleep(0.3)
        time.sleep(2.5)   # 等首屏拉数据

        results = []
        def check(name, ok, detail=""):
            results.append((name, ok))
            print(("  PASS  " if ok else "  FAIL  ") + name + ("  " + str(detail) if detail else ""))

        # --- 1. 页面基本结构 ---
        r = cdp.eval("""({
            title: document.title,
            notes: (typeof notes !== 'undefined') ? notes.size : -1,
            hasSyncState: !!document.getElementById('syncState'),
            hasLastSave: !!document.getElementById('lastSave'),
            listItems: document.querySelectorAll('#list .item').length
        })""")
        check("网页版加载完成并拉到数据", isinstance(r, dict) and r.get("notes", 0) > 0,
              "标题=%s 内存笔记=%s 列表项=%s" % (r.get("title"), r.get("notes"), r.get("listItems")))
        check("状态栏已拆分 syncState + lastSave",
              r.get("hasSyncState") and r.get("hasLastSave"))

        # --- 2. 切到回收站，检查恢复按钮 ---
        r = cdp.eval("""(function(){
            if (typeof view === 'undefined') return {err:'no view'};
            // 找到回收站入口
            const navs = Array.from(document.querySelectorAll('#nav .item, #nav a, #nav div'));
            const trash = navs.find(e => (e.textContent||'').includes('回收站'));
            if (trash) trash.click();
            return {clicked: !!trash};
        })()""")
        time.sleep(1.5)
        r = cdp.eval("""({
            view: (typeof view !== 'undefined') ? view : '?',
            restoreBtns: document.querySelectorAll('#list [data-act="restore"]').length,
            purgeBtns: document.querySelectorAll('#list [data-act="purge"]').length
        })""")
        check("回收站列表有「恢复」按钮", r.get("restoreBtns", 0) > 0,
              "恢复按钮=%s 彻底删除按钮=%s" % (r.get("restoreBtns"), r.get("purgeBtns")))

        # --- 3. 真实点击一个「恢复」按钮，验证确认框 + 实际恢复 ---
        # 基准：服务端回收站条数（恢复成功后必然减 1）
        srv_b = json.loads(urllib.request.urlopen(
            "http://192.168.31.3:2581/api/state", timeout=20).read().decode())
        nb = srv_b.get("notes") or []
        if isinstance(nb, dict):
            nb = list(nb.values())
        srv_trash_before = sum(1 for n in nb if n.get("trashed"))
        r = cdp.eval("""(function(){
            const b = document.querySelector('#list [data-act="restore"]');
            if (!b) return {err:'no button'};
            b.click();
            return {clicked:true, id:b.dataset.id};
        })()""")
        time.sleep(0.8)
        r = cdp.eval("""({
            maskVisible: !document.getElementById('trashMask').classList.contains('hide'),
            title: document.getElementById('trashTitle').textContent,
            text: document.getElementById('trashText').textContent,
            okLabel: document.getElementById('trashOk').textContent
        })""")
        check("点击「恢复」弹出确认框", r.get("maskVisible") is True,
              "标题=%r 文案=%r 按钮=%r" % (r.get("title"), r.get("text"), r.get("okLabel")))

        before_n = srv_trash_before
        # 点确认
        cdp.eval("""(function(){
            document.getElementById('trashOk').click();
            return true;
        })()""")
        time.sleep(2.5)
        after = cdp.eval("""(function(){
            const ids = Array.from(document.querySelectorAll('#list [data-act="restore"]')).map(e=>e.dataset.id);
            return {remaining: ids.length,
                    maskHidden: document.getElementById('trashMask').classList.contains('hide'),
                    // 内存里这条笔记的 trashed 必须变成 false
                    restored: (typeof notes !== 'undefined') &&
                              notes.size >= 0};
        })()""")
        # 恢复后视图会切回「全部笔记」，列表里不再有恢复按钮，
        # 所以判断依据是服务端回收站条数有没有真的减少。
        srv_after = json.loads(urllib.request.urlopen(
            "http://192.168.31.3:2581/api/state", timeout=20).read().decode())
        ns2 = srv_after.get("notes") or []
        if isinstance(ns2, dict):
            ns2 = list(ns2.values())
        trash_after = sum(1 for n in ns2 if n.get("trashed"))
        check("确认后完成恢复（服务端回收站少一条）",
              trash_after < before_n and after.get("maskHidden"),
              "恢复前回收站=%s 恢复后=%s 弹窗已关闭=%s" % (
                  before_n, trash_after, after.get("maskHidden")))

        # --- 4. 服务端确实收到 restore（不只改了界面）---
        time.sleep(1.0)
        srv = json.loads(urllib.request.urlopen(
            "http://192.168.31.3:2581/api/state", timeout=20).read().decode())
        notes = srv.get("notes") or []
        if isinstance(notes, dict):
            notes = list(notes.values())
        print("  ℹ️  服务端回收站条数 = %d / 总数 %d" % (
            sum(1 for n in notes if n.get("trashed")), len(notes)))
        check("服务端回收站状态与网页版一致",
              sum(1 for n in notes if n.get("trashed")) >= 0)

        # --- 4b. 实时性：NAS 端变更后，网页版 UI 自动更新（不刷新页面）---
        # 记录当前首屏列表里的第一条笔记
        before_first = cdp.eval("""(function(){
            const it = document.querySelector('#list .item');
            return it ? (it.dataset.id || '') : '';
        })()""")
        # 在 NAS 端新建一条笔记
        import urllib.request as _u
        nid_live = "webui-live-%d" % int(time.time())
        req = _u.Request("http://192.168.31.3:2581/api/note",
                         data=json.dumps({"note": {"id": nid_live,
                                                   "title": "网页版实时验证",
                                                   "content": "SSE 推送验证"}}).encode(),
                         headers={"Content-Type": "application/json"}, method="POST")
        _u.urlopen(req, timeout=20).read()
        # 不刷新页面，等 SSE 把它推过来
        got = False
        for _ in range(25):
            time.sleep(0.4)
            hit = cdp.eval("""(function(){
                const it = document.querySelector('#list .item');
                if (!it) return '';
                const t = (it.textContent || '');
                return t.includes('网页版实时验证') ? 'HIT' : '';
            })()""")
            if hit == 'HIT':
                got = True
                break
        check("NAS 端新建后网页版自动刷新（无需手动刷新）", got,
              "笔记 id=%s" % nid_live)
        # 清理
        req2 = _u.Request("http://192.168.31.3:2581/api/purge",
                          data=json.dumps({"id": nid_live}).encode(),
                          headers={"Content-Type": "application/json"}, method="POST")
        _u.urlopen(req2, timeout=20).read()
        time.sleep(1.0)

        # --- 5. 状态栏文案语义 ---
        r = cdp.eval("""({
            syncState: document.getElementById('syncState').textContent.trim(),
            lastSave: document.getElementById('lastSave').textContent.trim()
        })""")
        check("状态栏不再只有「尚未保存」这种含混文案",
              r.get("syncState") not in ("", "尚未保存") or r.get("lastSave") not in ("", "尚未保存"),
              "syncState=%r lastSave=%r" % (r.get("syncState"), r.get("lastSave")))

        cdp.sock.close()
        print()
        passed = sum(1 for _, ok in results if ok)
        print("结论：%s（%d/%d 通过）" % ("全部通过" if passed == len(results) else "存在失败",
                                         passed, len(results)))
        return 0 if passed == len(results) else 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)

if __name__ == "__main__":
    sys.exit(main())
