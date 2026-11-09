import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as na;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_lock.dart';
import 'app_version.dart';
import 'app_style.dart';
import 'biometrics.dart';
import 'db.dart';
import 'pages/notes_page.dart';
import 'pages/settings_page.dart';
import 'single_instance.dart';
import 'sync.dart';

/// 托盘初始化诊断日志（写到数据目录，便于确认 Windows 上是否真的挂上了托盘图标）
void _trayLog(String msg) {
  try {
    File('${NotesDb.dataDir}/tray.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append);
  } catch (_) {}
}

Future<void> main() async {
  // 单实例：必须在数据库与窗口初始化之前判断。
  // 抢不到锁说明已经有一份在跑，留个唤醒信号后立刻退出，
  // 已运行的实例会把自己显示到前台（等于双击图标唤出窗口）。
  // 自测模式（无界面）不参与抢锁，避免和正在使用的实例互相打架。
  final selfTestMode = Platform.environment['MYNOTES_SELFTEST'] == '1';
  if (!selfTestMode && !SingleInstance.i.acquireSync()) {
    exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();

  // 无界面自测模式：验证"新建笔记永不失效"等核心逻辑
  if (selfTestMode) {
    await _selfTest();
    return;
  }

  // 生物识别探测自测：只验证系统 Hello 是否可用，结果写 biometric.log
  if (Platform.environment['MYNOTES_BIO_SELFTEST'] == '1') {
    final ok = await Biometrics.isAvailable(refresh: true);
    debugPrint('BIO available=$ok label=${Biometrics.label} reason=${Biometrics.lastReason}');
    exit(0);
  }

  // 生物识别验证自测：真的弹出 Windows Hello 对话框走一次验证流程
  if (Platform.environment['MYNOTES_BIO_VERIFY'] == '1') {
    final ok = await Biometrics.verify('验证我的笔记指纹解锁');
    debugPrint('BIO verify=$ok reason=${Biometrics.lastReason}');
    exit(0);
  }

  try {
    await NotesDb.init();
  } catch (e) {
    debugPrint('数据库初始化失败：$e');
    exit(1);
  }

  // 命令行导入：MYNOTES_IMPORT=<simplenote 导出 json 路径>
  final importPath = Platform.environment['MYNOTES_IMPORT'];
  if (importPath != null && importPath.isNotEmpty) {
    try {
      final raw = jsonDecode(await File(importPath).readAsString());
      final items = raw is List
          ? raw.whereType<Map>().toList()
          : ((raw['notes'] as List?) ?? const []).whereType<Map>().toList();
      final n = await NotesDb.importBatch(items, bookName: '导入笔记');
      debugPrint('IMPORTED $n notes from $importPath');
    } catch (e) {
      debugPrint('IMPORT FAILED: $e');
    }
  }

  // 可将 MYNOTES_DEMO=1 用于演示/验收：预置示例笔记并自动打开第一篇
  if (Platform.environment['MYNOTES_DEMO'] == '1') {
    await _seedDemo();
  }
  final firstNotes = await NotesDb.listNotes(null);
  final openId = firstNotes.isNotEmpty ? firstNotes.first.id : null;

  // 性能采样（仅 MYNOTES_TIMINGS=1 时启用）：记录每帧 build/raster 耗时
  if (Platform.environment['MYNOTES_TIMINGS'] == '1') {
    final logFile = File('${NotesDb.dataDir}/timings.txt');
    final buf = <String>[];
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        buf.add('${t.timestampInMicroseconds} build=${t.buildDuration.inMicroseconds} '
            'raster=${t.rasterDuration.inMicroseconds} vsync=${t.vsyncOverhead.inMicroseconds} '
            'total=${t.totalSpan.inMicroseconds}');
      }
      if (buf.length >= 100) {
        try {
          logFile.writeAsStringSync('${buf.join('\n')}\n', mode: FileMode.append);
        } catch (_) {}
        buf.clear();
      }
    });
  }

  // ---- 窗口 ----
  final window = na.WindowManager.instance.getCurrent();
  window?.title = '我的笔记 v$kAppVersion';

  // nativeapi 的 Size/Rectangle 用逻辑像素（与 Flutter 一致）。
  // 旧代码误乘 devicePixelRatio，高 DPI 下把最小窗口撑到 1170x780，
  // 拖窗口边缘时被系统强行夹回，表现为「拖不动 / 不指哪打哪」。
  const double minW = 720;
  const double minH = 460;
  window?.minimumSize = na.Size(width: minW, height: minH);

  // 恢复上次的窗口大小与位置（含简单兜底，避免恢复到屏幕外）
  final savedW = double.tryParse(SettingsStore.readSync('winW', ''));
  final savedH = double.tryParse(SettingsStore.readSync('winH', ''));
  final savedX = double.tryParse(SettingsStore.readSync('winX', ''));
  final savedY = double.tryParse(SettingsStore.readSync('winY', ''));
  final sizeOk =
      savedW != null && savedH != null && savedW >= minW && savedH >= minH;
  final posOk = savedX != null &&
      savedY != null &&
      savedX > -200 &&
      savedY > -200 &&
      savedX < 6000 &&
      savedY < 4000;
  if (sizeOk) {
    window?.bounds = na.Rectangle(
      x: posOk ? savedX : 40,
      y: posOk ? savedY : 40,
      width: savedW,
      height: savedH,
    );
  } else {
    window?.setSize(na.Size(width: 1360, height: 840), false);
  }
  window?.show();
  window?.focus();

  // 再双击一次图标（第二个实例被拦下后会写唤醒信号）：把自己拉回前台，
  // 即使当前是「关到托盘」的隐藏状态也能唤出。
  SingleInstance.i.watchForActivate(() {
    window?.show();
    window?.focus();
  });

  // 记住窗口大小/位置（防抖保存：拖拽期间最多只挂一个定时器，减少开销）
  Timer? boundsTimer;
  void saveBounds() {
    if (boundsTimer != null) return;
    boundsTimer = Timer(const Duration(milliseconds: 700), () {
      boundsTimer = null;
      final b = window?.bounds;
      if (b == null) return;
      SettingsStore.write('winX', b.x.toStringAsFixed(0));
      SettingsStore.write('winY', b.y.toStringAsFixed(0));
      SettingsStore.write('winW', b.width.toStringAsFixed(0));
      SettingsStore.write('winH', b.height.toStringAsFixed(0));
    });
  }

  window?.addListener((event) {
    // 关闭窗口一律最小化到托盘（真正的「退出」由托盘菜单完成，
    // 那边直接 DestroyWindow，不会被这里拦截）。
    if (event is na.WindowCloseRequestedEvent) {
      saveBounds();
      event.request.cancel();
      window?.hide();
      return;
    }
    if (event is na.WindowResizedEvent || event is na.WindowMovedEvent) {
      saveBounds();
    }
  });

  // ---- 托盘 ----
  // 托盘图标与右键菜单由 Windows runner 的原生 Win32 实现负责
  // （windows/runner/main.cpp：Shell_NotifyIconW + CreatePopupMenu）。
  // nativeapi 的 TrayIcon 在本机 Windows 上只返回 visible=true 却不会真正
  // 注册到任务栏，因此不再使用它；菜单动作通过应用内快捷键触发。
  _trayLog('native Win32 tray is used (no dart tray)');

  // ---- 全局热键：Ctrl+Shift+Alt+N 呼出窗口 ----
  na.ShortcutManager.instance.registerWithAcceleratorAndCallback(
    'ctrl+shift+alt+n',
    () {
      window?.show();
      window?.focus();
    },
  );

  // ---- 开机自启 ----
  final launch = na.LaunchAtLogin.create();
  final autoStart = SettingsStore.readSync('autoStart', '0') == '1';
  if (launch != null) {
    if (autoStart) {
      launch.enable();
    } else {
      launch.disable();
    }
  }

  // ---- 局域网同步（NAS mynotes-sync 容器）----
  SyncService.i.start();

  runApp(_Root(initialNoteId: openId));
}

/// 演示/验收用示例数据（仅 MYNOTES_DEMO=1 时调用）
Future<void> _seedDemo() async {
  final existing = await NotesDb.listNotes(null);
  if (existing.isNotEmpty) return;
  final book = await NotesDb.createBook('示例笔记本', null, 'notebook');
  final tag = await NotesDb.createTag('示例标签');
  final samples = <List<String>>[
    [
      '欢迎使用我的笔记',
      '# 欢迎使用「我的笔记」\n\n'
          '这是一款**离线便携**的笔记软件，全界面使用内嵌的「方正宋黑」字体。\n\n'
          '## 主要功能\n\n'
          '- 笔记本与标签管理\n'
          '- Markdown 编辑 + 实时预览\n'
          '- 全文搜索、回收站、置顶\n'
          '- 托盘常驻与全局热键 `Ctrl+Shift+Alt+N`\n\n'
          '> 数据保存在程序目录的 data 文件夹，绿色便携。\n'
    ],
    [
      'Markdown 语法示例',
      '## 常用语法\n\n**粗体**、*斜体*、~~删除线~~、`行内代码`\n\n'
          '1. 有序列表第一项\n2. 第二项\n\n- 无序列表\n- 另一项\n\n'
          '```\n代码块示例\ndef hello():\n    print("hi")\n```\n\n'
          '[链接示例](https://example.com)\n'
    ],
    [
      '本周待办',
      '# 本周待办\n\n- [ ] 整理读书笔记\n- [ ] 备份笔记数据\n- [x] 试用新版软件\n'
    ],
  ];
  for (var i = 0; i < samples.length; i++) {
    final n = await NotesDb.createNote(book.id);
    n.title = samples[i][0];
    n.body = samples[i][1];
    n.plainText = NotesDb.markdownToPlainText(n.body);
    n.pinned = i == 0;
    await NotesDb.updateNote(n);
    await NotesDb.setTags(n.id, [tag.id]);
  }
  final trashNote = await NotesDb.createNote(book.id);
  trashNote.title = '过期草稿（示例）';
  trashNote.body = '这条笔记在回收站里，可以还原或彻底删除。';
  trashNote.plainText = trashNote.body;
  await NotesDb.updateNote(trashNote);
  await NotesDb.softDelete(trashNote.id);
}

class _Root extends StatefulWidget {
  final String? initialNoteId;
  const _Root({super.key, this.initialNoteId});

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  String _themeMode = 'system';

  @override
  void initState() {
    super.initState();
    _themeMode = SettingsStore.readSync('themeMode', 'system');
    NotesPage.themeChanged = _onThemeChanged;
  }

  void _onThemeChanged(String mode) {
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = switch (_themeMode) {
      'dark' => darkTheme(),
      'light' => lightTheme(),
      _ => lightTheme(),
    };
    return MaterialApp(
      title: '我的笔记',
      debugShowCheckedModeBanner: false,
      theme: theme,
      // 系统级中文本地化：日期/对话框/未显式指定 label 的文本选择按钮
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      // 全界面兜底：任何没显式写 fontFamily 的 Text 都继承方正宋黑 + w500，
      // 小字不再因为细笔画 + 浅灰而发虚，按钮/状态栏与列表标题观感一致。
      builder: (context, child) => DefaultTextStyle(
        style: _themeMode == 'dark' ? kDefaultTextStyleDark : kDefaultTextStyle,
        child: child ?? const SizedBox.shrink(),
      ),
      home: LockGate(child: NotesPage(initialNoteId: widget.initialNoteId)),
    );
  }
}

Future<void> _selfTest() async {
  final logFile = File(
      '${Platform.environment['MYNOTES_SELFTEST_LOG'] ?? 'C:\\Temp\\build\\selftest_result.txt'}');
  try {
    await NotesDb.init();
    logFile.writeAsStringSync('dataDir=${NotesDb.dataDir}\n');
    final ids = <String>[];
    // 连续新建 10 条笔记（验证新建功能始终可用）
    for (var i = 0; i < 10; i++) {
      final n = await NotesDb.createNote(null);
      if (n.id.isEmpty) throw StateError('createNote returned empty id');
      n.title = '自测笔记 $i';
      n.body = '# 标题 $i\n\n这是第 $i 篇笔记的内容。';
      n.plainText = NotesDb.markdownToPlainText(n.body);
      await NotesDb.updateNote(n);
      ids.add(n.id);
    }
    // 读回校验
    for (final id in ids) {
      final g = await NotesDb.getNote(id);
      if (g == null) throw StateError('note lost: $id');
      if (g.tags.length != g.tags.toSet().length) throw StateError('dup tags');
    }
    // 置顶
    final a = await NotesDb.getNote(ids.first);
    a!.pinned = true;
    await NotesDb.updateNote(a);
    final pinned = await NotesDb.listNotes(null);
    if (!pinned.first.pinned) throw StateError('pin failed');

    // 回收站流程
    final tmp = await NotesDb.createNote(null);
    await NotesDb.softDelete(tmp.id);
    final trashed = await NotesDb.listNotes(null, trash: true);
    if (!trashed.any((n) => n.id == tmp.id)) throw StateError('softDelete failed');
    await NotesDb.restore(tmp.id);
    final after = await NotesDb.listNotes(null, trash: true);
    if (after.any((n) => n.id == tmp.id)) throw StateError('restore failed');
    await NotesDb.purge(tmp.id);
    await NotesDb.clearTrash();

    // 笔记本 / 标签 / 搜索
    final book = await NotesDb.createBook('自测笔记本', null, 'notebook');
    await NotesDb.moveNote(ids.first, book.id);
    final t = await NotesDb.createTag('自测标签');
    await NotesDb.setTags(ids[1], [t.id]);
    final tagged = await NotesDb.notesWithTag(t.id);
    if (tagged.isEmpty) throw StateError('tag failed');
    final found = await NotesDb.searchNotes('自测笔记');
    if (found.length != 10) throw StateError('search failed: ${found.length}');

    logFile.writeAsStringSync('SELFTEST PASS\n', mode: FileMode.append);
    debugPrint('SELFTEST PASS');
    exit(0);
  } catch (e, st) {
    logFile.writeAsStringSync('SELFTEST FAIL: $e\n$st\n', mode: FileMode.append);
    debugPrint('SELFTEST FAIL: $e');
    exit(1);
  }
}
