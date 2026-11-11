#!/usr/bin/env python3
"""网页版分项裁决逻辑的单元测试（无需浏览器）。

网页版把同步合并逻辑写在 index.html 的内联脚本里，直接测 HTML 不方便。
这里把 <script> 块抽出来，用 Node 在隔离沙箱里跑一遍 mergeRemote()，
验证与桌面端一致的三条语义：

1. 正文冲突且本地正在编辑 → 保护本地正文（用户不丢字）；
2. 状态冲突（回收站 / 置顶）→ 立刻跟随远端（回收站必须实时）；
3. 内容状态都一致 → 只对齐服务端权威时间戳（三端排序一致）。

运行：python3 web/test_web_merge.py
"""

import io
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))


def extract_script():
    s = io.open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    blocks = re.findall(r"<script[^>]*>(.*?)</script>", s, re.S)
    if not blocks:
        raise SystemExit("index.html 里找不到内联脚本")
    return "\n".join(blocks)


HARNESS = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
// 只取 mergeRemote 函数及其依赖，避免整页脚本依赖 DOM。
const start = src.indexOf('function mergeRemote(');
if (start < 0) { console.error('mergeRemote 未找到'); process.exit(2); }
// 找到函数结束（下一个顶层 function 定义之前）
const end = src.indexOf('\nfunction ', start + 10);
const fnSrc = src.slice(start, end > 0 ? end : undefined);
const mergeRemote = eval('(' + fnSrc.replace(/^function mergeRemote/, 'function') + ')');

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  PASS  ' + name + (detail ? '  ' + detail : '')); }
  else { fail++; console.log('  FAIL  ' + name + (detail ? '  ' + detail : '')); }
}

// 1) 正文冲突 + 本地正在编辑 → 保护本地正文
let local = { id: 'a', title: '本地标题', content: '本地正文',
              tags: ['x'], pinned: false, trashed: false, updatedAt: 100 };
let remote = { id: 'a', title: '远端标题', content: '远端正文',
               tags: ['x'], pinned: false, trashed: false, updatedAt: 200 };
let r = mergeRemote(local, remote);
check('正文冲突时本地正文被保护',
  r.note.content === '本地正文' && r.note.title === '本地标题',
  'content=' + JSON.stringify(r.note.content));

// 2) 状态冲突（远端移入回收站）→ 立刻跟随远端，正文保留本地
remote = { id: 'a', title: '远端标题', content: '远端正文',
           tags: ['x'], pinned: false, trashed: true, updatedAt: 300 };
r = mergeRemote(local, remote);
check('远端移入回收站时状态立刻跟随远端',
  r.note.trashed === true, 'trashed=' + r.note.trashed);
check('状态跟随远端时本地正文仍然保留',
  r.note.content === '本地正文', 'content=' + JSON.stringify(r.note.content));
check('状态跟随远端时采用远端权威时间戳',
  r.note.updatedAt === 300, 'updatedAt=' + r.note.updatedAt);

// 3) 远端恢复（trashed=false）同样立刻生效
local = Object.assign({}, r.note);
r = mergeRemote(local, { id: 'a', title: '本地标题', content: '本地正文',
                          tags: ['x'], pinned: false, trashed: false, updatedAt: 400 });
check('远端恢复时状态立刻跟随远端',
  r.note.trashed === false, 'trashed=' + r.note.trashed);

// 4) 置顶状态也必须实时
local = { id: 'b', title: 't', content: 'c', tags: [],
          pinned: false, trashed: false, updatedAt: 100 };
r = mergeRemote(local, { id: 'b', title: 't', content: 'c', tags: [],
                         pinned: true, trashed: false, updatedAt: 200 });
check('置顶状态实时跟随远端', r.note.pinned === true, 'pinned=' + r.note.pinned);

// 5) 内容与状态都一致 → 只对齐时间戳
local = { id: 'c', title: 't', content: 'c', tags: [],
          pinned: false, trashed: false, updatedAt: 100 };
r = mergeRemote(local, { id: 'c', title: 't', content: 'c', tags: [],
                         pinned: false, trashed: false, updatedAt: 500 });
check('内容一致时对齐服务端权威时间戳',
  r.note.updatedAt === 500 && r.changed === true, 'updatedAt=' + r.note.updatedAt);

// 6) 标签顺序不同不算内容变更
local = { id: 'd', title: 't', content: 'c', tags: ['a', 'b'],
          pinned: false, trashed: false, updatedAt: 100 };
r = mergeRemote(local, { id: 'd', title: 't', content: 'c', tags: ['b', 'a'],
                         pinned: false, trashed: false, updatedAt: 500 });
check('标签顺序不同不算变更（只对齐时间戳）',
  r.note.updatedAt === 500 && r.note.tags.join(',') === 'a,b',
  'tags=' + r.note.tags.join(','));

// 7) 本地不存在这条笔记 → 直接采用远端
r = mergeRemote(null, { id: 'e', title: '远端', content: 'x', tags: [],
                        pinned: false, trashed: false, updatedAt: 100 });
check('本地没有这条笔记时直接采用远端版本',
  r.note.title === '远端' && r.changed === true);

console.log('\n结论：' + (fail === 0 ? '全部通过（' + pass + ' 项）' : '存在失败项（' + fail + ' 项）'));
process.exit(fail === 0 ? 0 : 1);
"""


def main():
    src = extract_script()
    tmp = tempfile.mkdtemp(prefix="mynotes-webtest-")
    js_path = os.path.join(tmp, "app.js")
    io.open(js_path, "w", encoding="utf-8").write(src)
    harness_path = os.path.join(tmp, "harness.js")
    io.open(harness_path, "w", encoding="utf-8").write(HARNESS)

    try:
        r = subprocess.run(["node", harness_path, js_path],
                           capture_output=True, text=True, timeout=60)
        print(r.stdout)
        if r.stderr.strip():
            print(r.stderr)
        return r.returncode
    except FileNotFoundError:
        print("未找到 node，跳过网页版单元测试")
        return 0
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
