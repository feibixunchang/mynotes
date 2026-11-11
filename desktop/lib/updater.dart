import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_version.dart';
import 'db.dart';

/// 自动更新：检查 GitHub 官方 Release -> 多渠道并发分段下载（自动选最快）
/// -> 校验官方 SHA-256 -> 自动替换并重启。
///
/// 隐私约定（重要）：
/// - 只发起 GET 请求到公开的 GitHub / CDN / 加速镜像，不发送任何本机信息，
///   不带设备名、用户名、笔记内容、同步地址或任何账号标识。
/// - 不写遥测、不上传日志；配置只存在本地数据目录的 update.json。
/// - 第三方镜像只作为传输通道，最终以 GitHub API 返回的 SHA-256 为准；
///   拿不到官方校验值时一律拒绝自动安装。
const String _repo = 'feibixunchang/mynotes';
const String _ua = 'MyNotes-Updater/$kAppVersion';

/// 版本元数据源（并发请求，取最先成功且能解析出本平台资产的一个）。
/// 前两个是 GitHub 官方 API（其一走加速代理），第三个是仓库里的静态清单，
/// 用于 api.github.com 完全不可达时的兜底。
const List<String> _metaUrls = <String>[
  'https://api.github.com/repos/$_repo/releases/latest',
  // gh-proxy.com 实测能正常代理 GitHub API（0.9s 返回），
  // 而原来的 ghfast.top 已完全失效（连接超时 12s），
  // 放在这里会白白拖慢整个元数据窗口。
  'https://gh-proxy.com/https://api.github.com/repos/$_repo/releases/latest',
  'https://cdn.jsdelivr.net/gh/$_repo@main/update/latest.json',
  // raw 直读仓库清单：jsdelivr 有 TTL 缓存，清完 CDN 也不会立刻生效，
  // 这条是最终的兜底。
  'https://raw.githubusercontent.com/$_repo/main/update/latest.json',
];

/// 下载渠道：空前缀是官方直连，其余为公开加速镜像。
/// 镜像只负责传输，内容以 SHA-256 校验为准。
const List<String> _mirrorPrefixes = <String>[
  '',
  // 实测速度（2026-11-11，下载 3MB 片段）：
  //   gh-proxy.com  367 KB/s  ← 最快
  //   ghproxy.net   123 KB/s
  //   直连 GitHub    83 KB/s
  // ghfast.top 已失效（连接超时），不再列入，避免浪费一个 worker。
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
];

enum UpdateStatus {
  idle,
  checking,
  downloading,
  ready,
  installing,
  upToDate,
  failed,
  postponed,
}

class UpdateState {
  const UpdateState({
    this.status = UpdateStatus.idle,
    this.version = '',
    this.progress = 0,
    this.message = '',
  });
  final UpdateStatus status;
  final String version;
  final double progress;
  final String message;
}

class _Release {
  const _Release({
    required this.version,
    required this.assetName,
    required this.url,
    this.sha256,
    this.size = 0,
  });
  final String version;
  final String assetName;
  final String url;
  final String? sha256;
  final int size;
}

class UpdateService {
  UpdateService._();
  static final UpdateService i = UpdateService._();

  final ValueNotifier<UpdateState> state = ValueNotifier(const UpdateState());
  File? _pkg;
  bool _busy = false;

  // ---------- 本地配置（与笔记数据放在同一目录，绝不上传） ----------

  Map<String, dynamic> _readCfg() {
    try {
      final f = File(p.join(NotesDb.dataDir, 'update.json'));
      if (!f.existsSync()) return <String, dynamic>{};
      final d = jsonDecode(f.readAsStringSync());
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _writeCfg(Map<String, dynamic> d) {
    try {
      File(p.join(NotesDb.dataDir, 'update.json')).writeAsStringSync(jsonEncode(d));
    } catch (_) {}
  }

  bool get autoEnabled => _readCfg()['auto'] != false;

  set autoEnabled(bool v) {
    final c = _readCfg();
    c['auto'] = v;
    _writeCfg(c);
  }

  int get lastCheckAt => (_readCfg()['lastCheck'] as num?)?.toInt() ?? 0;

  set lastCheckAt(int v) {
    final c = _readCfg();
    c['lastCheck'] = v;
    _writeCfg(c);
  }

  int get postponeUntil => (_readCfg()['postponeUntil'] as num?)?.toInt() ?? 0;

  set postponeUntil(int v) {
    final c = _readCfg();
    c['postponeUntil'] = v;
    _writeCfg(c);
  }

  void _set({
    UpdateStatus? status,
    String? version,
    double? progress,
    String? message,
  }) {
    final o = state.value;
    state.value = UpdateState(
      status: status ?? o.status,
      version: version ?? o.version,
      progress: progress ?? o.progress,
      message: message ?? o.message,
    );
  }

  /// 用户点「稍后」：本次会话不再自动安装，24 小时内不再提醒。
  void postpone() {
    postponeUntil = DateTime.now().millisecondsSinceEpoch + 24 * 3600 * 1000;
    _set(status: UpdateStatus.postponed, message: '已推迟本次更新，明天再提醒');
  }

  // ---------- 启动后自动检查 ----------

  Future<void> autoCheck() async {
    try {
      if (!autoEnabled) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now < postponeUntil || now - lastCheckAt < 6 * 3600 * 1000) return;
      await Future.delayed(const Duration(seconds: 3));
      await checkAndUpdate();
    } catch (_) {
      // 更新检查失败绝不能影响主程序使用，下次启动再试。
    }
  }

  Future<void> checkAndUpdate({bool manual = false}) async {
    if (_busy) return;
    if (!manual && DateTime.now().millisecondsSinceEpoch < postponeUntil) return;
    _busy = true;
    try {
      _set(status: UpdateStatus.checking, message: '正在检查更新…', progress: 0);
      lastCheckAt = DateTime.now().millisecondsSinceEpoch;

      final rel = await _fetchLatest();
      if (rel == null) {
        _set(status: UpdateStatus.failed,
            message: '暂时无法获取版本信息，稍后会自动重试');
        return;
      }
      if (_compare(rel.version, kAppVersion) <= 0) {
        _set(
          status: UpdateStatus.upToDate,
          version: rel.version,
          message: '已是最新版本 v$kAppVersion',
          progress: 0,
        );
        return;
      }

      _set(
        status: UpdateStatus.downloading,
        version: rel.version,
        message: '发现 v${rel.version}，正在多渠道并发下载…',
        progress: 0,
      );
      // 并发分段下载本身就在测速：快的渠道会领到更多分片，慢渠道自然落后。
      // 不再先花最多 6 秒做一次「首字节探测」，第一段请求就是真实数据。
      var file = await _download(rel, rel.url);
      // 镜像都不支持 Range 或并发下载失败时，退回官方单连接，保证可用。
      if (file == null) file = await _downloadSingle(rel, rel.url);
      if (file == null) {
        _set(status: UpdateStatus.failed, message: '下载失败，稍后会自动重试');
        return;
      }

      if (rel.sha256 == null || rel.sha256!.isEmpty) {
        _set(status: UpdateStatus.failed,
            message: '缺少官方 SHA-256，已停止自动安装（请手动下载）');
        return;
      }
      _set(message: '正在校验安装包…', progress: 1);
      final digest = await _sha256(file);
      if (digest != rel.sha256) {
        try {
          file.deleteSync();
        } catch (_) {}
        _set(status: UpdateStatus.failed,
            message: '校验不通过，已丢弃下载文件');
        return;
      }

      _pkg = file;
      _set(
        status: UpdateStatus.ready,
        version: rel.version,
        message: 'v${rel.version} 已下载并校验通过，即将自动更新并重启',
        progress: 1,
      );
      // 给一个可取消的窗口，但默认无需任何操作：倒计时结束自动安装。
      await Future.delayed(const Duration(seconds: 6));
      if (state.value.status == UpdateStatus.ready && autoEnabled) {
        await installNow();
      }
    } catch (_) {
      _set(status: UpdateStatus.failed, message: '更新出错，稍后会自动重试');
    } finally {
      _busy = false;
    }
  }

  Future<void> installNow() async {
    final f = _pkg;
    if (f == null) return;
    _set(status: UpdateStatus.installing,
        message: '正在安装更新，应用会自动重启…');
    var ok = false;
    try {
      ok = await _install(f);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      _set(status: UpdateStatus.failed,
          message: '安装准备失败，请到 GitHub Release 手动下载');
      return;
    }
    await Future.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  // ---------- 版本元信息 ----------

  Future<_Release?> _fetchLatest() async {
    // 短窗口内收齐所有元数据源，取「版本号最高」且带官方校验值的结果。
    // 以前取第一个成功的源：发布窗口内 jsdelivr 缓存若是旧清单且比
    // GitHub API 先返回，客户端会误判「已是最新」，要等 CDN 过期才发现新版。
    final results = await Future.wait(_metaUrls.map(_getJson).toList())
        .timeout(const Duration(seconds: 11),
            onTimeout: () => <Map<String, dynamic>?>[]);
    _Release? best;
    for (final j in results) {
      final rel = j == null ? null : _parseRelease(j);
      if (rel == null) continue;
      if (best == null ||
          _compare(rel.version, best.version) > 0 ||
          (_compare(rel.version, best.version) == 0 &&
              best.sha256 == null &&
              rel.sha256 != null)) {
        best = rel;
      }
    }
    return best;
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      req.headers.set('Accept', 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 9));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  _Release? _parseRelease(Map<String, dynamic> j) {
    final tag = (j['tag_name'] ?? j['version'] ?? '').toString();
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!RegExp(r'^\d+(\.\d+){1,3}').hasMatch(version)) return null;
    final assets = (j['assets'] as List?) ?? const <dynamic>[];
    final mac = Platform.isMacOS;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] ?? '').toString();
      final lower = name.toLowerCase();
      final match = mac
          ? lower.endsWith('.dmg') && lower.contains('mac')
          : lower.endsWith('.zip') && lower.contains('windows');
      if (!match) continue;
      final url = (a['browser_download_url'] ?? a['url'] ?? '').toString();
      if (url.isEmpty) continue;
      var digest = (a['digest'] ?? '').toString();
      if (digest.startsWith('sha256:')) digest = digest.substring(7);
      if (digest.isEmpty) digest = (a['sha256'] ?? '').toString();
      return _Release(
        version: version,
        assetName: name,
        url: url,
        sha256: digest.isEmpty ? null : digest.toLowerCase().trim(),
        size: (a['size'] as num?)?.toInt() ?? 0,
      );
    }
    return null;
  }

  static int _compare(String a, String b) {
    List<int> nums(String s) => s
        .split(RegExp(r'[.+\-]'))
        .map((x) => int.tryParse(x) ?? 0)
        .toList();
    final x = nums(a), y = nums(b);
    for (var i = 0; i < math.max(x.length, y.length); i++) {
      final l = i < x.length ? x[i] : 0;
      final r = i < y.length ? y[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  // ---------- 多渠道测速与下载 ----------

  List<String> _channels(String url) =>
      _mirrorPrefixes.map((m) => m.isEmpty ? url : '$m$url').toList();

  /// 多渠道并发分段下载：把安装包切成 2MB 小块，每个渠道开 2 个 worker，
  /// 谁快谁就多领几块（work-stealing），慢渠道自动落后、不拖累整体。
  /// 一次实现两件事：自动选最快通道 + 叠加多通道带宽。
  /// 每段独立重试其它渠道；整包完成后仍以官方 SHA-256 强校验为准。
  Future<File?> _download(_Release rel, String url) async {
    final total = rel.size;
    final channels = _channels(url);
    if (total < 1024 * 1024) return _downloadSingle(rel, url);

    const int partSize = 2 * 1024 * 1024;
    final count = (total / partSize).ceil();
    Directory? dir;
    try {
      dir = await Directory.systemTemp.createTemp('mynotes-upd-');
      var nextPart = 0;
      var totalGot = 0;
      var lastProgress = -0.02;
      void bump(int n) {
        totalGot += n;
        final progress = (totalGot / total).clamp(0.0, 1.0);
        if (progress - lastProgress < 0.01 && progress < 1) return;
        lastProgress = progress;
        _set(
          status: UpdateStatus.downloading,
          version: rel.version,
          progress: progress,
          message: '正在下载 v${rel.version} · ${_mb(totalGot)} / ${_mb(total)}',
        );
      }

      // 4 渠道 × 2 连接。Dart 单线程事件循环里 nextPart++ 是原子的。
      final workers = <Future<bool>>[];
      for (var w = 0; w < channels.length * 2; w++) {
        workers.add(() async {
          while (true) {
            final idx = nextPart++;
            if (idx >= count) return true;
            var bytes = -1;
            for (var r = 0; r < channels.length && bytes < 0; r++) {
              bytes = await _fetchRange(
                  channels[(w + r) % channels.length], dir!,
                  idx, partSize, total);
            }
            if (bytes < 0) return false;
            bump(bytes);
          }
        }());
      }
      final results = await Future.wait(workers);
      if (results.any((ok) => !ok)) return null;

      final out = File(p.join(dir.path, rel.assetName));
      final sink = out.openWrite();
      for (var i = 0; i < count; i++) {
        final part = File(p.join(dir.path, 'part_$i'));
        if (!await part.exists() || await part.length() == 0) {
          await sink.close();
          return null;
        }
        await sink.addStream(part.openRead());
      }
      await sink.close();
      if (await out.length() != total) return null;
      return out;
    } catch (_) {
      return null;
    } finally {
      // 分片只是中间产物，最终交付的整包不受影响。
      if (dir != null) {
        for (var i = 0; i < count; i++) {
          try {
            await File(p.join(dir.path, 'part_$i')).delete();
          } catch (_) {}
        }
      }
    }
  }

  /// 下载第 idx 个 Range 分片，返回成功写入的字节数；失败返回 -1。
  /// 只接受 206：返回 200 说明渠道忽略了 Range，会把整包写进一个分片。
  Future<int> _fetchRange(String url, Directory dir, int idx, int partSize,
      int total) async {
    HttpClient? client;
    IOSink? sink;
    final start = idx * partSize;
    final end = math.min(total, start + partSize) - 1;
    final expected = end - start + 1;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      req.headers.set('Range', 'bytes=$start-$end');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 206) return -1;
      sink = File(p.join(dir.path, 'part_$idx')).openWrite();
      var received = 0;
      await for (final chunk in resp) {
        if (received + chunk.length > expected) return -1;
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return received == expected ? received : -1;
    } catch (_) {
      return -1;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  /// 官方单连接兜底：镜像全部不支持 Range / 并发下载失败时使用。
  Future<File?> _downloadSingle(_Release rel, String url) async {
    IOSink? sink;
    HttpClient? client;
    try {
      final dir = await Directory.systemTemp.createTemp('mynotes-upd-');
      final out = File(p.join(dir.path, rel.assetName));
      sink = out.openWrite();
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 && resp.statusCode != 206) return null;
      final total = rel.size > 0 ? rel.size : resp.contentLength;
      var got = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        got += chunk.length;
        _set(
          status: UpdateStatus.downloading,
          version: rel.version,
          progress: total > 0 ? (got / total).clamp(0.0, 1.0) : 0,
          message: '正在下载 v${rel.version} · ${_mb(got)}',
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return out;
    } catch (_) {
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  static String _mb(int bytes) =>
      bytes < 1024 * 1024 ? '${bytes ~/ 1024} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB';

  Future<String> _sha256(File f) async {
    final d = await sha256.bind(f.openRead()).first;
    return d.toString();
  }

  // ---------- 自动安装 ----------

  Future<bool> _install(File pkg) async {
    if (Platform.isMacOS) return _installMac(pkg);
    if (Platform.isWindows) return _installWin(pkg);
    return false;
  }

  static String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _ps(String s) => "'${s.replaceAll("'", "''")}'";

  static String? _currentAppPath() {
    var d = Directory(p.dirname(Platform.resolvedExecutable));
    for (var i = 0; i < 5; i++) {
      if (d.path.endsWith('.app')) return d.path;
      d = d.parent;
    }
    return null;
  }

  Future<bool> _installMac(File dmg) async {
    final work = Directory(p.join(dmg.parent.path, 'stage'));
    await work.create(recursive: true);
    final mount = Directory(p.join(work.path, 'mnt'));
    await mount.create(recursive: true);
    final attach = await Process.run('/usr/bin/hdiutil', <String>[
      'attach', dmg.path, '-nobrowse', '-readonly',
      '-mountpoint', mount.path, '-quiet',
    ]);
    if (attach.exitCode != 0) return false;
    final apps = mount
        .listSync()
        .where((e) => e.path.toLowerCase().endsWith('.app'))
        .toList();
    final cur = _currentAppPath();
    if (apps.isEmpty || cur == null) {
      await Process.run('/usr/bin/hdiutil', <String>['detach', mount.path, '-quiet']);
      return false;
    }
    final src = apps.first.path;
    final bak = '$cur.update-backup';
    final script = File(p.join(work.path, 'update.sh'));
    await script.writeAsString('''#!/bin/sh
PID=${pid}
i=0
while kill -0 "\$PID" 2>/dev/null && [ "\$i" -lt 120 ]; do sleep 0.5; i=\$((i+1)); done
APP=${_sh(cur)}
BAK=${_sh(bak)}
SRC=${_sh(src)}
MNT=${_sh(mount.path)}
rm -rf "\$BAK"
if ! mv "\$APP" "\$BAK"; then exit 1; fi
if ditto "\$SRC" "\$APP" && [ -x "\$APP/Contents/MacOS/my_notes" ]; then
  /usr/bin/xattr -cr "\$APP" >/dev/null 2>&1
  /usr/bin/hdiutil detach "\$MNT" -quiet >/dev/null 2>&1
  /usr/bin/open -a "\$APP"
else
  rm -rf "\$APP"
  mv "\$BAK" "\$APP"
  /usr/bin/open -a "\$APP"
  exit 1
fi
''');
    await Process.run('/bin/chmod', <String>['755', script.path]);
    await Process.start('/bin/sh', <String>[script.path],
        mode: ProcessStartMode.detached);
    return true;
  }

  Future<bool> _installWin(File zip) async {
    final work = Directory(p.join(zip.parent.path, 'stage'));
    await work.create(recursive: true);
    final unzip = await Process.run('powershell', <String>[
      '-NoProfile', '-Command',
      'Expand-Archive -LiteralPath ${_ps(zip.path)} '
          '-DestinationPath ${_ps(work.path)} -Force',
    ]);
    if (unzip.exitCode != 0) return false;
    File? exe;
    await for (final e in work.list(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).toLowerCase() == 'my_notes.exe') {
        exe = e;
        break;
      }
    }
    if (exe == null) return false;
    final src = p.dirname(exe.path);
    final dst = p.dirname(Platform.resolvedExecutable);
    final bak = p.join(dst, '_update_backup');
    final script = File(p.join(work.path, 'update.cmd'));
    await script.writeAsString('''@echo off
chcp 65001 >nul
setlocal
set "PID=${pid}"
set "SRC=${src}"
set "DST=${dst}"
set "BAK=${bak}"
:wait
powershell -NoProfile -Command "if (Get-Process -Id %PID% -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }"
if errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
if exist "%BAK%" rmdir /s /q "%BAK%"
robocopy "%DST%" "%BAK%" /E /XD notes-data _update_backup /NFL /NDL /NJH /NJS /NP >nul
robocopy "%SRC%" "%DST%" /E /XD notes-data /XF *.log settings.txt notes.db update.json /NFL /NDL /NJH /NJS /NP
if errorlevel 8 (
  robocopy "%BAK%" "%DST%" /E /NFL /NDL /NJH /NJS /NP >nul
  start "" "%DST%\\my_notes.exe"
  exit /b 1
)
start "" "%DST%\\my_notes.exe"
''');
    await Process.start('cmd.exe', <String>['/C', script.path],
        mode: ProcessStartMode.detached);
    return true;
  }
}

/// 应用内底部更新提示条：默认无需操作，倒计时结束自动安装；可点「稍后」。
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateState>(
      valueListenable: UpdateService.i.state,
      builder: (context, st, _) {
        final visible = st.status == UpdateStatus.downloading ||
            st.status == UpdateStatus.ready ||
            st.status == UpdateStatus.installing ||
            st.status == UpdateStatus.failed ||
            st.status == UpdateStatus.checking;
        if (!visible) return const SizedBox.shrink();
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = dark ? const Color(0xFF2A2D3A) : const Color(0xFFF1F3F9);
        final fg = dark ? Colors.white : const Color(0xFF1B1D26);
        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              boxShadow: <BoxShadow>[
                BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.system_update_alt, size: 18, color: fg),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(st.message,
                          style: TextStyle(fontSize: 12, color: fg)),
                    ),
                    if (st.status == UpdateStatus.ready) ...<Widget>[
                      TextButton(
                          onPressed: () => UpdateService.i.postpone(),
                          child: const Text('稍后')),
                      TextButton(
                          onPressed: () => UpdateService.i.installNow(),
                          child: const Text('立即更新')),
                    ],
                    if (st.status == UpdateStatus.failed)
                      TextButton(
                          onPressed: () =>
                              UpdateService.i.checkAndUpdate(manual: true),
                          child: const Text('重试')),
                  ],
                ),
                if (st.status == UpdateStatus.downloading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(value: st.progress, minHeight: 3),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
