import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/db.dart';
import 'package:my_notes/pages/settings_page.dart';
import 'package:my_notes/sync.dart';

/// 回归测试：回收站里的笔记「彻底删除 / 清空」后不能被同步重新拉回，
/// 以及「另一端删除」必须能实时传到本端。
/// 用 NotesDb.testDataDirOverride 强制写入临时目录：即使直接执行
/// `flutter test`，也绝不会碰到真实笔记库或改掉同步设置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('mynotes-test-');
    NotesDb.testDataDirOverride = tmpDir.path;
    await NotesDb.init();
    // flutter_test 默认装上 HttpOverrides，让所有 HttpClient 请求直接返回 400。
    // 本文件要连自己起的本地 mock server，必须恢复真实网络实现，否则测试
    // 会变成「请求根本没发出」的假阳性。
    HttpOverrides.global = null;
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
    var reached = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      reached = true;
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
    expect(reached, isTrue, reason: 'mock 服务端必须真的收到过请求');
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

  test('push 不推进 rev，随后的 pull 仍能收到远端删除', () async {
    final note = await NotesDb.createNote(null);
    note.title = '另一端已删除';
    await NotesDb.updateNote(note);

    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/state') {
        seen.add(req.uri.queryParameters['since'] ?? '(no since)');
        // 服务端当前 rev=99，会由 push 的响应带回。若客户端错误地用这个值
        // 覆盖 _rev，紧随的 pull 就会发出 since=99 并命中 unchanged 短路。
        if (req.uri.queryParameters['since'] == '99') {
          req.response.write(jsonEncode({
            'rev': 99,
            'notes': <dynamic>[],
            'unchanged': true,
          }));
        } else {
          req.response.write(jsonEncode({
            'rev': 99,
            'epoch': 0,
            'notes': <dynamic>[],
            'deletedIds': [note.id],
            'deletedAt': {note.id: DateTime.now().millisecondsSinceEpoch},
          }));
        }
      } else {
        req.response.write(jsonEncode({
          'ok': true,
          'rev': 99,
          'changed': 0,
          'deletedApplied': <dynamic>[],
          'count': 0,
        }));
      }
      await req.response.close();
    });

    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');

    await SyncService.i.push();
    await SyncService.i.pull();

    expect(seen, isNotEmpty, reason: 'pull 必须真的发出请求');
    expect(await NotesDb.getNote(note.id), isNull,
        reason: 'push 后紧跟 pull 必须能拿到远端的彻底删除');
    expect(seen, isNot(contains('99')),
        reason: 'push 不应把 _rev 推进到服务端当前 rev，否则 pull 会命中 unchanged');

    await server.close(force: true);
  });

  test('unchanged 响应里的删除墓碑也要落地', () async {
    final note = await NotesDb.createNote(null);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'rev': 100,
        'epoch': 0,
        'notes': <dynamic>[],
        'unchanged': true,
        'deletedIds': [note.id],
        'deletedAt': {note.id: DateTime.now().millisecondsSinceEpoch},
      }));
      await req.response.close();
    });
    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');

    await SyncService.i.pull();
    expect(await NotesDb.getNote(note.id), isNull,
        reason: '笔记没变化但另一端删过笔记时，本地也必须同步删除');
    await server.close(force: true);
  });
}
