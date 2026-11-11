#!/usr/bin/env python3
"""v1.3.9 端到端回归：服务端权威时间戳 / 回收站实时 / 三端排序一致。

起一个**隔离**的真实 server.py（独立 DATA_DIR / 随机端口），模拟三端订阅，
验证本次修复的三个根因在服务端层面彻底修好：

1. **服务端权威时间戳**：客户端推的时间戳一律不采信，服务端自己裁决，
   并通过 stamps 回传。客户端时钟偏差再大也不会让真实修改被静默丢弃，
   三端最终持有同一套时间戳 → 列表顺序完全一致。
2. **回收站实时**：`/api/delete`（移入回收站）与 `/api/restore`（恢复）
   都会立刻广播，且广播帧里带笔记全文与 trashed 状态，
   其它端收到同一帧就能落地，不必反查 /api/state。
3. **墓碑不可复活**：被彻底删除的笔记，任何客户端再推回来都不会复活。

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
        check("服务端版本为 1.3.9", health.get("version") == "1.3.9",
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

        def note(nid, title, ts=None):
            return {"id": nid, "title": title, "content": "e2e " + nid,
                    "tags": [], "pinned": False, "trashed": False,
                    "createdAt": 1,
                    "updatedAt": ts if ts is not None else int(time.time() * 1000)}

        # ================================================================
        # 1. 服务端权威时间戳
        # ================================================================
        print("\n[1] 服务端权威时间戳")
        # 客户端 A 推一条笔记，但时间戳故意给成「未来 10 年」——
        # 旧逻辑会采信它，导致这条笔记在三端排序里永远排第一。
        far_future = int(time.time() * 1000) + 365 * 24 * 3600 * 1000
        n1 = note("e2e-1", "一", ts=far_future)
        res = api("/api/sync", {"notes": [n1], "deletedIds": []})
        stamps = res.get("stamps") or {}
        check("push 响应回传 stamps", n1["id"] in stamps, "stamps=%s" % stamps)
        check("服务端不采信客户端未来时间戳",
              stamps.get(n1["id"], 0) < far_future,
              "stamp=%s 客户端给的=%s" % (stamps.get(n1["id"]), far_future))

        state0 = api("/api/state")
        stored = [x for x in state0["notes"] if x["id"] == n1["id"]]
        check("服务端时间戳是服务端自己的时间",
              bool(stored) and abs(stored[0]["updatedAt"] - int(time.time() * 1000)) < 60000,
              "stored=%s" % (stored[0]["updatedAt"] if stored else None))

        # 客户端 B 推同一条笔记，内容相同 → 服务端应回传已有权威时间戳，
        # 两端据此对齐，排序才能完全一致。
        res_b = api("/api/sync", {"notes": [note("e2e-1", "一")], "deletedIds": []})
        stamps_b = res_b.get("stamps") or {}
        check("内容相同时回传同一权威时间戳",
              stamps_b.get(n1["id"]) == stamps.get(n1["id"]),
              "%s vs %s" % (stamps_b.get(n1["id"]), stamps.get(n1["id"])))

        # 内容变化 → 服务端盖新的、严格递增的时间戳
        n1b = note("e2e-1", "一改", ts=1)          # 客户端时间戳故意给很旧
        res_c = api("/api/sync", {"notes": [n1b], "deletedIds": []})
        stamp_c = (res_c.get("stamps") or {}).get(n1["id"])
        check("内容变化后时间戳严格递增",
              stamp_c is not None and stamp_c > stamps.get(n1["id"], 0),
              "%s > %s" % (stamp_c, stamps.get(n1["id"])))

        # 标签顺序不同不算变更（否则笔记会在列表里反复跳动）
        res_d = api("/api/sync", {"notes": [
            {"id": "e2e-tag", "title": "标签", "content": "x", "tags": ["a", "b"],
             "pinned": False, "trashed": False, "createdAt": 1,
             "updatedAt": int(time.time() * 1000)}], "deletedIds": []})
        stamp_tag = (res_d.get("stamps") or {}).get("e2e-tag")
        res_e = api("/api/sync", {"notes": [
            {"id": "e2e-tag", "title": "标签", "content": "x", "tags": ["b", "a"],
             "pinned": False, "trashed": False, "createdAt": 1,
             "updatedAt": int(time.time() * 1000)}], "deletedIds": []})
        check("标签顺序不同不产生新时间戳",
              (res_e.get("stamps") or {}).get("e2e-tag") == stamp_tag,
              "%s vs %s" % ((res_e.get("stamps") or {}).get("e2e-tag"), stamp_tag))

        # ================================================================
        # 2. 回收站实时
        # ================================================================
        print("\n[2] 回收站实时同步")
        n2 = note("e2e-2", "二")
        n3 = note("e2e-3", "三")
        api("/api/sync", {"notes": [n2, n3], "deletedIds": []})

        cursors = [cl.cursor() for cl in clients]
        t0 = time.time()
        api("/api/delete", {"id": n2["id"]})
        for cl, cur in zip(clients, cursors):
            ts, d = cl.wait_for(
                lambda x, i=n2["id"]: any(
                    (nt or {}).get("id") == i and (nt or {}).get("trashed") is True
                    for nt in (x.get("notes") or [])),
                timeout=2.0, since=cur)
            if ts is None:
                check("%s 移入回收站实时收到（含 trashed 状态）" % cl.label, False,
                      "超时未收到")
            else:
                delay = ts - t0
                check("%s 移入回收站实时收到（含 trashed 状态）" % cl.label,
                      delay < 1.0, "延迟 %.3fs rev=%s" % (delay, d.get("rev")))

        # 恢复也要实时
        cursors = [cl.cursor() for cl in clients]
        api("/api/restore", {"id": n2["id"]})
        for cl, cur in zip(clients, cursors):
            ts, d = cl.wait_for(
                lambda x, i=n2["id"]: any(
                    (nt or {}).get("id") == i and (nt or {}).get("trashed") is False
                    for nt in (x.get("notes") or [])),
                timeout=2.0, since=cur)
            check("%s 恢复实时收到" % cl.label, ts is not None,
                  "rev=%s" % (d or {}).get("rev"))

        # 移入回收站不能误报成彻底删除
        cursors = [cl.cursor() for cl in clients]
        api("/api/delete", {"id": n3["id"]})
        time.sleep(0.3)
        for cl, cur in zip(clients, cursors):
            frames = [d for _, d in cl.frames[cur:]]
            check("%s 移入回收站不广播 deletedIds" % cl.label,
                  bool(frames) and all(not (d.get("deletedIds") or []) for d in frames),
                  "收到 %d 帧" % len(frames))

        # ================================================================
        # 3. 删除事件独立 SSE 通道（原有回归）
        # ================================================================
        print("\n[3] 彻底删除的独立广播通道")
        cursors = [cl.cursor() for cl in clients]
        t0 = time.time()
        res = api("/api/sync", {"notes": [], "deletedIds": [n2["id"]]})
        check("删除被服务端确认", n2["id"] in res.get("deletedApplied", []),
              "deletedApplied=%s" % res.get("deletedApplied"))
        for cl, cur in zip(clients, cursors):
            ts, d = cl.wait_for(
                lambda x, i=n2["id"]: i in (x.get("deletedIds") or []),
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
              st.get("unchanged") is True and n2["id"] in st.get("deletedIds", []),
              "deletedIds 共 %d 条" % len(st.get("deletedIds", [])))
        full = api("/api/state")
        check("全量快照已不含被删笔记",
              n2["id"] not in [x["id"] for x in full["notes"]])

        # ================================================================
        # 4. 墓碑不可复活
        # ================================================================
        print("\n[4] 被彻底删除的笔记不会被客户端推回来复活")
        api("/api/purge", {"id": n3["id"]})
        time.sleep(0.2)
        api("/api/sync", {"notes": [note("e2e-3", "三")], "deletedIds": []})
        full = api("/api/state")
        check("墓碑笔记未被复活",
              "e2e-3" not in [x["id"] for x in full["notes"]],
              "现存 %d 条" % len(full["notes"]))

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
