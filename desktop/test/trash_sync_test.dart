import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/db.dart';
import 'package:my_notes/pages/settings_page.dart';
import 'package:my_notes/sync.dart';

/// 回归测试：回收站里的笔记「彻底删除 / 清空」后不能被同步重新拉回。
/// 用 NotesDb.testDataDirOverride 强制写入临时目录：即使直接执行
/// `flutter test`，也绝不会碰到真实笔记库或改掉同步设置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('mynotes-test-');
    NotesDb.testDataDirOverride = tmpDir.path;
    await NotesDb.init();
  });
  tearDownAll(() {
    NotesDb.testDataDirOverride = null;
    // Windows 上 SQLite 仍持有临时库的文件句柄，删除目录可能抛
    // PathAccessException；清理失败不影响测试结论，交给系统临时目录回收。
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('旧服务端仍持有已删除笔记时，pull 不会把它插回本地', () async {
    final note = await NotesDb.createNote(null);
    note.title = '待彻底删除';
    note.body = '回归测试内容';
    await NotesDb.updateNote(note);
    await NotesDb.softDelete(note.id);

    // 模拟旧版 NAS 服务端：/api/sync 不认识 deletedIds，
    // /api/state 仍会把这条已删除的笔记发给客户端。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/state') {
        req.response.write(jsonEncode({
          'rev': 7,
          'epoch': 0,
          'notes': [
            {
              'id': note.id,
              'title': '待彻底删除',
              'content': '回归测试内容',
              'trashed': true,
              'updatedAt': note.updatedAt,
            }
          ],
        }));
      } else {
        // 旧服务端：返回结果里没有 deletedApplied 字段
        req.response
            .write(jsonEncode({'ok': true, 'rev': 7, 'changed': 0, 'count': 1}));
      }
      await req.response.close();
    });

    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');

    await NotesDb.purge(note.id);
    expect(await NotesDb.getNote(note.id), isNull, reason: '本地应先删掉');
    expect((await NotesDb.tombstones()).containsKey(note.id), isTrue,
        reason: 'purge 必须留下墓碑');

    await SyncService.i.pull();
    expect(await NotesDb.getNote(note.id), isNull,
        reason: '墓碑必须挡住旧服务端回填，否则用户会看到「删不掉」');

    await server.close(force: true);
  });

  test('清空回收站会返回全部被删 id 并逐个留下墓碑', () async {
    final a = await NotesDb.createNote(null);
    final b = await NotesDb.createNote(null);
    await NotesDb.softDelete(a.id);
    await NotesDb.softDelete(b.id);

    final ids = await NotesDb.clearTrash();
    expect(ids.toSet(), {a.id, b.id});
    final tombs = await NotesDb.tombstones();
    expect(tombs.containsKey(a.id), isTrue);
    expect(tombs.containsKey(b.id), isTrue);
    expect(await NotesDb.listNotes(null, trash: true), isEmpty);
  });
}
