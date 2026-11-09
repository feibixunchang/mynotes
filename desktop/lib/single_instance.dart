import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 单实例守卫（纯 dart:io，跨平台，不依赖任何原生插件）。
///
/// 做法：对一个固定路径的锁文件加独占锁。
/// - 第一个进程拿到锁，并轮询「唤醒信号」文件；
/// - 第二个进程抢锁失败 -> 写一个信号文件 -> 立即退出；
/// - 第一个进程看到信号后把自己显示到前台并聚焦（等价于双击图标 = 唤出窗口）。
///
/// 锁随进程退出由系统自动释放，崩溃也不会留下「永远无法启动」的死锁。
class SingleInstance {
  SingleInstance._();
  static final SingleInstance i = SingleInstance._();

  static const String _lockName = '.instance.lock';
  static const String _signalName = '.instance.activate';

  RandomAccessFile? _raf;
  Directory? _dir;
  Timer? _timer;
  bool _first = false;

  /// 本进程是不是第一个实例。
  bool get isFirst => _first;

  /// 锁目录：与笔记数据目录无关，保证「同一用户只有一个实例」，
  /// 而不是「每个解压目录各跑一个」。便携版拷多份时也只允许开一个。
  static Directory _lockDir() {
    String? base;
    if (Platform.isWindows) {
      base = Platform.environment['LOCALAPPDATA'];
      if (base == null || base.isEmpty) {
        base = File(Platform.resolvedExecutable).parent.path;
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      base = (home == null || home.isEmpty)
          ? Directory.systemTemp.path
          : '$home/Library/Application Support';
    } else {
      final home = Platform.environment['HOME'];
      base = (home == null || home.isEmpty)
          ? Directory.systemTemp.path
          : '$home/.local/share';
    }
    final dir = Directory('$base/MyNotesPortable');
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {}
    return dir;
  }

  /// 同步抢锁：在 main() 最前面调用，抢不到就返回 false，调用方应立刻退出。
  bool acquireSync() {
    try {
      _dir = _lockDir();
      final lockFile = File('${_dir!.path}/$_lockName');
      final raf = lockFile.openSync(mode: FileMode.append);
      try {
        raf.lockSync(FileLock.exclusive);
      } on FileSystemException {
        raf.closeSync();
        _notifyRunning();
        return false;
      }
      _raf = raf;
      _first = true;
      _clearSignal();
      return true;
    } catch (e) {
      // 目录不可写等极端情况：不阻止用户使用，退化成允许多开
      debugPrint('single instance unavailable: $e');
      _first = false;
      return true;
    }
  }

  void _clearSignal() {
    final dir = _dir;
    if (dir == null) return;
    final sig = File('${dir.path}/$_signalName');
    try {
      if (sig.existsSync()) sig.deleteSync();
    } catch (_) {}
  }

  /// 第二次启动时留个信号给已经在跑的实例。
  void _notifyRunning() {
    final dir = _dir;
    if (dir == null) return;
    try {
      File('${dir.path}/$_signalName').writeAsStringSync(
          '${DateTime.now().microsecondsSinceEpoch}',
          flush: true);
    } catch (_) {}
  }

  /// 第一个实例调用：收到唤醒信号时把自己拉到前台。
  void watchForActivate(VoidCallback onActivate) {
    if (!_first) return;
    final dir = _dir;
    if (dir == null) return;
    final sig = File('${dir.path}/$_signalName');
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!sig.existsSync()) return;
      _clearSignal();
      try {
        onActivate();
      } catch (e) {
        debugPrint('activate failed: $e');
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    try {
      _raf?.unlockSync();
    } catch (_) {}
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
  }
}
