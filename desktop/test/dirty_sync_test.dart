import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/db.dart';
import 'package:my_notes/pages/settings_page.dart';
import 'package:my_notes/sync.dart';

/// v1.3.9 回归测试：三端实时同步的三个根因。
///
/// 1. 客户端每次都推「全量快照」→ 一端的旧快照会覆盖另一端刚写入的新内容。
///    现在改成按笔记粒度的脏标记：只推本机真正改动过的笔记。
/// 2. 服务端用客户端自带的时间戳判断新旧 → 两台机器时钟只要有偏差，
///    真实修改就被静默丢弃。现在由服务端裁决并回传权威时间戳。
/// 3. 软删除 / 恢复不推进 updated_at，且落库时丢掉 trashed 字段
///    → 回收站状态永远同步不过来。
///
/// 用 NotesDb.testDataDirOverride 强制写入临时目录，绝不碰真实笔记库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('mynotes-test-');
    NotesDb.testDataDirOverride = tmpDir.path;
    await NotesDb.init();
    // flutter_test 默认装上 HttpOverrides，让所有 HttpClient 请求直接返回 400。
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    NotesDb.testDataDirOverride = null;
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 起一个本地 mock 服务端，记录收到的推送内容。
  Future<HttpServer> startServer(
    List<Map<String, dynamic>> received, {
    Map<String, dynamic> Function()? onState,
    Map<String, dynamic>? syncReply,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/sync') {
        final raw = await utf8.decoder.bind(req).join();
        received.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response.write(jsonEncode(syncReply ??
            {'ok': true, 'rev': 1, 'changed': 0, 'deletedApplied': <dynamic>[]}));
      } else if (req.uri.path == '/api/state') {
        req.response.write(jsonEncode(onState?.call() ??
            {'rev': 1, 'epoch': 0, 'notes': <dynamic>[], 'deletedIds': <dynamic>[]}));
      } else {
        req.response.write(jsonEncode({'ok': true, 'rev': 1}));
      }
      await req.response.close();
    });
    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');
    return server;
  }

  test('push 只发送本机改动过的笔记，不会把全量快照推上去', () async {
    final pushed = <Map<String, dynamic>>[];
    final server = await startServer(pushed);

    // 一条「别的端早就写好、本机没动过」的笔记。
    final other = await NotesDb.createNote(null);
    other.title = '别的端写的';
    other.body = '本机从未编辑';
    // 模拟「本机已知且与服务端一致」：清掉脏标记。
    await NotesDb.clearDirty([other.id]);

    // 本机真正改动的一条。
    final mine = await NotesDb.createNote(null);
    mine.title = '本机改的';
    mine.body = '新内容';
    await NotesDb.updateNote(mine);

    await SyncService.i.push();

    expect(pushed, isNotEmpty, reason: 'push 必须真的发出请求');
    final sent = (pushed.last['notes'] as List).cast<Map<String, dynamic>>();
    final ids = sent.map((n) => n['id']).toSet();
    expect(ids, contains(mine.id), reason: '本机改过的笔记必须上推');
    expect(ids, isNot(contains(other.id)),
        reason: '本机没改过的笔记不能上推，否则会覆盖另一端的新内容');

    await server.close(force: true);
  });

  test('推送成功后脏标记被清除，服务端权威时间戳被本地采纳', () async {
    final pushed = <Map<String, dynamic>>[];
    final server = await startServer(pushed, syncReply: {
      'ok': true,
      'rev': 5,
      'changed': 1,
      'deletedApplied': <dynamic>[],
      // 服务端裁决出的权威时间戳：必须被本地采纳，
      // 否则三端用不同的时间戳排序，列表顺序必然不一致。
      'stamps': <String, dynamic>{},
    });

    final note = await NotesDb.createNote(null);
    note.title = '待对齐';
    expect((await NotesDb.dirtyIds()), contains(note.id));

    await SyncService.i.push();

    expect((await NotesDb.dirtyIds()), isNot(contains(note.id)),
        reason: '服务端确认后必须清掉脏标记');
    expect(await NotesDb.getNote(note.id), isNotNull);

    await server.close(force: true);
  });

  test('服务端回传的时间戳被写回本地，三端排序才能一致', () async {
    final pushed = <Map<String, dynamic>>[];
    String? noteId;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/sync') {
        final raw = await utf8.decoder.bind(req).join();
        pushed.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response.write(jsonEncode({
          'ok': true,
          'rev': 9,
          'changed': 1,
          'deletedApplied': <dynamic>[],
          'stamps': {noteId: 1730000000000},
        }));
      } else {
        req.response.write(jsonEncode(
            {'rev': 9, 'epoch': 0, 'notes': <dynamic>[], 'deletedIds': <dynamic>[]}));
      }
      await req.response.close();
    });
    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');

    final note = await NotesDb.createNote(null);
    noteId = note.id;
    await SyncService.i.push();

    final after = await NotesDb.getNote(note.id);
    expect(after!.updatedAt, 1730000000000,
        reason: '本地必须采用服务端的权威时间戳，否则三端排序不同');

    await server.close(force: true);
  });

  test('软删除与恢复都会推进 updated_at 并留下脏标记，回收站才能实时同步',
      () async {
    final note = await NotesDb.createNote(null);
    note.title = '回收站测试';
    await NotesDb.updateNote(note);
    final beforeDelete = (await NotesDb.getNote(note.id))!.updatedAt;

    await NotesDb.softDelete(note.id);
    final deleted = (await NotesDb.getNote(note.id))!;
    expect(deleted.trashed, isTrue);
    expect(deleted.updatedAt, greaterThan(beforeDelete),
        reason: '软删除必须推进时间戳，否则远端判不出「变了」');
    expect((await NotesDb.dirtyIds()), contains(note.id));

    await NotesDb.restore(note.id);
    final restored = (await NotesDb.getNote(note.id))!;
    expect(restored.trashed, isFalse);
    expect(restored.updatedAt, greaterThan(deleted.updatedAt),
        reason: '恢复也必须推进时间戳');
  });

  test('远端快照落地时保留 trashed 状态与远端时间戳', () async {
    final note = await NotesDb.createNote(null);
    await NotesDb.applyRemoteSnapshot({
      'id': note.id,
      'title': '远端改的',
      'content': '远端内容',
      'trashed': true,
      'pinned': false,
      'tags': <dynamic>[],
      'updatedAt': 1700000000000,
    });
    final applied = (await NotesDb.getNote(note.id))!;
    expect(applied.trashed, isTrue,
        reason: '远端的回收站状态必须落地，否则三端回收站永远对不上');
    expect(applied.updatedAt, 1700000000000);
    expect(applied.title, '远端改的');
    expect((await NotesDb.dirtyIds()), isNot(contains(note.id)),
        reason: '远端版本落地后本地不应再有待推送内容');
  });

  test('本地尚未推送的编辑不会被远端快照覆盖', () async {
    final note = await NotesDb.createNote(null);
    note.title = '本机新写的标题';
    await NotesDb.updateNote(note);

    // 远端送回同一条笔记的旧内容。
    await SyncService.i.applyRemoteEvent({
      'rev': 12,
      'notes': [
        {
          'id': note.id,
          'title': '远端旧标题',
          'content': '远端旧内容',
          'trashed': false,
          'pinned': false,
          'tags': <dynamic>[],
          'updatedAt': 1700000000000,
        }
      ],
      'deletedIds': <dynamic>[],
    });

    final local = (await NotesDb.getNote(note.id))!;
    expect(local.title, '本机新写的标题',
        reason: '本机还没上推的编辑不能被远端旧版本覆盖，否则用户会丢字');
    expect((await NotesDb.dirtyIds()), contains(note.id),
        reason: '保护本地编辑时脏标记必须留着，否则这次编辑永远上不去了');
  });

  test('本地有未推送编辑时，远端的回收站状态仍要立刻生效', () async {
    final note = await NotesDb.createNote(null);
    note.title = '本机新写的标题';
    await NotesDb.updateNote(note);
    expect((await NotesDb.dirtyIds()), contains(note.id));

    // 远端把这条笔记移入回收站（内容仍是旧的）。
    await SyncService.i.applyRemoteEvent({
      'rev': 13,
      'notes': [
        {
          'id': note.id,
          'title': '远端旧标题',
          'content': '远端旧内容',
          'trashed': true,
          'pinned': false,
          'tags': <dynamic>[],
          'updatedAt': 1700000000000,
        }
      ],
      'deletedIds': <dynamic>[],
    });

    final local = (await NotesDb.getNote(note.id))!;
    expect(local.trashed, isTrue,
        reason: '回收站状态必须实时同步，不能因为本地有未推送编辑就被挡住');
    expect(local.title, '本机新写的标题',
        reason: '但正文仍要保护本地，不能被远端旧内容覆盖');
    expect((await NotesDb.dirtyIds()), contains(note.id),
        reason: '状态同步过来后本地正文仍未推送，脏标记要留着');
  });

  test('本地有未推送编辑时，远端的置顶状态同样立刻生效', () async {
    final note = await NotesDb.createNote(null);
    note.title = '本机新写的标题';
    await NotesDb.updateNote(note);

    await SyncService.i.applyRemoteEvent({
      'rev': 14,
      'notes': [
        {
          'id': note.id,
          'title': '远端旧标题',
          'content': '远端旧内容',
          'trashed': false,
          'pinned': true,
          'tags': <dynamic>[],
          'updatedAt': 1700000000000,
        }
      ],
      'deletedIds': <dynamic>[],
    });

    final local = (await NotesDb.getNote(note.id))!;
    expect(local.pinned, isTrue, reason: '置顶状态也必须实时同步');
    expect(local.title, '本机新写的标题', reason: '正文仍然保护本地');
  });
}
