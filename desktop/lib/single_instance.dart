import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 单实例守卫（纯 dart:io，跨平台）。
///
/// 做法：在回环地址上独占一个固定端口。
/// - 第一个进程绑定成功 -> 它就是唯一实例，并在该端口上等待「唤醒」请求；
/// - 第二个进程绑定失败 -> 连接过去打个招呼，只要对方回 PONG（确认是同款应用），
///   就立刻退出；对方收到招呼会把自己的窗口显示到前台。
///
/// 为什么不用文件锁：`RandomAccessFile.lock` 在锁被占用时是**阻塞**的，
/// 第二份会安静地卡在那里（进程还在、界面不出来），比多开更糟。
/// 端口绑定是原子且非阻塞的，失败立刻知道。
class SingleInstance {
  SingleInstance._();
  static final SingleInstance i = SingleInstance._();

  static const int _basePort = 45871;
  static const String _token = 'mynotes-single-instance';

  int _port = _basePort;
  ServerSocket? _server;
  bool _first = false;
  VoidCallback? _onActivate;

  bool get isFirst => _first;

  /// 抢实例。返回 false 表示已有实例在运行，调用方应立即退出。
  Future<bool> acquire() async {
    for (var i = 0; i < 6; i++) {
      try {
        _server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          _port,
          shared: false,
        );
        _first = true;
        _server!.listen(_handle, onError: (_) {}, cancelOnError: false);
        return true;
      } on SocketException {
        // 端口被占：先确认占着的是不是我们自己的另一个实例
        final ours = await _notifyExisting();
        if (ours) return false;
        // 被别的程序占用了，换一个端口再试
        _port++;
      } catch (e) {
        debugPrint('single instance: $e');
        _port++;
      }
    }
    // 极端情况（端口全被占）：不阻止用户使用，退化为允许多开
    debugPrint('single instance: fallback, allow start');
    _first = true;
    return true;
  }

  void setActivateHandler(VoidCallback cb) {
    _onActivate = cb;
  }

  void _handle(Socket socket) {
    socket.listen(
      (data) {
        final text = utf8.decode(data, allowMalformed: true);
        if (!text.contains(_token)) return;
        try {
          socket.write('PONG $_token\n');
          socket.flush();
        } catch (_) {}
        _onActivate?.call();
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// 连一下已知实例：是同类应用就顺手请求它把窗口唤到前台。
  Future<bool> _notifyExisting() async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 700),
      );
      s.write('ACTIVATE $_token\n');
      await s.flush();
      final reply = await s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .first
          .timeout(const Duration(milliseconds: 900), onTimeout: () => '');
      s.destroy();
      return reply.trim() == 'PONG $_token';
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    try {
      _server?.close();
    } catch (_) {}
    _server = null;
  }
}
