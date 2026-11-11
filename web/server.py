#!/usr/bin/env python3
# 我的笔记 · NAS 网页版 v3 (stdlib only)
#
# 这是一个"完整可用的网页版笔记应用"：既提供 Web UI，也提供桌面端同步接口。
#   GET  /                     -> 网页版应用（内嵌方正宋黑）
#   GET  /font.ttf             -> 方正宋黑字体
#   GET  /favicon.ico          -> 站点图标
#   GET  /health               -> 健康检查
#   GET  /api/state?since=REV  -> 全量/增量状态
#   GET  /api/export.md        -> 导出全部笔记为 Markdown
#   GET  /api/events           -> SSE 实时同步
#   GET  /attach/<name>        -> 网页版上传的附件图片
#   POST /api/sync             -> 桌面端批量合并
#   POST /api/note             -> 新建/更新单条
#   POST /api/delete           -> 删除到回收站
#   POST /api/restore          -> 从回收站还原
#   POST /api/purge            -> 彻底删除
#   POST /api/upload           -> 网页版上传图片（raw body + X-File-Name）
#   POST /api/clear            -> 一键清空所有笔记（本地+NAS 同步）
#
# 局域网内默认免令牌：未设置 SYNC_TOKEN 时所有接口开放。
# 若设置 SYNC_TOKEN，则支持 Authorization: Bearer <token> 或 ?token=<token>。

import os
import re
import json
import time
import mimetypes
import threading
import tempfile
import queue
from urllib.parse import urlparse, parse_qs, unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("DATA_DIR", "/data")
TOKEN = os.environ.get("SYNC_TOKEN", "")
PORT = int(os.environ.get("PORT", "8000"))
APP_VERSION = "1.3.9"
BUILD_STAMP = "2026-11-11 13:05"
STATE = os.path.join(DATA_DIR, "state.json")
LEGACY = os.path.join(DATA_DIR, "snapshot.json")
MD_DIR = os.path.join(DATA_DIR, "md")
ATTACH_DIR = os.path.join(DATA_DIR, "attachments")
LOCK = threading.Lock()
SUBS = []
# 单条 SSE 帧最多携带多少条变更笔记全文；超过就只发 partial 标记，
# 客户端收到后自行做一次全量拉取，避免批量导入时单帧过大阻塞事件通道。
MAX_EVENT_NOTES = 60
# 判断一条笔记是否真的变了：以前只比 title/content/trashed，
# 置顶、标签、笔记本变化不会广播，三端列表也就永远对不上。
COMPARE_FIELDS = ("title", "content", "trashed", "pinned", "tags", "bookId")


def same_tags(a, b):
    """标签按集合比较：两端保存的标签顺序可能不同，内容相同就不该算变更。

    否则每次 push 都会被判成「有差异」→ 服务端盖新时间戳 → 广播 →
    其它端再拉回来，笔记会在列表里反复跳动。
    """
    if not isinstance(a, list) or not isinstance(b, list):
        return a == b
    return sorted(str(x) for x in a) == sorted(str(x) for x in b)

_state = {"rev": 0, "notes": {}, "updatedAt": 0, "epoch": 0, "deleted": {}}
APP_DIR = os.path.dirname(os.path.abspath(__file__))


def _now():
    return int(time.time() * 1000)


def atomic_write(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except Exception:
            pass
        raise


def load_state():
    global _state
    if os.path.exists(STATE):
        try:
            with open(STATE, encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict) and isinstance(d.get("notes"), dict):
                d.setdefault("epoch", 0)
                d.setdefault("deleted", {})
                _state = d
                return
            # 兼容 state.json 里 notes 为数组的旧格式
            if isinstance(d, dict) and isinstance(d.get("notes"), list):
                _state = {"rev": int(d.get("rev") or 1),
                          "notes": {n["id"]: n for n in d["notes"] if isinstance(n, dict) and n.get("id")},
                          "updatedAt": _now(),
                          "epoch": int(d.get("epoch") or 0),
                          "deleted": d.get("deleted") or {}}
                save_state()
                return
        except Exception:
            pass
    notes = {}
    if os.path.exists(LEGACY):
        try:
            with open(LEGACY, encoding="utf-8") as f:
                old = json.load(f)
            for n in old.get("notes", []):
                if isinstance(n, dict) and n.get("id"):
                    notes[n["id"]] = n
        except Exception:
            pass
    _state = {"rev": 1, "notes": notes, "updatedAt": _now(), "epoch": 0, "deleted": {}}
    save_state()


def save_state():
    atomic_write(STATE, _state)
    try:
        write_md_mirror()
    except Exception:
        pass


def write_md_mirror():
    os.makedirs(MD_DIR, exist_ok=True)
    for fn in os.listdir(MD_DIR):
        if fn.endswith(".md"):
            try:
                os.remove(os.path.join(MD_DIR, fn))
            except Exception:
                pass
    for i, n in enumerate(_state["notes"].values()):
        t = (n.get("title") or "").strip().replace("\n", " ")[:40]
        for ch in '\\/:*?"<>|\r\n\t':
            t = t.replace(ch, "_")
        name = (t or "untitled") + "_" + str(i) + ".md"
        with open(os.path.join(MD_DIR, name), "w", encoding="utf-8") as f:
            f.write(n.get("content") or n.get("title") or "")


def bump(changed, deleted=None):
    """推进 rev，并把「变更笔记全文 + 永久删除 id」随事件一次性广播。

    以前广播里 changed 只是 id 列表，客户端必须再反查
    /api/state?since=rev。这条反查链路会被 unchanged 短路、pull 撞车、
    rev 对齐等任一环节丢事件，表现为「移入回收站 / 改内容很久才同步」。
    现在数据随事件直接下发：客户端收到同一帧即可落地，实时性不再依赖反查。
    """
    _state["rev"] = int(_state.get("rev", 0)) + 1
    _state["updatedAt"] = _now()
    save_state()
    ids = list(dict.fromkeys(str(x) for x in (changed or [])))
    partial = len(ids) > MAX_EVENT_NOTES
    notes = [] if partial else [_state["notes"][i] for i in ids
                                if i in _state["notes"]]
    msg = json.dumps({
        "rev": _state["rev"],
        "epoch": int(_state.get("epoch", 0)),
        "changed": ids,
        "notes": notes,
        "deletedIds": [str(x) for x in (deleted or [])],
        "partial": partial,
    }, ensure_ascii=False)
    for q in list(SUBS):
        try:
            q.put_nowait(msg)
        except Exception:
            pass


def merge_notes(items):
    """合并客户端上推的笔记。

    时间戳必须由服务端裁决，不能直接采信客户端的 updatedAt：
    两台机器的系统时钟只要有几秒偏差，「客户端时间戳更新」就会把
    另一端的真实修改判成过期而静默丢弃 —— 表现为「某一端怎么改，
    其它端都不动」「三端列表顺序还不一样」。
    这里改成：内容有实质变化就接受，并统一盖上服务端权威时间戳。
    这样三端最终持有完全相同的时间戳，列表顺序也就完全一致。
    """
    changed = []
    stamps = {}
    now = _now()
    for n in items:
        if not isinstance(n, dict) or not n.get("id"):
            continue
        old = _state["notes"].get(n["id"])
        new_up = int(n.get("updatedAt") or 0)
        # 已被永久删除的笔记，任何客户端再推回来都不能复活。
        # 这里不再拿客户端时间戳做比较：两台机器时钟只要有偏差，
        # 就会出现「删掉的笔记又冒出来」或「删不掉」。
        if n["id"] in _state.get("deleted", {}):
            continue
        if old is None:
            n = dict(n)
            # 服务端权威时间戳：完全不采信客户端的 updatedAt。
            # 客户端时钟只要超前，采信它就会把这条笔记排到所有笔记最前面，
            # 三端排序从此错乱。新笔记一律盖服务端当前时间。
            n["updatedAt"] = now
            _state["notes"][n["id"]] = n
            changed.append(n["id"])
            stamps[n["id"]] = n["updatedAt"]
            continue
        # 内容实质变化才接受。updatedAt 不参与比较：它正是时钟漂移的来源。
        differs = False
        for k in COMPARE_FIELDS:
            if k == "tags":
                if not same_tags(old.get("tags"), n.get("tags")):
                    differs = True
                    break
            elif old.get(k) != n.get(k):
                differs = True
                break
        if not differs:
            # 内容一致：仍然回传服务端已有的权威时间戳，客户端据此把本地
            # 时间戳对齐，三端排序才能完全一样。
            stamps[n["id"]] = int(old.get("updatedAt") or 0)
            continue
        n = dict(n)
        n["updatedAt"] = max(now, int(old.get("updatedAt") or 0) + 1)
        _state["notes"][n["id"]] = n
        changed.append(n["id"])
        stamps[n["id"]] = n["updatedAt"]
    return changed, stamps


def safe_name(name):
    name = os.path.basename(unquote(name or ""))
    name = re.sub(r"[^A-Za-z0-9._\-\u4e00-\u9fff]", "_", name)
    return name[:120] or "upload.bin"


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MyNotesWeb/3.0"

    def log_message(self, fmt, *a):
        pass

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _bytes(self, code, raw, ctype, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(raw)

    def _authed(self):
        if not TOKEN:
            return True
        got = self.headers.get("Authorization", "")
        if got == "Bearer " + TOKEN:
            return True
        q = parse_qs(urlparse(self.path).query)
        return q.get("token", [""])[0] == TOKEN

    def _body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                line = self.rfile.readline().strip()
                try:
                    size = int(line.split(b";")[0], 16)
                except Exception:
                    break
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        try:
            ln = int(self.headers.get("Content-Length", "0"))
        except Exception:
            ln = 0
        return self.rfile.read(ln) if ln else b""

    def _static(self, name, ctype, binary=False, cache="no-store"):
        p = os.path.join(APP_DIR, name)
        if not os.path.exists(p):
            return self._json(404, {"ok": False, "error": "missing " + name})
        mode = "rb" if binary else "r"
        kw = {} if binary else {"encoding": "utf-8"}
        with open(p, mode, **kw) as f:
            data = f.read()
        if not binary:
            data = data.encode("utf-8")
        return self._bytes(200, data, ctype, cache)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            return self._json(200, {"ok": True, "ts": _now(), "rev": _state["rev"],
                                   "app": "我的笔记 NAS 网页版", "auth": bool(TOKEN),
                                   "version": APP_VERSION, "build": BUILD_STAMP,
                                   "epoch": _state.get("epoch", 0)})
        # 页面与静态资源一律免令牌（页面本身不含数据）
        if u.path in ("/", "/index.html"):
            return self._static("index.html", "text/html; charset=utf-8")
        if u.path == "/font.ttf":
            return self._static("FangZhengSongHei.ttf", "font/ttf", True, "public, max-age=86400")
        if u.path == "/favicon.ico":
            return self._static("favicon.ico", "image/x-icon", True, "public, max-age=86400")
        if u.path.startswith("/attach/"):
            name = safe_name(u.path[len("/attach/"):])
            p = os.path.join(ATTACH_DIR, name)
            if not os.path.isfile(p):
                return self._json(404, {"ok": False, "error": "not found"})
            ctype = mimetypes.guess_type(p)[0] or "application/octet-stream"
            with open(p, "rb") as f:
                return self._bytes(200, f.read(), ctype, "public, max-age=86400")
        if not self._authed():
            return self._json(401, {"ok": False, "error": "unauthorized"})
        if u.path == "/api/state":
            q = parse_qs(u.query)
            try:
                since = int(q.get("since", ["-1"])[0])
            except Exception:
                since = -1
            with LOCK:
                cutoff = _now() - 365 * 24 * 3600 * 1000
                deleted = {k: v for k, v in _state.get("deleted", {}).items()
                           if v > cutoff}
                if since >= 0 and since == _state["rev"]:
                    # 笔记没变不等于没有删除：删除墓碑仍要随 unchanged 下发。
                    # 否则另一端要等下一次任意笔记变更（rev 再 +1）才能看到
                    # 「已被彻底删除」，表现为删除很久才同步。
                    return self._json(200, {"rev": _state["rev"],
                                            "epoch": _state.get("epoch", 0),
                                            "notes": [],
                                            "unchanged": True,
                                            "deletedIds": list(deleted.keys()),
                                            "deletedAt": deleted})
                return self._json(200, {"rev": _state["rev"],
                                        "epoch": _state.get("epoch", 0),
                                        "notes": list(_state["notes"].values()),
                                        "deletedIds": list(deleted.keys()),
                                        "deletedAt": deleted})
        if u.path == "/api/export.md":
            with LOCK:
                parts = ["# 我的笔记（NAS 导出）\n"]
                for n in sorted(_state["notes"].values(),
                                key=lambda x: -(int(x.get("updatedAt") or 0))):
                    parts.append("\n## %s\n\n%s\n" % (n.get("title") or "(无标题)",
                                                       n.get("content") or ""))
            out = "".join(parts).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="my-notes.md"')
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if u.path == "/api/events":
            q = queue.Queue()
            with LOCK:
                SUBS.append(q)
                rev = _state["rev"]
                cutoff = _now() - 365 * 24 * 3600 * 1000
                tombs = [k for k, v in _state.get("deleted", {}).items()
                         if v > cutoff]
                # hello 带上全部删除墓碑 + partial 标记：断线重连的客户端
                # 可立即补偿期间漏掉的删除，并做一次全量拉取补齐断线期间的
                # 内容/回收站变更，不必等下一次 rev 变化或 30 秒轮询。
                hello = json.dumps({
                    "rev": rev,
                    "epoch": int(_state.get("epoch", 0)),
                    "deletedIds": tombs,
                    "changed": [],
                    "notes": [],
                    "partial": True,
                    "hello": True,
                }, ensure_ascii=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            # 反代（nginx 等）默认会缓冲 SSE，导致事件不实时下发。
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            try:
                self.wfile.write(("event: hello\ndata: %s\n\n" % hello).encode())
                self.wfile.flush()
                while True:
                    try:
                        msg = q.get(timeout=20)
                        self.wfile.write(("data: %s\n\n" % msg).encode())
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                try:
                    SUBS.remove(q)
                except Exception:
                    pass
            return
        return self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self._authed():
            return self._json(401, {"ok": False, "error": "unauthorized"})
        u = urlparse(self.path)
        raw = self._body()

        if u.path == "/api/upload":
            name = safe_name(self.headers.get("X-File-Name", "image.png"))
            ext = os.path.splitext(name)[1].lower()
            if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg"):
                return self._json(400, {"ok": False, "error": "unsupported image type"})
            if not raw or len(raw) > 20 * 1024 * 1024:
                return self._json(400, {"ok": False, "error": "empty or too large (>20MB)"})
            os.makedirs(ATTACH_DIR, exist_ok=True)
            # 加时间戳前缀避免重名覆盖
            fname = str(_now()) + "_" + name
            with open(os.path.join(ATTACH_DIR, fname), "wb") as f:
                f.write(raw)
            return self._json(200, {"ok": True, "url": "/attach/" + fname})

        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception as e:
            return self._json(400, {"ok": False, "error": "bad json: %s" % e})
        if u.path == "/api/clear":
            # 一键删除所有笔记：清空服务端并递增 epoch，桌面端 pull 时据此同步清空本地
            with LOCK:
                now = _now()
                ids = list(_state["notes"].keys())
                for nid in ids:
                    _state.setdefault("deleted", {})[nid] = now
                _state["notes"] = {}
                _state["epoch"] = int(_state.get("epoch", 0)) + 1
                bump([], ids)
            return self._json(200, {"ok": True, "rev": _state["rev"],
                                    "epoch": _state["epoch"]})

        if u.path == "/api/sync":
            items = data.get("notes")
            if not isinstance(items, list):
                return self._json(400, {"ok": False, "error": "notes must be list"})
            deleted_ids = [x for x in (data.get("deletedIds") or [])
                           if isinstance(x, str)]
            deleted_at = data.get("deletedAt")
            if not isinstance(deleted_at, dict):
                deleted_at = {}
            with LOCK:
                now = _now()
                removed = []
                for nid in deleted_ids:
                    ts = int(deleted_at.get(nid) or now)
                    if nid in _state["notes"] or ts > int(
                            _state.get("deleted", {}).get(nid) or 0):
                        _state["notes"].pop(nid, None)
                        _state.setdefault("deleted", {})[nid] = ts
                        removed.append(nid)
                cutoff = now - 365 * 24 * 3600 * 1000
                _state["deleted"] = {
                    k: v for k, v in _state.get("deleted", {}).items()
                    if v > cutoff}
                changed, stamps = merge_notes(items)
                if changed or removed:
                    bump(changed + removed, removed)
                else:
                    save_state()
            return self._json(200, {"ok": True, "rev": _state["rev"],
                                    "changed": len(changed),
                                    "deletedApplied": removed,
                                    # 服务端权威时间戳：客户端据此对齐本地时间戳，
                                    # 三端列表顺序才会完全一致。
                                    "stamps": stamps,
                                    "count": len(_state["notes"])})
        if u.path == "/api/note":
            note = data.get("note")
            if not isinstance(note, dict) or not note.get("id"):
                return self._json(400, {"ok": False, "error": "need note.id"})
            with LOCK:
                changed, stamps = merge_notes([note])
                if changed:
                    bump(changed)
                else:
                    save_state()
            return self._json(200, {"ok": True, "rev": _state["rev"],
                                    "stamps": stamps})
        if u.path in ("/api/delete", "/api/restore", "/api/purge"):
            nid = data.get("id")
            with LOCK:
                if u.path == "/api/purge":
                    _state["notes"].pop(nid, None)
                    _state.setdefault("deleted", {})[nid] = _now()
                    stamps = {}
                else:
                    note = _state["notes"].get(nid)
                    if not note:
                        return self._json(404, {"ok": False, "error": "not found"})
                    note["trashed"] = (u.path == "/api/delete")
                    note["updatedAt"] = max(_now(),
                                            int(note.get("updatedAt") or 0) + 1)
                    _state["notes"][nid] = note
                    stamps = {nid: note["updatedAt"]}
                # 只有 /api/purge 是彻底删除；/api/delete 只是移入回收站。
                # 软删除 / 恢复同样立刻广播，回收站才能三端实时。
                bump([nid], [nid] if u.path == "/api/purge" else [])
            return self._json(200, {"ok": True, "rev": _state["rev"],
                                    "stamps": stamps})
        return self._json(404, {"ok": False, "error": "not found"})


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(ATTACH_DIR, exist_ok=True)
    load_state()
    print("我的笔记 NAS 网页版 v3 on %d, %d notes, rev=%d, auth=%s"
          % (PORT, len(_state["notes"]), _state["rev"], "on" if TOKEN else "off"),
          flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
