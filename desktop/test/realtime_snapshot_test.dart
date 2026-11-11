import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/db.dart';
import 'package:my_notes/pages/settings_page.dart';
import 'package:my_notes/sync.dart';

/// v1.3.9 回归：SSE 帧直接携带「变更笔记全文」，客户端收到同一帧就落地，
/// 并保留服务端权威 updatedAt，使三端列表顺序完全一致。
///
/// 隔离约定：NotesDb.testDataDirOverride 强制写入临时目录，
/// HttpOverrides.global = null 让本地 mock server 真的能收到请求。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('mynotes-snapshot-test-');
    NotesDb.testDataDirOverride = tmpDir.path;
    await NotesDb.init();
    HttpOverrides.global = null;
    await SettingsStore.write('syncUrl', '');
    await SettingsStore.write('syncToken', '');
  });
  tearDownAll(() {
    NotesDb.testDataDirOverride = null;
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  setUp(() => SyncService.i.stop());

  Map<String, dynamic> snap(String id,
      {required bool trashed,
      required int updatedAt,
      String body = '内容',
      bool pinned = false}) {
    return {
      'id': id,
      'title': '标题-$id',
      'content': body,
      'tags': <dynamic>[],
      'pinned': pinned,
      'trashed': trashed,
      'bookId': '测试本',
      'createdAt': 500,
      'updatedAt': updatedAt,
    };
  }

  Map<String, dynamic> frame(List<Map<String, dynamic>> notes,
      {List<String> deleted = const <String>[],
      bool partial = false,
      int rev = 10}) {
    return {
      'rev': rev,
      'epoch': 0,
      'changed': notes.map((n) => n['id']).toList(),
      'notes': notes,
      'deletedIds': deleted,
      'partial': partial,
    };
  }

  test('远端「移入回收站」随事件即时落地，且保留服务端时间戳', () async {
    final local = await NotesDb.createNote(null);
    local.title = '标题-${local.id}';
    local.body = '内容';
    await NotesDb.updateNote(local);
    // 用「略晚于本机时间」的服务端时间戳，避免触发本地未推送编辑保护，
    // 同时能与 updateNote 写入的本机时间明确区分。
    final stamp = DateTime.now().millisecondsSinceEpoch + 1000;

    final before = SyncService.dataVersion.value;
    await SyncService.i.handleSseDataLine(
        'data: ${jsonEncode(frame([snap(local.id, trashed: true, updatedAt: stamp)]))}');

    final after = await NotesDb.getNote(local.id);
    expect(after, isNotNull);
    expect(after!.trashed, isTrue,
        reason: '回收站状态必须随事件即时同步，不能等 30 秒轮询');
    expect(after.updatedAt, stamp,
        reason: '必须保留服务端时间戳；被本机时间覆盖会让三端排序漂移');
    expect(SyncService.dataVersion.value, greaterThan(before),
        reason: '落地后必须通知界面重绘三栏');
  });

  test('远端「恢复」随事件即时落地，笔记从回收站回到全部笔记', () async {
    final id = 'restore-${DateTime.now().microsecondsSinceEpoch}';
    final stamp = DateTime.now().millisecondsSinceEpoch + 1000;
    await NotesDb.applyRemoteSnapshot(snap(id, trashed: true, updatedAt: stamp));
    expect((await NotesDb.getNote(id))!.trashed, isTrue);

    await SyncService.i.handleSseDataLine(
        'data: ${jsonEncode(frame([snap(id, trashed: false, updatedAt: stamp + 1)]))}');
    final after = await NotesDb.getNote(id);
    expect(after!.trashed, isFalse, reason: '恢复必须即时同步到本端');
    expect(after.updatedAt, stamp + 1);
  });

  test('同一帧内同时处理新增、内容变更与永久删除', () async {
    final stamp = DateTime.now().millisecondsSinceEpoch + 1000;
    final freshId = 'fresh-${DateTime.now().microsecondsSinceEpoch}';
    final goneId = 'gone-${DateTime.now().microsecondsSinceEpoch}';
    await NotesDb.applyRemoteSnapshot(snap(goneId, trashed: false, updatedAt: stamp));

    await SyncService.i.handleSseDataLine('data: ${jsonEncode(frame([
          snap(freshId, trashed: false, updatedAt: stamp, body: '新笔记'),
        ], deleted: [goneId]))}');

    expect(await NotesDb.getNote(goneId), isNull,
        reason: 'deletedIds 必须即时生效');
    final fresh = await NotesDb.getNote(freshId);
    expect(fresh, isNotNull);
    expect(fresh!.body, '新笔记');
    expect((await NotesDb.tombstones()).containsKey(goneId), isFalse,
        reason: '远端删除不能写本地墓碑，否则 push 会把删除再广播回去');
  });

  test('相同 updatedAt 时按 id 稳定排序，三端顺序一致', () async {
    const stamp = 1700000000000;
    for (final id in ['s-b', 's-a', 's-c']) {
      await NotesDb.applyRemoteSnapshot(snap(id, trashed: false, updatedAt: stamp));
    }
    final all = await NotesDb.listNotes('');
    final subset = all
        .where((n) => ['s-b', 's-a', 's-c'].contains(n.id))
        .map((n) => n.id)
        .toList();
    expect(subset, equals(['s-a', 's-b', 's-c']),
        reason: '缺少 id 兜底时，SQLite 与 JS 会按各自插入顺序排出不同结果');
    // 三端都保留同一个服务端时间戳
    expect(all.where((n) => n.id.startsWith('s-')).every((n) => n.updatedAt == stamp),
        isTrue);
  });

  test('本端 softDelete / restore 会推进 updated_at', () async {
    final note = await NotesDb.createNote(null);
    await NotesDb.updateNote(note);
    final before = (await NotesDb.getNote(note.id))!.updatedAt;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await NotesDb.softDelete(note.id);
    final trashed = (await NotesDb.getNote(note.id))!;
    expect(trashed.trashed, isTrue);
    expect(trashed.updatedAt, greaterThan(before),
        reason: '不推进时间戳，远端会判定「这条没变」而不合并');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await NotesDb.restore(note.id);
    final restored = (await NotesDb.getNote(note.id))!;
    expect(restored.trashed, isFalse);
    expect(restored.updatedAt, greaterThan(trashed.updatedAt));
  });

  test('新版帧直接落地不再反查 /api/state，partial 帧才做全量补齐', () async {
    var stateHits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      stateHits++;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'rev': 300,
        'epoch': 0,
        'notes': <dynamic>[],
        'deletedIds': <dynamic>[],
      }));
      await req.response.close();
    });
    await SettingsStore.write('syncUrl', 'http://127.0.0.1:${server.port}');
    await SettingsStore.write('syncToken', '');
    final stamp = DateTime.now().millisecondsSinceEpoch + 1000;
    final id = 'no-refetch-${DateTime.now().microsecondsSinceEpoch}';

    await SyncService.i.handleSseDataLine(
        'data: ${jsonEncode(frame([snap(id, trashed: false, updatedAt: stamp)]))}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(stateHits, 0,
        reason: '全文帧必须自己带数据，反查会被 unchanged / rev 短路丢事件');
    expect((await NotesDb.getNote(id))!.body, '内容');

    await SyncService.i.handleSseDataLine(
        'data: ${jsonEncode(frame(<Map<String, dynamic>>[], partial: true, rev: 301))}');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(stateHits, greaterThanOrEqualTo(1),
        reason: '重连/批量变更的 partial 帧必须触发一次全量补齐');
    SyncService.i.stop();
    await server.close(force: true);
  });

  test('旧版服务端帧（只有 id 列表）仍走兼容路径', () async {
    final id = 'legacy-${DateTime.now().microsecondsSinceEpoch}';
    final stamp = DateTime.now().millisecondsSinceEpoch + 1000;
    await NotesDb.applyRemoteSnapshot(snap(id, trashed: false, updatedAt: stamp));
    await SyncService.i.handleSseDataLine(
        'data: ${jsonEncode({'rev': 400, 'changed': <dynamic>[], 'deletedIds': [id]})}');
    SyncService.i.stop();
    expect(await NotesDb.getNote(id), isNull,
        reason: '老 NAS 尚未升级时，永久删除也必须照常实时生效');
  });
}
