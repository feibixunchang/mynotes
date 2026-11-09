#!/usr/bin/env python3
"""隐私自查：确认仓库里没有混入笔记数据或私密配置。"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAD_NAMES = {
    'notes.db', 'settings.txt', 'state.json', 'sync.log', 'tray.log',
    'FangZhengSongHei.ttf',
}
BAD_DIRS = {'notes-data', '__pycache__'}
BAD_SUFFIX = ('.db', '.db-journal', '.ttf', '.otf')
# 用通用模式检测，检查器本身不携带任何具体地址或令牌
PRIVATE_PREFIXES = ('http://192.', 'http://10.', 'http://172.')
SECRET_MARKERS = ('x-access-token:', 'bearer g')

problems = []
for dp, ds, fs in os.walk(ROOT):
    ds[:] = [d for d in ds if d not in ('.git', '.dart_tool', 'build')]
    for d in ds:
        if d in BAD_DIRS or d.lower().startswith('backup'):
            problems.append('目录 ' + os.path.relpath(os.path.join(dp, d), ROOT))
    for f in fs:
        rel = os.path.relpath(os.path.join(dp, f), ROOT)
        low = f.lower()
        if f in BAD_NAMES or low.endswith(BAD_SUFFIX) or 'deserialized' in low:
            problems.append('文件 ' + rel)
        if f == os.path.basename(__file__):
            continue
        try:
            s = open(os.path.join(dp, f), 'rb').read().decode('utf-8', 'ignore')
        except OSError:
            continue
        low_s = s.lower()
        if any(x in low_s for x in PRIVATE_PREFIXES + SECRET_MARKERS):
            problems.append('敏感串命中 ' + rel)

if problems:
    print('FAIL - 发现 %d 项：' % len(problems))
    for p in problems[:30]:
        print('  ' + p)
    sys.exit(1)
print('PASS - 未发现笔记数据或私密配置')
