import 'dart:io';

import 'package:flutter/material.dart';

import '../app_lock.dart';
import '../app_version.dart';
import '../biometrics.dart';
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

  // 同步设置：地址与令牌直接可编辑，保存后立刻重连（不必再改 settings.txt）
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  bool _showToken = false;
  bool _testing = false;
  String? _testMsg;

  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _themeMode = SettingsStore.readSync('themeMode', 'system');
    _urlCtrl = TextEditingController(text: SyncService.i.baseUrl);
    _tokenCtrl = TextEditingController(text: SyncService.i.token);
    _probeBio();
  }

  Future<void> _probeBio() async {
    final ok = await Biometrics.isAvailable();
    if (!mounted) return;
    setState(() => _bioAvailable = ok);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _testSync() async {
    setState(() => _testing = true);
    final msg = await SyncService.i
        .testConnection(url: _urlCtrl.text, token: _tokenCtrl.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testMsg = msg;
    });
  }

  Future<void> _saveSync() async {
    final url = SyncService.normalizeUrl(_urlCtrl.text);
    if (url.isEmpty) {
      _toast('请填写同步服务器地址');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _toast('地址格式不正确，例如 http://NAS的IP:2581');
      return;
    }
    final oldUrl = SyncService.i.baseUrl;
    final token = _tokenCtrl.text.trim();
    await SettingsStore.write('syncUrl', url);
    await SettingsStore.write('syncToken', token);
    _urlCtrl.text = url;
    // 换服务器才重置游标并完整重推；仅改令牌时保留增量状态
    await SyncService.i.applyConfig(refresh: url != oldUrl);
    _toast('已保存，正在连接 $url');
    if (mounted) setState(() => _testMsg = null);
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
            child: Text('同步（NAS / 局域网）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _urlCtrl,
                  style: const TextStyle(fontSize: 14),
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '同步服务器地址',
                    hintText: 'http://NAS的IP:2581',
                    helperText: '形如 http://IP:端口，不要带结尾斜杠',
                    helperStyle: TextStyle(fontSize: 11),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenCtrl,
                  style: const TextStyle(fontSize: 14),
                  obscureText: !_showToken,
                  decoration: InputDecoration(
                    labelText: '访问令牌',
                    hintText: '服务端未启用令牌时留空',
                    helperText: '需与服务端 SYNC_TOKEN 一致；留空表示免令牌',
                    helperStyle: const TextStyle(fontSize: 11),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _showToken ? '隐藏' : '显示',
                      icon: Icon(
                        _showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _testSync,
                      icon: const Icon(Icons.wifi_tethering_rounded, size: 17),
                      label: Text(_testing ? '测试中…' : '测试连接',
                          style: const TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _saveSync,
                      icon: const Icon(Icons.check_rounded, size: 17),
                      label: const Text('保存并重连', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                if (_testMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _testMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testMsg!.startsWith('连接成功')
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFC62828),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 实时状态：直接听 SyncService，其它页面同步后这里也会跟着变
          AnimatedBuilder(
            animation: SyncService.i,
            builder: (_, __) {
              final s = SyncService.i;
              final ok = s.lastOk;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Icon(
                      ok ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      size: 16,
                      color: ok ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${s.resultText} · ${s.live ? "实时连接中" : "轮询模式"}'
                        '${s.atMs != null ? " · ${s.formatTime(s.atMs)}" : ""}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '换到另一台服务器时，本机全部笔记会作为一次完整推送发过去；'
              '清空笔记请用下方「删除所有笔记」，会在两端同时生效。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5),
            ),
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
          SwitchListTile(
            dense: true,
            secondary: Icon(
              Icons.fingerprint_rounded,
              size: 20,
              color: _bioAvailable ? kLockAccent : const Color(0xFFB6BCC9),
            ),
            title: const Text('用生物识别解锁', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _bioAvailable
                  ? '${Biometrics.label}：指纹 / 人脸 / PIN 由系统校验，应用不接触任何凭据'
                  : (Biometrics.lastReason.isEmpty
                      ? '这台设备暂不支持生物识别'
                      : Biometrics.lastReason),
              style: const TextStyle(fontSize: 12),
            ),
            value: _bioAvailable && AppLock.bioEnabled,
            onChanged: _bioAvailable
                ? (v) async {
                    await SettingsStore.write('bioUnlock', v ? '1' : '0');
                    if (mounted) setState(() {});
                  }
                : null,
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
