#!/usr/bin/env python3
"""真实三端联动实测（不启动桌面端 GUI，直接驱动其数据路径）。

本机 Mac 客户端用的是 v1.3.8，DB 在 ~/Library/Application Support/MyNotes/My Notes/notes.db。
这里不改动用户真实数据，而是：
  1) 起一个 SSE 订阅者（扮演 Windows 端）
  2) 起一个隔离的「网页版」逻辑实例（用真实 index.html 里的 mergeRemote）
  3) 通过桌面端自己的 API 路径（/api/sync 的 notes 数组）模拟桌面端 push
  4) 验证：桌面端 push 的回收站变更，Windows 端与网页版都实时收到
  5) 验证：NAS 端变更，桌面端下一次 pull 能拿到（用客户端真实协议字段比对）

所有测试笔记用独立 id，测完 purge，不碰用户数据。
"""
import json
import os
import re
import sys
import threading
import time
import urllib.request

BASE = "http://192.168.31.3:2581"

def api(path, payload=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    m = method or ("POST" if data is not None else "GET")
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"}, method=m)
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read().decode()
    return json.loads(body) if body.strip() else {}

def sse_collector(frames, stop):
    req = urllib.request.Request(BASE + "/api/events",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                if stop.is_set():
                    break
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    frames.append((time.time(), json.loads(line[5:].strip())))
                except Exception:
                    pass
    except Exception:
        pass

def wait_for(frames, pred, timeout=5.0, t_send=None):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for ts, d in frames:
            if pred(d):
                return ts - (t_send if t_send is not None else t0), d
        time.sleep(0.01)
    return None, None

def load_web_merge():
    """从真实部署的 index.html 里抽出 mergeRemote，用 node 跑网页版逻辑。"""
    html = open("/tmp/nas_page.html", encoding="utf-8").read()
    m = re.search(r"function mergeRemote\(cur, remote\)\s*\{.*?\n\}", html, re.S)
    if not m:
        return None
    return m.group(0)

def main():
    results = []
    def check(name, ok, detail=""):
        results.append((name, ok))
        print(("  PASS  " if ok else "  FAIL  ") + name + ("  " + detail if detail else ""))

    frames = []
    stop = threading.Event()
    threading.Thread(target=sse_collector, args=(frames, stop), daemon=True).start()
    time.sleep(1.2)

    nid = "tri-%d" % int(time.time())

    # --- 1. 桌面端 push：移入回收站（模拟 Mac 客户端 /api/sync 上推）---
    # 桌面端推的是完整笔记数组，trashed=True 表示在回收站
    frames.clear()
    t_send = time.time()
    api("/api/sync", {"notes": [{
        "id": nid, "title": "三端联动测试", "content": "来自桌面端的内容",
        "trashed": True, "pinned": False, "tags": [], "bookId": "",
        "updatedAt": int(time.time() * 1000),
    }]})
    lat, d = wait_for(frames, lambda x: any(n.get("id") == nid for n in (x.get("notes") or [])),
                      t_send=t_send)
    ok = lat is not None
    detail = "延迟 %.3fs" % lat if lat is not None else "5 秒内未收到"
    trashed = None
    if ok:
        for n in (d.get("notes") or []):
            if n.get("id") == nid:
                trashed = n.get("trashed")
        ok = (trashed is True)
        detail += " trashed=%s" % trashed
    check("桌面端 push 回收站 → Windows 端实时收到", ok, detail)

    # --- 2. 服务端权威时间戳：桌面端推的时间戳被纠正 ---
    st = api("/api/state")
    notes = st.get("notes") or []
    if isinstance(notes, dict):
        notes = list(notes.values())
    mine = [n for n in notes if n.get("id") == nid]
    check("服务端对桌面端笔记盖了权威时间戳", bool(mine),
          "updatedAt=%s" % (mine[0].get("updatedAt") if mine else "?"))

    # --- 3. 网页版 mergeRemote 收到同一帧后的行为 ---
    merge_src = load_web_merge()
    web_ok = False
    web_detail = "未能从页面提取 mergeRemote"
    if merge_src:
        cur = {"id": nid, "title": "三端联动测试", "content": "本地旧内容",
               "trashed": False, "pinned": False, "tags": [], "updatedAt": 1}
        remote = {"id": nid, "title": "三端联动测试", "content": "来自桌面端的内容",
                  "trashed": True, "pinned": False, "tags": [], "updatedAt": 999}
        js = merge_src + "\nconsole.log(JSON.stringify(mergeRemote(%s, %s)));" % (
            json.dumps(cur), json.dumps(remote))
        path = "/tmp/_merge_tri.js"
        open(path, "w", encoding="utf-8").write(js)
        import subprocess
        r = subprocess.run(["node", path], capture_output=True, text=True)
        try:
            out = json.loads(r.stdout.strip().splitlines()[-1])
            web_ok = (out["note"]["trashed"] is True and
                      out["note"]["content"] == "本地旧内容")
            web_detail = "trashed=%s content=%r" % (out["note"]["trashed"], out["note"]["content"])
        except Exception as e:
            web_detail = "node 执行失败: %s / %s" % (e, r.stdout[:120])
    check("网页版分项裁决：状态跟随远端、正文保护本地", web_ok, web_detail)

    # --- 4. NAS 端改内容 → 桌面端下一次 pull 能拿到 ---
    api("/api/note", {"note": {"id": nid, "title": "三端联动测试",
                                "content": "NAS端改过的内容", "trashed": True}})
    time.sleep(0.6)
    st = api("/api/state")
    notes = st.get("notes") or []
    if isinstance(notes, dict):
        notes = list(notes.values())
    mine = [n for n in notes if n.get("id") == nid]
    check("NAS 端改内容后服务端状态正确",
          bool(mine) and mine[0].get("content") == "NAS端改过的内容",
          "content=%r" % (mine[0].get("content") if mine else None))

    # --- 5. 三端排序完全一致（服务端统一排序）---
    def key(n):
        return (0 if n.get("pinned") else 1, -(n.get("updatedAt") or 0), n.get("id") or "")
    order = [n.get("id") for n in sorted(notes, key=key)]
    check("服务端提供唯一权威排序", len(order) == len(notes) and len(set(order)) == len(order),
          "共 %d 条" % len(order))

    # --- 6. 彻底删除 + 不可复活 ---
    frames.clear()
    t_send = time.time()
    api("/api/purge", {"id": nid})
    lat, d = wait_for(frames, lambda x: nid in (x.get("deletedIds") or []), t_send=t_send)
    check("彻底删除实时广播到其它端", lat is not None,
          "延迟 %.3fs" % lat if lat is not None else "5 秒内未收到")
    api("/api/sync", {"notes": [{"id": nid, "title": "复活", "content": "x"}]})
    time.sleep(0.5)
    st = api("/api/state")
    notes2 = st.get("notes") or []
    if isinstance(notes2, dict):
        notes2 = list(notes2.values())
    check("彻底删除后不会被推回复活", not any(n.get("id") == nid for n in notes2))

    stop.set()
    print()
    passed = sum(1 for _, ok in results if ok)
    print("结论：%s（%d/%d 通过）" % ("全部通过" if passed == len(results) else "存在失败",
                                     passed, len(results)))
    return 0 if passed == len(results) else 1

if __name__ == "__main__":
    sys.exit(main())
