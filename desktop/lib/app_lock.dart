import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/settings_page.dart';

/// 启动锁：4-6 位数字密码。
/// 只存「随机盐 + SHA-256」，明文密码与笔记数据都不写进任何配置文件。
const int kLockMinLen = 4;
const int kLockMaxLen = 6;
const int kLockMaxAttempts = 5;
const int kLockPenaltySeconds = 30;
const Color kLockAccent = Color(0xFFF97316);

/// 全局锁定信号：设置页「立即锁定」置 true，解锁后复位。
final ValueNotifier<bool> lockNowSignal = ValueNotifier<bool>(false);

class AppLock {
  AppLock._();

  static String get _salt => SettingsStore.readSync('lockSalt', '');
  static String get _hash => SettingsStore.readSync('lockHash', '');
  static int get length =>
      int.tryParse(SettingsStore.readSync('lockLen', '')) ?? 0;
  static bool get disabled =>
      SettingsStore.readSync('lockDisabled', '') == '1';
  static bool get enabled =>
      !disabled &&
      _hash.isNotEmpty &&
      _salt.isNotEmpty &&
      length >= kLockMinLen &&
      length <= kLockMaxLen;

  static String _digest(String pin, String salt) =>
      sha256.convert(utf8.encode('mynotes-lock|$salt|$pin')).toString();

  static String _newSalt() {
    final r = Random.secure();
    return List<int>.generate(24, (_) => r.nextInt(256))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static bool verify(String pin) => enabled && _digest(pin, _salt) == _hash;

  static Future<void> setPin(String pin) async {
    final s = _newSalt();
    await SettingsStore.write('lockSalt', s);
    await SettingsStore.write('lockHash', _digest(pin, s));
    await SettingsStore.write('lockLen', '${pin.length}');
    await SettingsStore.write('lockDisabled', '');
    await recordSuccess();
  }

  /// 关闭启动锁（笔记数据完全保留）。
  static Future<void> disable() async {
    for (final k in const [
      'lockSalt',
      'lockHash',
      'lockLen',
      'lockFail',
      'lockUntil'
    ]) {
      await SettingsStore.write(k, '');
    }
    await SettingsStore.write('lockDisabled', '1');
  }

  static int get fails =>
      int.tryParse(SettingsStore.readSync('lockFail', '')) ?? 0;

  static int get remainSeconds {
    final until =
        int.tryParse(SettingsStore.readSync('lockUntil', '')) ?? 0;
    final d = until - DateTime.now().millisecondsSinceEpoch;
    return d <= 0 ? 0 : (d / 1000).ceil();
  }

  /// 记一次失败，返回剩余可尝试次数；达到上限后进入 30 秒冷却。
  static Future<int> recordFail() async {
    final f = fails + 1;
    if (f >= kLockMaxAttempts) {
      await SettingsStore.write('lockFail', '0');
      await SettingsStore.write('lockUntil',
          '${DateTime.now().millisecondsSinceEpoch + kLockPenaltySeconds * 1000}');
      return 0;
    }
    await SettingsStore.write('lockFail', '$f');
    return kLockMaxAttempts - f;
  }

  static Future<void> recordSuccess() async {
    await SettingsStore.write('lockFail', '');
    await SettingsStore.write('lockUntil', '');
  }
}

/// 包在首页外面：未解锁时根本不构建笔记界面，笔记内容不进 widget 树。
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  late bool _unlocked;

  @override
  void initState() {
    super.initState();
    // 只有 explicitly 关闭过启动锁（lockDisabled=1）才直接放行；
    // 首次使用一律先设置密码，之后每次启动一律先解锁。
    _unlocked = AppLock.disabled;
    lockNowSignal.addListener(_onSignal);
  }

  @override
  void dispose() {
    lockNowSignal.removeListener(_onSignal);
    super.dispose();
  }

  void _onSignal() {
    if (lockNowSignal.value && AppLock.enabled && mounted) {
      setState(() => _unlocked = false);
    }
  }

  void _onDone() {
    lockNowSignal.value = false;
    if (mounted) setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    if (AppLock.disabled || !AppLock.enabled) {
      return _SetupLockPage(onDone: _onDone);
    }
    return _UnlockPage(onDone: _onDone);
  }
}

/// 锁屏通用外壳
Widget _lockShell({required Widget child}) {
  return Scaffold(
    backgroundColor: const Color(0xFFF5F6FA),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 400,
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                  color: Color.fromRGBO(20, 28, 50, 0.10),
                  blurRadius: 34,
                  offset: Offset(0, 12)),
            ],
          ),
          child: child,
        ),
      ),
    ),
  );
}

Widget _lockHeader(String title, String sub) {
  return Column(
    children: [
      Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: const Color.fromRGBO(249, 115, 22, 0.12),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(Icons.lock_outline_rounded,
            size: 34, color: kLockAccent),
      ),
      const SizedBox(height: 16),
      Text(title,
          style: const TextStyle(
              fontSize: 21, fontWeight: FontWeight.w700, color: Color(0xFF1F2430))),
      const SizedBox(height: 6),
      Text(sub,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Color(0xFF5A6474))),
      const SizedBox(height: 22),
    ],
  );
}

Widget _pinDots(int total, int filled) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: List.generate(total, (i) {
      final on = i < filled;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 7),
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? kLockAccent : Colors.white,
          border: Border.all(
              color: on ? kLockAccent : const Color(0xFFC9CEDA), width: 1.6),
        ),
      );
    }),
  );
}

Widget _numpad(void Function(String digit) onDigit, VoidCallback onClear,
    VoidCallback onBackspace, VoidCallback onSubmit, String submitLabel,
    {bool enabled = true}) {
  Widget key(String label, VoidCallback? onTap, {bool primary = false}) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: enabled ? onTap : null,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: primary ? kLockAccent : Colors.white,
            foregroundColor: primary ? Colors.white : const Color(0xFF1F2430),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: primary
                  ? BorderSide.none
                  : const BorderSide(color: Color(0xFFE1E5EE)),
            ),
            textStyle: TextStyle(
                fontSize: label.length > 1 ? 15 : 22,
                fontWeight: FontWeight.w600),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  final rows = <List<Widget>>[
    for (final r in const [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ])
      [for (final d in r) Expanded(child: key(d, () => onDigit(d)))],
  ];
  rows.add([
    Expanded(child: key('清空', onClear)),
    Expanded(child: key('0', () => onDigit('0'))),
    Expanded(child: key('⌫', onBackspace)),
  ]);

  return Column(
    children: [
      ...rows.map((r) => Row(children: r)),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        height: 46,
        child: ElevatedButton(
          onPressed: enabled ? onSubmit : null,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: kLockAccent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          child: Text(submitLabel),
        ),
      ),
    ],
  );
}

/// 让锁屏支持物理键盘：数字键 / 小键盘 / 退格 / 回车
KeyEventResult _handleLockKey(KeyEvent event, void Function(String) onDigit,
    VoidCallback onBackspace, VoidCallback onSubmit) {
  String? ch;
  if (event is KeyDownEvent) ch = event.character;
  if (event is KeyRepeatEvent) ch = event.character;
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (ch != null && ch.length == 1) {
    final c = ch.codeUnitAt(0);
    if (c >= 48 && c <= 57) {
      onDigit(String.fromCharCode(c));
      return KeyEventResult.handled;
    }
  }
  if (event.logicalKey == LogicalKeyboardKey.backspace) {
    onBackspace();
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter) {
    onSubmit();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

// ---------------------------------------------------------------------------
// 解锁
// ---------------------------------------------------------------------------
class _UnlockPage extends StatefulWidget {
  final VoidCallback onDone;
  const _UnlockPage({required this.onDone});

  @override
  State<_UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<_UnlockPage> {
  String _pin = '';
  String _error = '';
  int _remain = AppLock.remainSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_remain > 0) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      final r = AppLock.remainSeconds;
      if (r <= 0) {
        await AppLock.recordSuccess();
        t.cancel();
        if (mounted) setState(() { _remain = 0; _error = ''; });
      } else if (mounted) {
        setState(() => _remain = r);
      }
    });
  }

  void _add(String d) {
    if (_remain > 0 || _pin.length >= AppLock.length) return;
    setState(() {
      _pin += d;
      _error = '';
    });
    if (_pin.length == AppLock.length) _submit();
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_remain > 0 || _pin.length < kLockMinLen) return;
    if (AppLock.verify(_pin)) {
      await AppLock.recordSuccess();
      widget.onDone();
      return;
    }
    final left = await AppLock.recordFail();
    if (!mounted) return;
    setState(() {
      _pin = '';
      _error = left > 0
          ? '密码错误，还可尝试 $left 次'
          : '连续输错，已锁定 $kLockPenaltySeconds 秒';
      _remain = AppLock.remainSeconds;
    });
    if (_remain > 0) _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _remain > 0;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) => _handleLockKey(event, _add, _backspace, _submit),
      child: _lockShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _lockHeader('我的笔记', locked ? '请稍后再试' : '请输入启动密码解锁'),
            const SizedBox(height: 4),
            _pinDots(AppLock.length, _pin.length),
            const SizedBox(height: 14),
            SizedBox(
              height: 22,
              child: Text(
                locked ? '已锁定，$_remain 秒后可重试' : _error,
                style: const TextStyle(fontSize: 13, color: Color(0xFFD14343)),
              ),
            ),
            const SizedBox(height: 8),
            _numpad(
                _add,
                () => setState(() { _pin = ''; _error = ''; }),
                _backspace,
                _submit,
                '解锁',
                enabled: !locked),
            const SizedBox(height: 14),
            const Text('忘记密码：删除数据目录 settings.txt 中的 lockHash 行后重启（笔记保留）',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFF8A93A6))),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 首次设置
// ---------------------------------------------------------------------------
class _SetupLockPage extends StatefulWidget {
  final VoidCallback onDone;
  const _SetupLockPage({required this.onDone});

  @override
  State<_SetupLockPage> createState() => _SetupLockPageState();
}

class _SetupLockPageState extends State<_SetupLockPage> {
  int _step = 0;
  String _first = '';
  String _pin = '';
  String _error = '';

  void _add(String d) {
    if (_pin.length >= kLockMaxLen) return;
    setState(() { _pin += d; _error = ''; });
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < kLockMinLen || _pin.length > kLockMaxLen) {
      setState(() => _error = '请输入 4-6 位数字');
      return;
    }
    if (_step == 0) {
      _first = _pin;
      setState(() { _step = 1; _pin = ''; _error = ''; });
      return;
    }
    if (_pin != _first) {
      setState(() { _error = '两次输入不一致，请重新设置'; _step = 0; _first = ''; _pin = ''; });
      return;
    }
    await AppLock.setPin(_pin);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) => _handleLockKey(event, _add, _backspace, _submit),
      child: _lockShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _lockHeader('设置启动密码',
                _step == 0 ? '为保护笔记隐私，请设置 4-6 位数字密码' : '请再输入一次以确认'),
            _pinDots(kLockMaxLen, _pin.length),
            const SizedBox(height: 14),
            SizedBox(
              height: 22,
              child: Text(_error,
                  style: const TextStyle(fontSize: 13, color: Color(0xFFD14343))),
            ),
            const SizedBox(height: 8),
            _numpad(
                _add,
                () => setState(() { _pin = ''; _error = ''; }),
                _backspace,
                _submit,
                _step == 0 ? '下一步' : '确认设置'),
            const SizedBox(height: 14),
            const Text('密码以加盐哈希保存在本机，不会上传；可在「设置 → 安全」中修改或关闭',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFF8A93A6))),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 设置页里的密码管理
// ---------------------------------------------------------------------------
Future<String?> askLockPinDialog(BuildContext context,
    {required String title, String? message}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (b) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(message,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF5A6474))),
            ),
          TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(kLockMaxLen),
            ],
            decoration: const InputDecoration(
                hintText: '4-6 位数字', counterText: '', border: OutlineInputBorder()),
            onSubmitted: (_) => Navigator.of(b).pop(ctrl.text),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(b).pop(), child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.of(b).pop(ctrl.text),
            child: const Text('确定')),
      ],
    ),
  );
}

void _notify(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> _setNewPin(BuildContext context) async {
  final a = await askLockPinDialog(context,
      title: '设置新的启动密码', message: '请输入 4-6 位数字，下次启动生效');
  if (a == null) return false;
  if (a.length < kLockMinLen || a.length > kLockMaxLen) {
    if (context.mounted) _notify(context, '密码长度必须为 4-6 位');
    return false;
  }
  final b = await askLockPinDialog(context, title: '再输入一次');
  if (b != a) {
    if (context.mounted) _notify(context, '两次输入不一致');
    return false;
  }
  await AppLock.setPin(a);
  return true;
}

Future<void> showLockSettingsDialog(BuildContext context) async {
  if (!AppLock.enabled) {
    await _setNewPin(context);
    return;
  }
  final choice = await showDialog<String>(
    context: context,
    builder: (b) => SimpleDialog(
      title: const Text('启动密码'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(b).pop('change'),
          child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('修改启动密码')),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(b).pop('disable'),
          child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('关闭启动锁', style: TextStyle(color: Colors.red))),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(b).pop(),
          child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('取消')),
        ),
      ],
    ),
  );
  if (choice == null) return;
  final old = await askLockPinDialog(context, title: '请输入当前启动密码');
  if (old == null) return;
  if (!AppLock.verify(old)) {
    if (context.mounted) _notify(context, '当前密码错误');
    return;
  }
  if (choice == 'change') {
    await _setNewPin(context);
  } else {
    await AppLock.disable();
    if (context.mounted) _notify(context, '启动锁已关闭，笔记数据保留');
  }
}
