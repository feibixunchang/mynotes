import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 生物识别解锁。
///
/// Windows 上走系统自带的 Windows Hello（`UserConsentVerifier`）：
/// 弹出的是系统凭据对话框，指纹 / 人脸 / PIN 都由系统自己校验，
/// 应用既拿不到指纹模板，也拿不到 PIN —— 只拿到「通过 / 未通过」。
///
/// 实现方式：用 PowerShell 承载 WinRT 调用。这样不需要额外的原生插件，
/// 也不会把任何凭据留在本进程里。macOS 上应换成 LocalAuthentication
/// （见仓库 docs/MACOS.md），这里返回不支持，由调用方隐藏入口。
class Biometrics {
  Biometrics._();

  /// 是否支持生物识别（结果缓存，避免每次解锁都探测）
  static bool? _available;
  static String _label = '生物识别';
  static String _lastReason = '';

  /// 界面按钮上显示的名字
  static String get label => _label;
  static String get lastReason => _lastReason;

  static void _log(String msg) {
    try {
      final dir = Directory('${_dataDir()}/notes-data');
      dir.createSync(recursive: true);
      File('${dir.path}/biometric.log').writeAsStringSync(
          '${DateTime.now().toIso8601String()} $msg\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  static String _dataDir() {
    try {
      // 避免强依赖 db.dart 的初始化顺序
      final exe = File(Platform.resolvedExecutable).parent.path;
      return exe;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  /// 平台是否具备「可能支持」的能力（不含运行时探测）
  static bool get platformLikely =>
      Platform.isWindows || Platform.isMacOS;

  /// PowerShell 调 WinRT 的公共前缀（取 AsTask 泛型方法）
  static const String _psHeader = r'''
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Security.Credentials.UI.UserConsentVerifier,Windows.Security.Credentials.UI,ContentType=WindowsRuntime]
$null=[Windows.Security.Credentials.UI.UserConsentVerifierAvailability,Windows.Security.Credentials.UI,ContentType=WindowsRuntime]
$asTask=([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
# 枚举 UserConsentVerifierResult 用类型字面量在 PowerShell 5.1 里解析不到，
# 下面统一通过反射拿它的 Type。
function Get-ResultType {
  $t=$null
  try { $t=[Windows.Security.Credentials.UI.UserConsentVerifier].Assembly.GetType('Windows.Security.Credentials.UI.UserConsentVerifierResult') } catch {}
  if (-not $t) {
    try {
      $m=[Windows.Security.Credentials.UI.UserConsentVerifier].GetMethods()|Where-Object{$_.Name -eq 'RequestVerificationAsync'}|Select-Object -First 1
      if ($m) { $t=$m.ReturnType.GetGenericArguments()[0] }
    } catch {}
  }
  return $t
}
''';

  /// 执行一段 PowerShell，返回 stdout（失败返回空串）
  ///
  /// 走「临时 .ps1 + -File」而不是 -EncodedCommand：
  /// PowerShell 5.1 只有带 BOM 的 UTF-8 才按 UTF-8 解析，中文提示才不会乱码，
  /// 报错信息也能原样拿到。
  static Future<String> _runPs(String body) async {
    final script = '$_psHeader\n$body\n';
    File? tmp;
    Process? p;
    try {
      tmp = File('${Directory.systemTemp.path}/mynotes_bio_'
          '${DateTime.now().microsecondsSinceEpoch}.ps1');
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)];
      tmp.writeAsBytesSync(bytes, flush: true);

      p = await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', tmp.path,
      ]);
      // PowerShell 的输出可能夹带 GBK 错误信息，不能按严格 UTF-8 解码
      const dec = Utf8Decoder(allowMalformed: true);
      final outF = p.stdout.transform(dec).join();
      final errF = p.stderr.transform(dec).join();
      final code = await p.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          try {
            p!.kill();
          } catch (_) {}
          return -1;
        },
      );
      final out = (await outF).trim();
      final err = (await errF).trim();
      if (code != 0 || out.isEmpty) {
        final flat = err.replaceAll(RegExp(r'\s+'), ' ');
        _log('PS exit=$code out=${out.length}B err=${flat.isEmpty ? '-' : (flat.length > 500 ? flat.substring(0, 500) : flat)}');
        return out;
      }
      return out;
    } catch (e) {
      _log('PS spawn failed: $e');
      try {
        p?.kill();
      } catch (_) {}
      return '';
    } finally {
      try {
        tmp?.deleteSync();
      } catch (_) {}
    }
  }

  /// 探测：系统是否已配置好可用的 Windows Hello
  static Future<bool> isAvailable({bool refresh = false}) async {
    if (!Platform.isWindows) {
      _available = false;
      return false;
    }
    if (!refresh && _available != null) return _available!;
    const body = r'''
$t=$asTask.MakeGenericMethod([Windows.Security.Credentials.UI.UserConsentVerifierAvailability]).Invoke($null,@([Windows.Security.Credentials.UI.UserConsentVerifier]::CheckAvailabilityAsync()))
$t.Wait(-1)|Out-Null
Write-Output ("RESULT:" + $t.Result.ToString())
''';
    final raw = await _runPs(body);
    final state = raw
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('RESULT:'), orElse: () => '')
        .replaceFirst('RESULT:', '');
    _log('availability=$state');
    _available = state == 'Available';
    switch (state) {
      case 'Available':
        _label = 'Windows Hello 解锁';
        _lastReason = '';
      case 'NotConfiguredForUser':
        _label = 'Windows Hello';
        _lastReason = '系统里还没有设置 Windows Hello（指纹/人脸/PIN）';
      case 'DeviceNotPresent':
        _label = 'Windows Hello';
        _lastReason = '这台设备没有可用的生物识别硬件';
      case 'DisabledByPolicy':
        _label = 'Windows Hello';
        _lastReason = '系统策略禁用了 Windows Hello';
      default:
        if (state.isEmpty) {
          _label = 'Windows Hello';
          _lastReason = '无法调用系统验证（PowerShell 不可用）';
        }
    }
    return _available!;
  }

  /// 弹出系统 Windows Hello 对话框进行验证。
  /// 只有系统返回 Verified 才算通过；其它情况一律视为未通过。
  static Future<bool> verify(String reason) async {
    if (!Platform.isWindows) return false;
    final safe = reason.replaceAll("'", "''");
    final body = '''
try {
  \$rt = Get-ResultType
  if (-not \$rt) { Write-Output 'ERR:找不到 UserConsentVerifierResult 类型'; exit }
  \$t=\$asTask.MakeGenericMethod(\$rt).Invoke(\$null,@([Windows.Security.Credentials.UI.UserConsentVerifier]::RequestVerificationAsync('$safe')))
  \$t.Wait(-1)|Out-Null
  Write-Output ("RESULT:" + \$t.Result.ToString())
} catch {
  Write-Output ("ERR:" + \$_.Exception.Message)
}
''';
    final raw = await _runPs(body);
    final flat = raw.replaceAll('\n', ' | ').replaceAll('\r', '');
    _log('verifyRaw(${raw.length}B)=${flat.length > 300 ? flat.substring(0, 300) : flat}');
    final result = raw
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('RESULT:') || l.startsWith('ERR:'),
            orElse: () => '')
        .replaceFirst('RESULT:', '');
    _log('verify=$result');
    if (result.startsWith('ERR:')) {
      _lastReason = '系统验证调用失败：${result.substring(4)}';
      return false;
    }
    _lastReason = switch (result) {
      'Verified' => '',
      'Canceled' => '已取消验证',
      'RetriesExhausted' => '尝试次数过多，请用密码解锁',
      'DeviceBusy' => '验证设备忙，请稍后再试',
      'NotConfiguredForUser' => '系统里还没有设置 Windows Hello',
      'DeviceNotPresent' => '找不到可用的生物识别设备',
      'DisabledByPolicy' => '系统策略禁用了 Windows Hello',
      '' => '验证超时或窗口被关闭，请重试',
      _ => '验证未通过，请用密码解锁',
    };
    return result == 'Verified';
  }

  @visibleForTesting
  static void resetCache() => _available = null;
}
