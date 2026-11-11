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

  /// 公开分发版不预置任何地址。以前默认 http://127.0.0.1:8000，
  /// 全新安装的 Windows 安装版会静默连到本机不存在的端口，用户完全看不到
  /// 任何笔记同步，也不明白为什么。现在改为空并在状态栏明确提示未配置。
  static const String defaultUrl = "";
  /// 仅用于设置页的占位示例，采用文档用的私有地址段，不指向任何真实设备。
  static const String exampleUrl = "http://192.168.1.100:2581";
  static const String defaultToken = "";

  String get baseUrl => normalizeUrl(SettingsStore.readSync('syncUrl', defaultUrl));
  String get token => SettingsStore.readSync('syncToken', defaultToken).trim();
  bool get enabled => SettingsStore.readSync('syncEnabled', '1') != '0';

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
  // 每次 stop/reconfigure 递增，让旧的 SSE 重连循环退出，避免双连接。
  int _generation = 0;
  // epoch 持久化：只有「上次见过的 epoch」与服务端不同，才说明另一端真的清空过，
  // 这样导入大批笔记后重启不会被误清空。
  int _epoch = int.tryParse(SettingsStore.readSync('syncEpoch', '-1')) ?? -1;
  bool _dirty = false;
  // 本地改动过、尚未推送成功的笔记 id 集合（按笔记粒度）。
  // 只用全局 _dirty 的话，一处改动会连带把整个库推上去，
  // 覆盖其它端刚写入的内容。
  Set<String> _dirtyIds = <String>{};
  bool _pushing = false;
  bool _pulling = false;
  // SSE 事件撞上正在进行的 pull 时记一笔，pull 结束后补跑，避免整批变更丢失。
  bool _pullPending = false;
  Timer? _pushTimer;
  Timer? _ssePullTimer;
  Timer? _poll;
  HttpClient? _sseClient;

  /// 标记本机有改动需要上推。
  /// 传入笔记 id 时只把这一条计入脏集合；不传则退化为全局标记
  /// （仅用于「有改动」这个状态提示，实际推送内容以数据库脏标记为准）。
  void markDirty([String? noteId]) {
    _dirty = true;
    if (noteId != null) {
      _dirtyIds.add(noteId);
    }
    // 本地改动 0.6 秒内上推，缩短另一端感知延迟。
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 600), () => push());
  }

  void start() {
    _poll?.cancel();
    if (!enabled) {
      live = false;
      resultText = '同步已关闭';
      notifyListeners();
      return;
    }
    if (baseUrl.isEmpty) {
      live = false;
      resultText = '未设置同步地址（设置 → 同步）';
      notifyListeners();
      return;
    }
    // 每 30 秒兜底：脏数据就上推；否则轻量拉取（服务端 unchanged 直接返回空）。
    // 这样启动瞬间的短暂失败会在下一轮自动恢复，状态栏不会长期挂着红色错误。
    _poll = Timer.periodic(const Duration(seconds: 30), (_) async {
      // 数据库里还有未推送的笔记就推：应用重启后全局 _dirty 会丢，
      // 但脏标记是持久化的，不能因此漏推。
      if (_dirty || (await NotesDb.dirtyIds()).isNotEmpty) await push();
      // 无论本地是否有改动都要拉一次：push 不再推进 _rev，远端删除
      // （含 SSE 断线期间漏掉的）在这里也能被兜住，不必等下一次 rev 变化。
      await pull(silent: true);
    });
    // SSE 必须立即启动。以前排在 pull()+push() 之后，一次 20 秒的推送超时
    // 就会让实时通道晚 20 秒才连上。
    unawaited(_connect());
    Timer(const Duration(seconds: 2), () async {
      await pull(silent: true);
      await push();
    });
  }

  // ---------- 推送 ----------

  Future<void> push() async {
    if (_pushing) return;
    _pushing = true;
    try {
      final books = await NotesDb.listBooks();
      final nameOf = <String, String>{for (final b in books) b.id: b.name};
      // 只推「本机真正改动过」的笔记。以前每次都推全量，一端的旧快照会把
      // 另一端刚写入的新内容覆盖回去 —— 这是「三端内容互相打架、回收站
      // 状态乱跳」的另一个根因。
      final all = await NotesDb.dirtyNotes();
      final tombs = await NotesDb.tombstones();
      if (all.isEmpty && tombs.isEmpty) {
        _dirty = false;
        lastOk = true;
        resultText = '已是最新';
        notifyListeners();
        return;
      }
      // 记录本次发送的内容指纹。推送期间用户可能又改了同一条笔记，
      // 只有内容没再变的那几条才能算「已被服务端确认」。
      final sent = <String, String>{
        for (final n in all) n.id: _fingerprint(n)
      };
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
        // 服务端已确认收到这批笔记：只清「内容没再变」的脏标记，
        // 推送期间新改的内容要留给下一轮，避免丢失用户刚敲的字。
        final confirmed = <String>[];
        for (final n in all) {
          final now = await NotesDb.getNote(n.id);
          if (now != null && _fingerprint(now) == sent[n.id]) {
            confirmed.add(n.id);
          }
        }
        await NotesDb.clearDirty(confirmed);
        _dirty = (await NotesDb.dirtyIds()).isNotEmpty;
        // 关键：push 的响应 rev 只表示「服务端处理到哪一次变更」，不代表本端
        // 已经看到该 rev 里的远端改动（尤其是彻底删除）。若在这里推进 _rev，
        // 紧随其后的 pull() 会命中 unchanged 短路，删除列表永远收不到。
        // _rev 只允许由 pull() 的成功响应推进。
        lastOk = true;
        resultText = '已同步 ${all.length} 条';
        // 服务端回传权威时间戳：把本地时间戳对齐过去，
        // 三端才会用同一套时间戳排出完全一致的列表顺序。
        final stamps = (res["stamps"] as Map?)?.cast<String, dynamic>();
        if (stamps != null && stamps.isNotEmpty) {
          // 只对已确认的笔记套用服务端权威时间戳；
          // 刚改过还没上推的笔记保持本地时间戳，等下一轮再对齐。
          final safe = <String, dynamic>{
            for (final id in confirmed)
              if (stamps[id] != null) id: stamps[id]
          };
          if (safe.isNotEmpty) {
            await NotesDb.applyServerStamps(safe);
            SyncService.dataVersion.value++;
          }
        }
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
      // 同 push()：不推进 _rev，下一次 pull() 会以全量确认清空结果。
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

  /// full=true 时不带 since，强制取服务端全量快照（手动刷新用）。
  /// 服务端在 unchanged 响应里也会下发删除墓碑，所以必须先应用删除再判断
  /// unchanged，否则「笔记没变、但有笔记在另一端被删掉」会被整个跳过。
  Future<void> pull({bool silent = true, bool full = false}) async {
    if (_pulling && !full) {
      // SSE 事件常与 30 秒轮询/启动拉取重叠。以前直接丢掉，导致该次远端
      // 删除最长要再等 30 秒；这里记下并在当前 pull 结束后补跑一次。
      _pullPending = true;
      return;
    }
    _pulling = true;
    try {
      final path = (!full && _rev >= 0) ? '/api/state?since=$_rev' : '/api/state';
      final res = await _send('GET', path, null);
      if (res == null) {
        if (!silent) _fail('无法连接同步服务');
        return;
      }
      // 删除列表可能出现在 unchanged 响应里：先落地，再决定是否短路。
      final remoteDeleted = ((res["deletedIds"] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      final purged = remoteDeleted.isEmpty
          ? 0
          : await NotesDb.purgeRemoteIds(remoteDeleted.toList());
      if (res["unchanged"] == true) {
        _rev = (res["rev"] as num?)?.toInt() ?? _rev;
        if (purged > 0) {
          atMs = DateTime.now().millisecondsSinceEpoch;
          lastOk = true;
          resultText = '已同步（移除 $purged 条已删除笔记）';
          SyncService.dataVersion.value++;
          notifyListeners();
        }
        return;
      }
      _rev = (res["rev"] as num?)?.toInt() ?? _rev;
      // 另一端执行了「一键删除所有笔记」：本地必须同步清空，
      // 否则下次 push 会把已经删掉的笔记又推回服务端。
      final remoteEpoch = (res["epoch"] as num?)?.toInt() ?? 0;
      if (_epoch >= 0 && remoteEpoch > 0 && remoteEpoch != _epoch) {
        await NotesDb.clearAllNotes();
        SyncService.dataVersion.value++;
      }
      if (remoteEpoch != _epoch) {
        _epoch = remoteEpoch;
        await SettingsStore.write('syncEpoch', '$remoteEpoch');
      }
      final remote = (res["notes"] as List?) ?? const [];
      // remoteDeleted 已在 unchanged 判断之前解析并落地，这里直接复用。
      // 本机已永久删除的笔记，旧服务端仍会把它发回来；用墓碑挡住，
      // 否则「彻底删除 / 清空回收站」看起来永远删不掉。
      final tombs = await NotesDb.tombstones();
      // 刷新脏集合：只有本地确实改动过、且尚未推送成功的笔记才受保护。
      _dirtyIds = await NotesDb.dirtyIds();
      var applied = 0;
      for (final item in remote) {
        if (item is! Map) continue;
        final id = item["id"] as String?;
        if (id == null || remoteDeleted.contains(id)) continue;
        final ru = (item["updatedAt"] as num?)?.toInt() ?? 0;
        final tombAt = tombs[id] ?? 0;
        if (tombAt > 0 && tombAt >= ru) continue;
        final snapshot = Map<String, dynamic>.from(item);
        final local = await NotesDb.getNote(id);
        if (local == null) {
          await NotesDb.applyRemoteSnapshot(snapshot);
          applied++;
        } else {
          // 分项裁决，与 _applySnapshot 保持一致：
          // 正文冲突 → 保护本地未推送的编辑；
          // 状态冲突（回收站 / 置顶 / 笔记本）→ 立刻跟随远端。
          final dirty = await _isLocallyDirty(id);
          final stateDiffers = _snapshotDiffers(local, snapshot);
          if (!dirty) {
            if (stateDiffers) {
              await NotesDb.applyRemoteSnapshot(snapshot);
              applied++;
            } else if (ru > 0 && ru != local.updatedAt) {
              // 内容一致、时间戳不同：对齐到服务端权威时间戳，
              // 三端才能排出完全一样的顺序。
              await NotesDb.applyServerStamps({id: ru});
              applied++;
            }
          } else if (stateDiffers) {
            final remoteTrashed = snapshot['trashed'] == true;
            final remotePinned = snapshot['pinned'] == true;
            final remoteBook = (snapshot['bookId'] ?? '').toString();
            if (remoteTrashed != local.trashed ||
                remotePinned != local.pinned ||
                (remoteBook.isNotEmpty && remoteBook != local.bookId)) {
              await NotesDb.applyRemoteState(id,
                  trashed: remoteTrashed,
                  pinned: remotePinned,
                  bookId: remoteBook,
                  updatedAt: ru);
              applied++;
            }
          }
          // 正文冲突（且状态一致）：保护本地，等 push 后由服务端裁决。
        }
      }
      if (purged > 0) applied++;
      atMs = DateTime.now().millisecondsSinceEpoch;
      lastOk = true;
      lastError = null;
      resultText = applied > 0 ? '已同步（收到 $applied 条）' : '已同步';
      if (applied > 0) {
        // _dirty 只能由 push() 成功清除。收到远端数据就清，会丢掉本地
        // 尚未上推的编辑。
        SyncService.dataVersion.value++;
      }
      notifyListeners();
    } catch (_) {
      if (!silent) _fail('拉取异常');
    } finally {
      _pulling = false;
      if (_pullPending) {
        _pullPending = false;
        Future.microtask(() => unawaited(pull()));
      }
    }
  }

  /// 这条笔记本地是否还有「尚未推送成功」的改动。
  /// 以数据库 dirty 列为准（持久化、重启后仍在），内存里的 _dirtyIds 只是
  /// 快速路径的补充——SSE 事件帧走 applyRemoteEvent，不会经过 pull()，
  /// 只看内存集合会漏判，把用户刚写的内容覆盖成远端旧版本。
  Future<bool> _isLocallyDirty(String id) async {
    if (_dirtyIds.contains(id)) return true;
    return NotesDb.isDirty(id);
  }

  /// 内容指纹：用于判断「推送期间这条笔记有没有被再次修改」。
  String _fingerprint(Note n) => [
        n.title,
        n.body,
        n.pinned ? '1' : '0',
        n.trashed ? '1' : '0',
        (n.tags.toList()..sort()).join(','),
      ].join('\u0001');

  /// 判断服务端快照与本地笔记是否有实质差异。
  /// 只看时间戳不够：移入回收站 / 恢复 / 置顶可能留下相同的 updatedAt，
  /// 却必须同步；反过来完全相同就不必重复写库、重刷界面。
  /// 标签按集合比较（顺序可能不同），笔记本名称也要比。
  bool _snapshotDiffers(Note local, Map item) {
    final body = (item['content'] ?? item['body'] ?? '') as String;
    final title = (item['title'] ?? '') as String;
    final remoteTags =
        ((item['tags'] as List?) ?? const []).map((e) => e.toString()).toList()
          ..sort();
    final localTags = local.tags.toList()..sort();
    final remoteBook = (item['bookId'] ?? '').toString();
    return local.body != body ||
        (title.isNotEmpty && local.title != title) ||
        local.pinned != (item['pinned'] == true) ||
        local.trashed != (item['trashed'] == true) ||
        localTags.join(',') != remoteTags.join(',') ||
        (remoteBook.isNotEmpty && local.bookId != remoteBook);
  }

  /// 正文（标题 + 内容 + 标签）是否与远端不同。
  /// 回收站 / 置顶 / 笔记本属于「状态」，与「正文」分开裁决：
  /// 本地未推送的编辑必须保护正文（否则用户丢字），
  /// 但状态必须立刻跟随远端（否则回收站不同步）。
  bool _contentDiffers(Note local, Map item) {
    final body = (item['content'] ?? item['body'] ?? '') as String;
    final title = (item['title'] ?? '') as String;
    final remoteTags =
        ((item['tags'] as List?) ?? const []).map((e) => e.toString()).toList()
          ..sort();
    final localTags = local.tags.toList()..sort();
    return local.body != body ||
        (title.isNotEmpty && local.title != title) ||
        localTags.join(',') != remoteTags.join(',');
  }

  /// 落地一条服务端笔记快照，返回是否真的写入了数据库。
  Future<bool> _applySnapshot(
      Map item, Set<String> deleted, Map<String, int> tombs) async {
    final id = item['id'] as String?;
    if (id == null || deleted.contains(id)) return false;
    final ru = (item['updatedAt'] as num?)?.toInt() ?? 0;
    final tombAt = tombs[id] ?? 0;
    if (tombAt > 0 && tombAt >= ru) return false;
    final snapshot = Map<String, dynamic>.from(item);
    final local = await NotesDb.getNote(id);
    if (local == null) {
      await NotesDb.applyRemoteSnapshot(snapshot);
      return true;
    }
    final dirty = await _isLocallyDirty(id);
    final contentDiffers = _contentDiffers(local, snapshot);
    final stateDiffers = _snapshotDiffers(local, snapshot);

    if (!dirty) {
      // 本地没有未推送的编辑：远端版本直接落地。
      if (!stateDiffers) {
        // 内容一致但时间戳可能不同：对齐到服务端权威时间戳，
        // 三端才能排出完全一样的顺序。
        if (ru > 0 && ru != local.updatedAt) {
          await NotesDb.applyServerStamps({id: ru});
          return true;
        }
        return false;
      }
      await NotesDb.applyRemoteSnapshot(snapshot);
      return true;
    }

    // 本地还有未推送的编辑：分项裁决。
    // 1) 正文冲突 → 保护本地（用户刚敲的字不能被远端旧版本覆盖）。
    // 2) 状态冲突（回收站 / 置顶 / 笔记本）→ 必须立刻跟随远端，
    //    否则「另一端删了，这端还在正常列表里」就永远修不好。
    //    落地时只改状态字段，正文保留本地，脏标记保留（下次 push 会带上）。
    if (stateDiffers) {
      final remoteTrashed = snapshot['trashed'] == true;
      final remotePinned = snapshot['pinned'] == true;
      final remoteBook = (snapshot['bookId'] ?? '').toString();
      if (remoteTrashed != local.trashed ||
          remotePinned != local.pinned ||
          (remoteBook.isNotEmpty && remoteBook != local.bookId)) {
        await NotesDb.applyRemoteState(id,
            trashed: remoteTrashed,
            pinned: remotePinned,
            bookId: remoteBook,
            updatedAt: ru);
        return true;
      }
    }
    if (contentDiffers) {
      // 只有正文冲突、状态一致：保护本地正文，等 push 后由服务端裁决。
      return false;
    }
    return false;
  }

  /// 处理新版服务端的 SSE 事件帧：帧里直接带变更笔记全文、永久删除 id
  /// 与 epoch，收到同一帧即可落地，不再反查 /api/state。
  /// 以前广播只带 changed 的 id，客户端要二次拉取，会被 unchanged 短路、
  /// pull 撞车、rev 对齐丢事件 —— 这就是三端不实时的根因。返回落地条数。
  Future<int> applyRemoteEvent(Map<String, dynamic> d) async {
    final ids = ((d['deletedIds'] as List?) ?? const [])
        .whereType<String>()
        .toSet();
    final tombs = await NotesDb.tombstones();
    var changed = 0;

    final remoteEpoch = (d['epoch'] as num?)?.toInt() ?? _epoch;
    if (_epoch >= 0 && remoteEpoch > 0 && remoteEpoch != _epoch) {
      await NotesDb.clearAllNotes();
      _epoch = remoteEpoch;
      await SettingsStore.write('syncEpoch', '$_epoch');
      changed++;
    }

    if (ids.isNotEmpty) {
      changed += await NotesDb.purgeRemoteIds(ids.toList());
    }
    for (final raw in (d['notes'] as List?) ?? const []) {
      if (raw is! Map) continue;
      if (await _applySnapshot(raw, ids, tombs)) changed++;
    }

    final rev = (d['rev'] as num?)?.toInt();
    // partial 帧不带全文，留给紧随其后的全量 pull 去推进 rev。
    if (rev != null && d['partial'] != true) _rev = rev;

    if (changed > 0) {
      atMs = DateTime.now().millisecondsSinceEpoch;
      lastOk = true;
      lastError = null;
      resultText = '已同步（收到 $changed 条变更）';
      SyncService.dataVersion.value++;
      notifyListeners();
    }
    return changed;
  }

  /// 立即落地远端删除：SSE 事件到达的同一帧就删本地记录并刷新三栏。
  /// 刻意不写本地墓碑 —— 墓碑只由本端主动删除产生，否则会被 push() 再推回
  /// 服务端，形成「删除广播 → 墓碑 → 再广播」的无限循环。
  /// 返回实际删掉的条数，便于回归测试断言。
  Future<int> applyRemoteDeletions(List<String> ids) async {
    if (ids.isEmpty) return 0;
    try {
      final n = await NotesDb.purgeRemoteIds(ids);
      if (n <= 0) return 0;
      atMs = DateTime.now().millisecondsSinceEpoch;
      lastOk = true;
      resultText = '已同步（移除 $n 条已删除笔记）';
      SyncService.dataVersion.value++;
      notifyListeners();
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 处理一行 SSE 帧。抽成 public 便于回归测试直接喂服务端帧。
  Future<void> handleSseDataLine(String line) async {
    if (!line.startsWith('data: ')) return;
    final payload = line.substring(6).trim();
    if (payload.isEmpty) return;
    if (payload.startsWith('{')) {
      try {
        final d = jsonDecode(payload);
        if (d is Map) {
          final event = Map<String, dynamic>.from(d);
          if (event.containsKey('notes')) {
            // 新版服务端：数据随事件直接下发，收到即落地。
            await applyRemoteEvent(event);
            // 批量变更 / 断线重连：帧里不放全文，做一次全量补齐。
            if (event['partial'] == true || event['hello'] == true) {
              unawaited(pull(full: true));
            }
            return;
          }
          // 旧版服务端：只有 id 列表，仍需反查补齐。
          final ids = ((event['deletedIds'] as List?) ?? const [])
              .whereType<String>()
              .toList();
          if (ids.isNotEmpty) await applyRemoteDeletions(ids);
        }
      } catch (_) {}
    }
    // 旧帧（纯数字 rev）或解析失败：走一次合并拉取兜底。
    _schedulePull();
  }

  /// 合并短时间内的多次 SSE 通知，避免一次批量改动触发多次全量拉取。
  void _schedulePull() {
    _ssePullTimer?.cancel();
    _ssePullTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(pull());
    });
  }

  // ---------- SSE 实时监听 ----------

  Future<void> _connect() async {
    if (baseUrl.isEmpty) return;
    final gen = _generation;
    for (;;) {
      if (gen != _generation) return;
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..idleTimeout = const Duration(seconds: 60);
        _sseClient = client;
        final req = await client.getUrl(Uri.parse('$baseUrl/api/events?token=${Uri.encodeComponent(token)}'));
        req.headers.set('Authorization', 'Bearer ${token.trim()}');
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Connection', 'keep-alive');
        req.headers.set('Cache-Control', 'no-cache');
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
        // 45 秒没有任何数据行就判定连接僵死（服务端 20 秒一次心跳注释行），
        // 主动断开重连，避免「状态栏显示实时同步、实际收不到事件」。
        final lines = resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 45),
                onTimeout: (sink) => sink.addError(TimeoutException(
                    'SSE 心跳超时', const Duration(seconds: 45))));
        await for (final line in lines) {
          await handleSseDataLine(line);
        }
        client.close(force: true);
      } catch (_) {
        // 忽略，走重连
      }
      live = false;
      notifyListeners();
      await Future.delayed(const Duration(seconds: 8));
      if (gen != _generation || _sseClient == null) return;
    }
  }

  void stop() {
    _generation++;
    _pushTimer?.cancel();
    _ssePullTimer?.cancel();
    _ssePullTimer = null;
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
    if (baseUrl.isEmpty) return null;
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
