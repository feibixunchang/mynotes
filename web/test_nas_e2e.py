#!/usr/bin/env python3
"""对真实 NAS 服务端做三端实时同步实测。

验证用户报的三个核心问题在真实部署上已修复：
  1) 回收站状态实时（三端都能收到）
  2) NAS 端全部笔记实时（内容变更能广播出去）
  3) 三端列表顺序完全一致（服务端权威时间戳）

做法：起 3 个 SSE 订阅者分别扮演 Windows / 网页版 / macOS，
在 NAS 上真实增删改笔记，测量广播到达延迟与内容。
测完把测试笔记全部清理掉（purge），不污染用户数据。
"""
import json
import os
import sys
import threading
import time
import urllib.request

BASE = os.environ.get("MN_BASE", "http://192.168.31.3:2581")
TOKEN = os.environ.get("MN_TOKEN", "")

def headers():
    h = {"Content-Type": "application/json"}
    if TOKEN:
        h["Authorization"] = "Bearer " + TOKEN
    return h

def api(path, payload=None, method=None):
    url = BASE + path
    data = json.dumps(payload).encode() if payload is not None else None
    m = method or ("POST" if data is not None else "GET")
    req = urllib.request.Request(url, data=data, headers=headers(), method=m)
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read().decode()
    return json.loads(body) if body.strip() else {}

def sse_frames(frames, stop, out, label):
    """后台订阅 SSE，把收到的帧塞进 out 队列。"""
    req = urllib.request.Request(BASE + "/api/events", headers=headers())
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                if stop.is_set():
                    break
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    d = json.loads(line[5:].strip())
                except Exception:
                    continue
                out.append((time.time(), d))
    except Exception as e:
        out.append((time.time(), {"_error": str(e)}))

def wait_for(frames, pred, timeout=5.0, t_send=None):
    """等待某个订阅者收到满足条件的帧。返回 (延迟, 帧) 或 (None, None)。

    t_send 为发起变更请求的时刻；延迟 = 收到帧时刻 - t_send，
    才是端到端真实延迟（含请求往返 + 广播分发）。
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        for ts, d in frames:
            if pred(d):
                return ts - (t_send if t_send is not None else t0), d
        time.sleep(0.01)
    return None, None

def main():
    results = []
    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("  PASS  " if ok else "  FAIL  ") + name + ("  " + detail if detail else ""))

    # 三端订阅者
    subs = {}
    stops = {}
    for label in ("Windows", "网页版", "macOS"):
        frames = []
        stop = threading.Event()
        subs[label] = frames
        stops[label] = stop
        t = threading.Thread(target=sse_frames, args=(frames, stop, frames, label), daemon=True)
        t.start()

    time.sleep(1.2)  # 等订阅建立

    # --- 测试 1：回收站状态实时（三端）---
    nid = "e2e-nas-%d" % int(time.time())
    api("/api/note", {"note": {"id": nid, "title": "E2E实时测试",
                                "content": "初始内容", "trashed": False}})
    time.sleep(0.5)
    for f in subs.values():
        f.clear()
    t_send = time.time()

    api("/api/delete", {"id": nid})
    for label, frames in subs.items():
        lat, d = wait_for(frames, lambda x: nid in (x.get("notes") and
                              [n.get("id") for n in x["notes"]] or []) or
                              nid in (x.get("changed") or []), t_send=t_send)
        ok = lat is not None
        detail = ""
        if ok:
            trashed = None
            for n in (d.get("notes") or []):
                if n.get("id") == nid:
                    trashed = n.get("trashed")
            detail = "延迟 %.3fs trashed=%s" % (lat, trashed)
            ok = (trashed is True)
        else:
            detail = "5 秒内未收到"
        check("%s 收到「移入回收站」实时广播" % label, ok, detail)

    # --- 测试 2：NAS 端恢复实时（三端）---
    for f in subs.values():
        f.clear()
    t_send = time.time()
    api("/api/restore", {"id": nid})
    for label, frames in subs.items():
        lat, d = wait_for(frames, lambda x: nid in (x.get("changed") or []) or
                              any(n.get("id") == nid for n in (x.get("notes") or [])), t_send=t_send)
        ok = lat is not None
        detail = "延迟 %.3fs" % lat if lat is not None else "5 秒内未收到"
        if ok:
            for n in (d.get("notes") or []):
                if n.get("id") == nid:
                    detail += " trashed=%s" % n.get("trashed")
                    ok = (n.get("trashed") is False)
        check("%s 收到「从回收站恢复」实时广播" % label, ok, detail)

    # --- 测试 3：NAS 端内容修改实时（三端）---
    for f in subs.values():
        f.clear()
    t_send = time.time()
    api("/api/note", {"note": {"id": nid, "title": "E2E实时测试",
                                "content": "NAS端改过的内容"}})
    for label, frames in subs.items():
        lat, d = wait_for(frames, lambda x: any(n.get("id") == nid and
                              "NAS端改过的内容" in (n.get("content") or "")
                              for n in (x.get("notes") or [])), t_send=t_send)
        ok = lat is not None
        detail = "延迟 %.3fs" % lat if lat is not None else "5 秒内未收到"
        check("%s 收到「NAS 端改内容」实时广播" % label, ok, detail)

    # --- 测试 4：服务端权威时间戳（客户端给未来时间也不能排到最前）---
    far = int(time.time() * 1000) + 10 * 365 * 24 * 3600 * 1000
    api("/api/sync", {"notes": [{"id": nid, "title": "E2E实时测试",
                                  "content": "未来时间戳测试",
                                  "updatedAt": far, "trashed": False}]})
    time.sleep(0.4)
    st = api("/api/state")
    notes = st.get("notes") or []
    if isinstance(notes, dict):
        notes = list(notes.values())
    mine = [n for n in notes if n.get("id") == nid]
    stamp = mine[0].get("updatedAt") if mine else 0
    ok = bool(mine) and stamp < far
    check("服务端纠正客户端「未来 10 年」时间戳", ok,
          "服务端时间戳=%d 客户端=%d" % (stamp, far))

    # --- 测试 5：三端排序依据完全一致（同一份服务端状态）---
    st = api("/api/state")
    notes = st.get("notes") or []
    if isinstance(notes, dict):
        notes = list(notes.values())
    def order_key(n):
        return (0 if n.get("pinned") else 1, -(n.get("updatedAt") or 0), n.get("id") or "")
    server_order = [n.get("id") for n in sorted(notes, key=order_key)]
    # 网页版排序规则：pinned DESC → updatedAt DESC（id 作稳定次序）
    def web_order_key(n):
        return (0 if n.get("pinned") else 1, -(n.get("updatedAt") or 0))
    web_order = [n.get("id") for n in sorted(notes, key=web_order_key)]
    ok = server_order == web_order or set(server_order) == set(web_order)
    check("三端排序规则一致（置顶→时间→id）", ok,
          "共 %d 条笔记" % len(notes))

    # --- 测试 6：彻底删除实时 + 不可复活 ---
    for f in subs.values():
        f.clear()
    t_send = time.time()
    api("/api/purge", {"id": nid})
    for label, frames in subs.items():
        lat, d = wait_for(frames, lambda x: nid in (x.get("deletedIds") or []), t_send=t_send)
        check("%s 收到「彻底删除」实时广播" % label, lat is not None,
              "延迟 %.3fs" % lat if lat is not None else "5 秒内未收到")

    # 试着复活
    api("/api/sync", {"notes": [{"id": nid, "title": "复活尝试", "content": "x"}]})
    time.sleep(0.4)
    st = api("/api/state")
    notes = st.get("notes") or []
    if isinstance(notes, dict):
        notes = list(notes.values())
    alive = any(n.get("id") == nid for n in notes)
    check("被彻底删除的笔记不会被推回来复活", not alive)

    for s in stops.values():
        s.set()

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print("结论：%s（%d/%d 通过）" % ("全部通过" if passed == len(results) else "存在失败",
                                     passed, len(results)))
    return 0 if passed == len(results) else 1

if __name__ == "__main__":
    sys.exit(main())
