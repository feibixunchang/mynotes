#!/usr/bin/env python3
"""端到端回归：删除事件独立 SSE 通道。

起一个**隔离**的真实 server.py（独立 DATA_DIR / 随机端口），模拟三端订阅，
再从 A 端发起彻底删除，验证：

1. hello 帧携带当前全部删除墓碑（重连补偿）；
2. 删除广播里带 deletedIds，所有订阅者 1 秒内收到；
3. unchanged 兜底通道仍带 deletedIds（SSE 断线时 30 秒轮询能补上）；
4. /api/purge 也广播删除，而 /api/delete（移入回收站）不广播删除。

只用 127.0.0.1 与临时目录，不触碰任何真实笔记数据。
运行：python3 web/test_realtime_sync.py
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import shutil

ROOT = os.path.dirname(os.path.abspath(__file__))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class SseClient:
    """最小 SSE 订阅者：逐行读 data: 帧，记录 (到达时间, 载荷)。"""

    def __init__(self, port, label):
        self.label = label
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.sock.settimeout(8)
        req = (
            "GET /api/events HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Accept: text/event-stream\r\n"
            "Connection: keep-alive\r\n\r\n" % port
        )
        self.sock.sendall(req.encode())
        self.f = self.sock.makefile("rb")
        while True:                       # 跳过响应头
            line = self.f.readline()
            if line in (b"\r\n", b"\n", b""):
                break
        self.frames = []
        self.alive = True
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        while self.alive:
            try:
                line = self.f.readline()
            except (socket.timeout, OSError):
                continue                  # 20s 心跳之间允许超时后继续等
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if text.startswith("data: "):
                try:
                    self.frames.append((time.time(), json.loads(text[6:])))
                except Exception:
                    pass

    def wait_for(self, pred, timeout=2.0, since=0):
        end = time.time() + timeout
        while time.time() < end:
            for ts, d in list(self.frames[since:]):
                if pred(d):
                    return ts, d
            time.sleep(0.01)
        return None, None

    def cursor(self):
        return len(self.frames)

    def close(self):
        self.alive = False
        try:
            self.sock.close()
        except Exception:
            pass


def main():
    port = free_port()
    tmp = tempfile.mkdtemp(prefix="mynotes-e2e-")
    env = dict(os.environ, DATA_DIR=tmp, PORT=str(port), SYNC_TOKEN="")
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "server.py")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    clients = []
    ok = True

    def api(path, data=None):
        url = "http://127.0.0.1:%d%s" % (port, path)
        if data is None:
            r = urllib.request.urlopen(url, timeout=5)
        else:
            req = urllib.request.Request(
                url, data=json.dumps(data).encode(),
                headers={"Content-Type": "application/json"}, method="POST")
            r = urllib.request.urlopen(req, timeout=5)
        return json.loads(r.read())

    def check(name, cond, detail=""):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("  " + detail if detail else ""))
        if not cond:
            ok = False

    try:
        health = None
        for _ in range(50):
            try:
                health = api("/health")
                break
            except Exception:
                time.sleep(0.1)
        check("隔离服务端启动", health is not None)
        if health is None:
            return 1
        check("服务端版本为 1.3.8", health.get("version") == "1.3.8",
              "version=%s build=%s" % (health.get("version"), health.get("build")))

        a = SseClient(port, "Windows")
        clients.append(a)
        b = SseClient(port, "网页版")
        clients.append(b)
        c = SseClient(port, "macOS")
        clients.append(c)
        for cl in clients:
            ts, d = cl.wait_for(lambda x: "deletedIds" in x, timeout=2)
            check("%s 收到 hello 且带 deletedIds 字段" % cl.label,
                  d is not None and isinstance(d.get("deletedIds"), list),
                  "rev=%s" % (d or {}).get("rev"))

        def note(nid, title):
            return {"id": nid, "title": title, "content": "e2e " + nid,
                    "tags": [], "pinned": False, "trashed": False,
                    "createdAt": 1, "updatedAt": int(time.time() * 1000)}

        n1, n2, n3 = note("e2e-1", "一"), note("e2e-2", "二"), note("e2e-3", "三")
        api("/api/sync", {"notes": [n1, n2, n3], "deletedIds": []})
        state0 = api("/api/state")
        check("三条笔记已写入", len(state0["notes"]) == 3,
              "rev=%d" % state0["rev"])

        # ---- 核心：A 端彻底删除 n1 ----
        cursors = [cl.cursor() for cl in clients]
        t0 = time.time()
        res = api("/api/sync", {"notes": [], "deletedIds": [n1["id"]]})
        check("删除被服务端确认", n1["id"] in res.get("deletedApplied", []),
              "deletedApplied=%s" % res.get("deletedApplied"))
        for cl, cur in zip(clients, cursors):
            ts, d = cl.wait_for(
                lambda x, i=n1["id"]: i in (x.get("deletedIds") or []),
                timeout=2.0, since=cur)
            if ts is None:
                check("%s 1 秒内收到删除广播" % cl.label, False, "超时未收到")
            else:
                delay = ts - t0
                check("%s 1 秒内收到删除广播" % cl.label, delay < 1.0,
                      "延迟 %.3fs rev=%s" % (delay, d.get("rev")))

        rev = api("/health")["rev"]
        st = api("/api/state?since=%d" % rev)
        check("unchanged 兜底仍带 deletedIds",
              st.get("unchanged") is True and n1["id"] in st.get("deletedIds", []),
              "deletedIds 共 %d 条" % len(st.get("deletedIds", [])))
        full = api("/api/state")
        check("全量快照已不含被删笔记",
              n1["id"] not in [x["id"] for x in full["notes"]])

        # ---- /api/purge 也要广播删除 ----
        cursors = [cl.cursor() for cl in clients]
        api("/api/purge", {"id": n2["id"]})
        for cl, cur in zip(clients, cursors):
            ts, d = cl.wait_for(
                lambda x, i=n2["id"]: i in (x.get("deletedIds") or []),
                timeout=2.0, since=cur)
            check("%s purge 也广播删除" % cl.label, ts is not None)

        # ---- /api/delete 只是移入回收站，不能误报彻底删除 ----
        cursors = [cl.cursor() for cl in clients]
        api("/api/delete", {"id": n3["id"]})
        time.sleep(0.3)
        for cl, cur in zip(clients, cursors):
            frames = [d for _, d in cl.frames[cur:]]
            check("%s 移入回收站不广播 deletedIds" % cl.label,
                  bool(frames) and all(not (d.get("deletedIds") or []) for d in frames),
                  "收到 %d 帧" % len(frames))

        print("\n结论：%s" % ("全部通过" if ok else "存在失败项"))
        return 0 if ok else 1
    finally:
        for cl in clients:
            cl.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
