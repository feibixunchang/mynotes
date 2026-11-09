import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'db.dart';
import 'pages/settings_page.dart';

/// 局域网同步：对接 NAS 上的 mynotes-sync v2 容器
/// - 本地有改动 -> 2 秒内合并上推（服务端按 updatedAt 逐条取新）
/// - 远端有改动 -> SSE 事件即时拉取合并；另有 30 秒兜底轮询
class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService i = SyncService._();

  static const String defaultUrl = "http://127.0.0.1:8000";
  static const String defaultToken = "";

  String get baseUrl => SettingsStore.readSync('syncUrl', defaultUrl).trim();
  String get token => SettingsStore.readSync('syncToken', defaultToken).trim();

  String resultText = '尚未同步';
  String? lastError;
  int? atMs;
  bool lastOk = true;
  bool live = false;

  void _log(String msg) {
    try {
      File('${NotesDb.dataDir}/sync.log').writeAsStringSync(
          '${DateTime.now().toIso8601String()} $msg\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  int _rev = -1;
  // epoch 持久化：只有「上次见过的 epoch」与服务端不同，才说明另一端真的清空过，
  // 这样导入大批笔记后重启不会被误清空。
  int _epoch = int.tryParse(SettingsStore.readSync('syncEpoch', '-1')) ?? -1;
  bool _dirty = false;
  bool _pushing = false;
  Timer? _pushTimer;
  Timer? _poll;
  HttpClient? _sseClient;

  void markDirty() {
    _dirty = true;
    // 秒级上推：2 秒防抖
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 1800), () => push());
  }

  void start() {
    _poll?.cancel();
    // 每 30 秒兜底：脏数据就上推；否则轻量拉取（服务端 unchanged 直接返回空）。
    // 这样启动瞬间的短暂失败会在下一轮自动恢复，状态栏不会长期挂着红色错误。
    _poll = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_dirty) {
        await push();
      } else {
        await pull(silent: true);
      }
    });
    Timer(const Duration(seconds: 2), () async {
      await pull(silent: true);
      await push();
      _connect();
    });
  }

  // ---------- 推送 ----------

  Future<void> push() async {
    if (_pushing) return;
    _pushing = true;
    try {
      final books = await NotesDb.listBooks();
      final nameOf = <String, String>{for (final b in books) b.id: b.name};
      final all = <Note>[];
      all.addAll(await NotesDb.listNotes('', trash: false));
      all.addAll(await NotesDb.listNotes('', trash: true));
      final body = jsonEncode({
        "notes": all
            .map((n) => {
                  "id": n.id,
                  "title": n.title,
                  "content": n.body,
                  "tags": n.tags,
                  "pinned": n.pinned,
                  "trashed": n.trashed,
                  // 传笔记本名称而非本地 id，网页版更易读
                  "bookId": nameOf[n.bookId] ?? n.bookId,
                  "createdAt": n.createdAt,
                  "updatedAt": n.updatedAt,
                })
            .toList(),
        "device": Platform.localHostname,
      });
      final res = await _send('POST', '/api/sync', body);
      atMs = DateTime.now().millisecondsSinceEpoch;
      if (res == null) {
        _fail('无法连接同步服务');
        return;
      }
      if (res["ok"] == true) {
        _dirty = false;
        _rev = (res["rev"] as num?)?.toInt() ?? _rev;
        lastOk = true;
        resultText = '已同步 ${all.length} 条';
      } else {
        lastOk = false;
        resultText = '同步失败：${res["error"] ?? "未知"}';
      }
    } catch (e) {
      _log('PUSH EXCEPTION $e');
      _fail('同步异常');
    } finally {
      _pushing = false;
      notifyListeners();
    }
  }

  /// 清空 NAS 服务端（配合本地 clearAllNotes 使用）
  Future<bool> clearRemote() async {
    final res = await _send('POST', '/api/clear', '{}');
    if (res != null && res['ok'] == true) {
      _rev = (res['rev'] as num?)?.toInt() ?? _rev;
      _epoch = (res['epoch'] as num?)?.toInt() ?? _epoch;
      await SettingsStore.write('syncEpoch', '$_epoch');
      _dirty = false;
      lastOk = true;
      resultText = '已清空全部笔记';
      notifyListeners();
      return true;
    }
    lastOk = false;
    resultText = '清空远端失败';
    notifyListeners();
    return false;
  }

  // ---------- 拉取合并 ----------

  Future<void> pull({bool silent = true}) async {
    try {
      final path = _rev >= 0 ? '/api/state?since=$_rev' : '/api/state';
      final res = await _send('GET', path, null);
      if (res == null) {
        if (!silent) _fail('无法连接同步服务');
        return;
      }
      if (res["unchanged"] == true) return;
      _rev = (res["rev"] as num?)?.toInt() ?? _rev;
      // 另一端执行了「一键删除所有笔记」：本地必须同步清空，
      // 否则下次 push 会把已经删掉的笔记又推回服务端。
      final remoteEpoch = (res["epoch"] as num?)?.toInt() ?? 0;
      if (_epoch >= 0 && remoteEpoch > 0 && remoteEpoch != _epoch) {
        await NotesDb.clearAllNotes();
      }
      if (remoteEpoch != _epoch) {
        _epoch = remoteEpoch;
        await SettingsStore.write('syncEpoch', '$remoteEpoch');
      }
      final remote = (res["notes"] as List?) ?? const [];
      var applied = 0;
      for (final item in remote) {
        if (item is! Map) continue;
        final id = item["id"] as String?;
        if (id == null) continue;
        final ru = (item["updatedAt"] as num?)?.toInt() ?? 0;
        final local = await NotesDb.getNote(id);
        if (local == null) {
          await NotesDb.importOne(Map<String, dynamic>.from(item));
          applied++;
        } else if (ru > local.updatedAt) {
          await NotesDb.applyRemote(local, Map<String, dynamic>.from(item));
          applied++;
        }
      }
      atMs = DateTime.now().millisecondsSinceEpoch;
      lastOk = true;
      lastError = null;
      resultText = applied > 0 ? '已同步（收到 $applied 条）' : '已同步';
      if (applied > 0) _dirty = false;
      notifyListeners();
    } catch (_) {
      if (!silent) _fail('拉取异常');
    }
  }

  // ---------- SSE 实时监听 ----------

  Future<void> _connect() async {
    for (;;) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..idleTimeout = const Duration(seconds: 60);
        _sseClient = client;
        final req = await client.getUrl(Uri.parse('$baseUrl/api/events?token=${Uri.encodeComponent(token)}'));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          client.close(force: true);
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }
        live = true;
        // SSE 已连上就说明服务端可达：清掉启动瞬间的陈旧失败提示
        if (!lastOk) {
          lastOk = true;
          lastError = null;
          resultText = '已同步';
          atMs = DateTime.now().millisecondsSinceEpoch;
        }
        notifyListeners();
        final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
        await for (final line in lines) {
          if (line.startsWith('data: ')) {
            final payload = line.substring(6);
            if (payload.startsWith('{')) {
              try {
                final d = jsonDecode(payload);
                final r = (d['rev'] as num?)?.toInt();
                if (r != null && r != _rev) {
                  unawaited(pull());
                }
              } catch (_) {}
            }
          }
        }
        client.close(force: true);
      } catch (_) {
        // 忽略，走重连
      }
      live = false;
      notifyListeners();
      await Future.delayed(const Duration(seconds: 8));
      if (_sseClient == null) return;
    }
  }

  void stop() {
    _pushTimer?.cancel();
    _poll?.cancel();
    final c = _sseClient;
    _sseClient = null;
    try {
      c?.close(force: true);
    } catch (_) {}
  }

  void _fail(String msg) {
    lastOk = false;
    atMs = DateTime.now().millisecondsSinceEpoch;
    resultText = msg;
    _log('FAIL $msg lastError=$lastError');
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _send(String method, String path, String? body) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      // 双保险：旧配置里可能残留 \\r，header 值绝不能带控制字符
      req.headers.set('Authorization', 'Bearer ${token.trim()}');
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (body != null) {
        final bytes = utf8.encode(body);
        // 必须显式给 Content-Length：否则 Dart 走 chunked，服务端读不到 body
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      Map<String, dynamic>? parsed;
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) parsed = d;
      } catch (_) {}
      if (resp.statusCode >= 400) {
        lastError = 'HTTP ${resp.statusCode}';
        return parsed ?? {"ok": false, "error": "HTTP ${resp.statusCode}"};
      }
      lastError = null;
      return parsed ?? {"ok": true};
    } catch (e) {
      lastError = e.toString();
      _log('SEND ERROR $method $path -> $e');
      return null;
    }
  }

  String formatTime(int? ms) {
    if (ms == null) return '--';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
