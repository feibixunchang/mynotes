import 'dart:io';

import 'package:flutter/material.dart';

import '../app_lock.dart';
import '../app_version.dart';
import '../db.dart';
import '../sync.dart';

class SettingsPage extends StatefulWidget {
  final void Function(String mode)? onThemeChanged;
  const SettingsPage({super.key, this.onThemeChanged});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _themeMode = 'system';

  @override
  void initState() {
    super.initState();
    _themeMode = SettingsStore.readSync('themeMode', 'system');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('外观主题', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          RadioListTile<String>(
            value: 'system',
            groupValue: _themeMode,
            dense: true,
            title: const Text('跟随系统', style: TextStyle(fontSize: 14)),
            onChanged: (v) async {
              if (v == null) return;
              await SettingsStore.write('themeMode', v);
              if (mounted) setState(() => _themeMode = v);
              widget.onThemeChanged?.call(v);
            },
          ),
          RadioListTile<String>(
            value: 'light',
            groupValue: _themeMode,
            dense: true,
            title: const Text('浅色', style: TextStyle(fontSize: 14)),
            onChanged: (v) async {
              if (v == null) return;
              await SettingsStore.write('themeMode', v);
              if (mounted) setState(() => _themeMode = v);
              widget.onThemeChanged?.call(v);
            },
          ),
          RadioListTile<String>(
            value: 'dark',
            groupValue: _themeMode,
            dense: true,
            title: const Text('深色', style: TextStyle(fontSize: 14)),
            onChanged: (v) async {
              if (v == null) return;
              await SettingsStore.write('themeMode', v);
              if (mounted) setState(() => _themeMode = v);
              widget.onThemeChanged?.call(v);
            },
          ),
          const Divider(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('运行方式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('开机自启动', style: TextStyle(fontSize: 14)),
            value: SettingsStore.readSync('autoStart', '0') == '1',
            onChanged: (v) => SettingsStore.write('autoStart', v ? '1' : '0'),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('关闭窗口时最小化到托盘', style: TextStyle(fontSize: 14)),
            value: SettingsStore.readSync('closeToTray', '1') == '1',
            onChanged: (v) => SettingsStore.write('closeToTray', v ? '1' : '0'),
          ),
          const Divider(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('数据', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            dense: true,
            title: const Text('数据目录', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '${NotesDb.dataDir}\n${NotesDb.attachmentsDir}',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          ListTile(
            dense: true,
            title: const Text('清空回收站', style: TextStyle(fontSize: 14, color: Colors.red)),
            onTap: () async {
              await NotesDb.clearTrash();
              if (mounted) Navigator.of(context).pop();
            },
          ),
          ListTile(
            dense: true,
            title: const Text('删除所有笔记（含回收站）',
                style: TextStyle(fontSize: 14, color: Colors.red)),
            subtitle: const Text('本地与 NAS 网页版同时清空，不可恢复',
                style: TextStyle(fontSize: 12, color: Colors.red)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (b) => AlertDialog(
                  title: const Text('删除所有笔记'),
                  content: const Text(
                      '将永久删除全部笔记（包括回收站），并同步清空 NAS 网页版。此操作不可恢复。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(b).pop(false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.of(b).pop(true),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('全部删除')),
                  ],
                ),
              );
              if (ok != true) return;
              await NotesDb.clearAllNotes();
              await SyncService.i.clearRemote();
              if (mounted) Navigator.of(context).pop(true);
            },
          ),

          const Divider(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('安全', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.lock_outline_rounded, size: 20, color: kLockAccent),
            title: Text(AppLock.enabled ? '启动密码：已启用' : '启动密码：未启用',
                style: const TextStyle(fontSize: 14)),
            subtitle: Text(
                AppLock.enabled ? '每次启动需输入 4-6 位数字密码' : '建议启用，防止他人打开查看笔记',
                style: const TextStyle(fontSize: 12)),
            onTap: () async {
              await showLockSettingsDialog(context);
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            dense: true,
            title: const Text('立即锁定', style: TextStyle(fontSize: 14)),
            onTap: () {
              if (!AppLock.enabled) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请先设置启动密码')));
                return;
              }
              lockNowSignal.value = true;
              Navigator.of(context).pop();
            },
          ),
          const Divider(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('关于', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            dense: true,
            title: Text('我的笔记 v$kAppVersion（便携桌面版）',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text('构建时间 $kBuildStamp · 全界面字体：方正宋黑（GBK 内嵌）',
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 极简本地设置存储（settings.txt，随数据目录走）
class SettingsStore {
  static final Map<String, String> _cache = {};

  static String readSync(String key, String def) {
    if (_cache.containsKey(key)) return _cache[key]!;
    return _readFromDisk(key) ?? def;
  }

  static Future<String> read(String key, String def) async {
    return readSync(key, def);
  }

  static String? _readFromDisk(String key) {
    try {
      final file = File('${NotesDb.dataDir}/settings.txt');
      if (!file.existsSync()) return null;
      // settings.txt 可能由 Windows 工具写成 CRLF；split('\n') 会把 '\r'
      // 留在值里，若恰好是 syncToken 就会导致 HTTP 请求头非法（同步全失败）。
      for (final raw in file.readAsStringSync().split('\n')) {
        final l = raw.trimRight();
        final kv = l.split('=');
        if (kv.length == 2 && kv[0].trim() == key) return kv[1].trim();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> write(String key, String value) async {
    _cache[key] = value;
    try {
      final file = File('${NotesDb.dataDir}/settings.txt');
      final lines = <String>[];
      if (file.existsSync()) {
        for (final raw in file.readAsStringSync().split('\n')) {
          final l = raw.trimRight();
          if (l.trim().isNotEmpty && !l.startsWith('$key=')) lines.add(l);
        }
      }
      lines.add('$key=$value');
      // 统一写 LF，杜绝 CRLF 再污染值
      file.writeAsStringSync('${lines.join('\n')}\n');
    } catch (_) {}
  }
}
