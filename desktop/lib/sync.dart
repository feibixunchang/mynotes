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

  /// 远端数据变化时递增，主界面据此刷新三栏列表与计数。
  static final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  static const String defaultUrl = "http://127.0.0.1:8000";
  static const String defaultToken = "";

  String get baseUrl => SettingsStore.readSync('syncUrl', defaultUrl).trim();
  String get token => SettingsStore.readSync('syncToken', defaultToken).trim();

  /// 规范化用户填进来的地址：补 http:// 前缀、去掉结尾多余的斜杠。
  static String normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 试连一次同步服务，返回给用户看的一句话结论。
  /// 走 /api/state 而不是 /health：前者需要令牌，能顺便验证令牌是否正确。
  Future<String> testConnection({String? url, String? token}) async {
    final base = normalizeUrl(url ?? baseUrl);
    final tok = (token ?? this.token).trim();
    if (base.isEmpty) return '请先填写服务器地址';
    final uri = Uri.tryParse('$base/api/state?since=999999999');
    if (uri == null || uri.host.isEmpty) return '地址格式不正确：$base';
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.openUrl('GET', uri);
      if (tok.isNotEmpty) req.headers.set('Authorization', 'Bearer $tok');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return '服务器拒绝访问（HTTP ${resp.statusCode}）：令牌不正确，或服务端已启用令牌而这里留空了';
      }
      if (resp.statusCode >= 400) return '服务器返回 HTTP ${resp.statusCode}';
      Map<String, dynamic>? j;
      try {
        final d = jsonDecode(body);
        if (d is Map<String, dynamic>) j = d;
      } catch (_) {}
      if (j == null) return '连上了，但返回内容不是笔记服务（确认地址端口对不对）';
      final rev = (j['rev'] as num?)?.toInt();
      final total = (j['notes'] as List?)?.length;
      return '连接成功 · 服务端 rev ${rev ?? '?'}'
          '${total != null ? ' · 本次收到 $total 条' : ''}';
    } catch (e) {
      final s = e.toString();
      if (s.contains('TimeoutException')) return '连接超时：检查地址、端口与网络';
      if (s.contains('SocketException')) return '连不上：主机或端口不可达（$base）';
      return '连接失败：$s';
    }
  }

  /// 保存设置后重建连接。refresh=true 时清空增量游标并完整重推一次，
  /// 用于「切换到了另一台服务器」——这样新服务器也能拿到本地全部笔记。
  Future<void> applyConfig({bool refresh = false}) async {
    stop();
    live = false;
    if (refresh) {
      _rev = -1;
      _dirty = true;
      _epoch = -1;
      // -1 表示「epoch 未知」：首次拉取只记录不清空本地，避免误删
      await SettingsStore.write('syncEpoch', '-1');
    }
    lastOk = true;
    lastError = null;
    resultText = '正在连接…';
    atMs = null;
    notifyListeners();
    start();
  }

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
      final tombs = await NotesDb.tombstones();
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
        // 永久删除的墓碑要告知服务端，否则服务端不会删、下次 pull 又会把笔记送回来。
        "deletedIds": tombs.keys.toList(),
        "deletedAt": tombs,
        // 不发送本机主机名或设备标识，避免任何可识别信息离开这台电脑。
        "device": "desktop",
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
        // 服务端确认已处理删除列表后，本地墓碑即可清掉。
        if (res.containsKey('deletedApplied')) {
          await NotesDb.forgetTombstones(tombs.keys);
        }
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

  /// 永久删除后立即告知服务端，避免 SSE / 轮询把旧笔记推回本地。
  /// 新版服务端一次批量处理 deletedIds；旧版回退到逐条 /api/purge。
  /// 全程后台执行，不阻塞界面。
  void notifyDeleted(List<String> ids) {
    final unique = ids.toSet().toList();
    if (unique.isEmpty) return;
    () async {
      try {
        await _notifyDeletedImpl(unique);
      } catch (_) {}
    }();
  }

  Future<void> _notifyDeletedImpl(List<String> ids) async {
    if (baseUrl.isEmpty) return;
    final res = await _send('POST', '/api/sync',
        jsonEncode({'notes': <dynamic>[], 'deletedIds': ids}));
    if (res != null && res.containsKey('deletedApplied')) {
      await NotesDb.forgetTombstones(ids);
      markDirty();
      return;
    }
    // 旧版服务端不认识 deletedIds：逐条调用已有的 /api/purge，限制并发。
    const batch = 6;
    for (var i = 0; i < ids.length; i += batch) {
      final end = i + batch > ids.length ? ids.length : i + batch;
      final part = ids.sublist(i, end);
      await Future.wait(part.map((id) async {
        try {
          await _send('POST', '/api/purge', jsonEncode({'id': id}));
        } catch (_) {}
      }));
    }
    markDirty();
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
      // 新版服务端下发的删除列表：本地同步删除。
      final remoteDeleted = ((res["deletedIds"] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      if (remoteDeleted.isNotEmpty) {
        await NotesDb.purgeRemoteIds(remoteDeleted.toList());
      }
      // 本机已永久删除的笔记，旧服务端仍会把它发回来；用墓碑挡住，
      // 否则「彻底删除 / 清空回收站」看起来永远删不掉。
      final tombs = await NotesDb.tombstones();
      var applied = 0;
      for (final item in remote) {
        if (item is! Map) continue;
        final id = item["id"] as String?;
        if (id == null || remoteDeleted.contains(id)) continue;
        final ru = (item["updatedAt"] as num?)?.toInt() ?? 0;
        final tombAt = tombs[id] ?? 0;
        if (tombAt > 0 && tombAt >= ru) continue;
        final local = await NotesDb.getNote(id);
        if (local == null) {
          await NotesDb.importOne(Map<String, dynamic>.from(item));
          applied++;
        } else if (ru > local.updatedAt) {
          await NotesDb.applyRemote(local, Map<String, dynamic>.from(item));
          applied++;
        }
      }
      if (remoteDeleted.isNotEmpty) applied++;
      atMs = DateTime.now().millisecondsSinceEpoch;
      lastOk = true;
      lastError = null;
      resultText = applied > 0 ? '已同步（收到 $applied 条）' : '已同步';
      if (applied > 0) {
        _dirty = false;
        SyncService.dataVersion.value++;
      }
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
