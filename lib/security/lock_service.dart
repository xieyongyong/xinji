import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用锁。
///
/// 设计取舍（和需求确认时一致）：
/// - **生物识别为主**：指纹/面容优先，日常几乎不用输 PIN
/// - **PIN 兜底**：生物识别不可用（湿手、传感器脏、没录入）时用
/// - **提示语找回**：忘记 PIN 时答对提示语可重设。这是本地 App 唯一可行的找回方式，
///   代价是提示语必须明文存（要显示在锁屏上）
/// - PIN 本身**只存加盐哈希，不存明文**
class LockService extends ChangeNotifier {
  static const _kEnabled = 'lock_enabled';
  static const _kPinHash = 'lock_pin_hash';
  static const _kPinSalt = 'lock_pin_salt';
  static const _kHint = 'lock_hint';
  static const _kBioEnabled = 'lock_bio_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

  /// 内存里的锁状态。冷启动、以及后台超过设定时长都会置为 true
  bool locked = false;

  /// 后台隐私遮罩：切后台时盖住整屏，最近任务的缩略图里看不到工资内容。
  /// 与 [locked] 无关 —— 没开应用锁也应该能遮，否则旁人在任务列表就能看到。
  bool masked = false;

  bool _enabled = false;
  String? _pinHash;
  String? _pinSalt;
  String? _hint;
  bool _bioEnabled = true;

  bool get enabled => _enabled;
  bool get bioEnabled => _bioEnabled;
  String? get hint => _hint;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _enabled = sp.getBool(_kEnabled) ?? false;
    _pinHash = sp.getString(_kPinHash);
    _pinSalt = sp.getString(_kPinSalt);
    _hint = sp.getString(_kHint);
    _bioEnabled = sp.getBool(_kBioEnabled) ?? true;
    locked = _enabled;
  }

  /// 是否为「首次设置」：还没走过设置引导
  bool get needsSetup => _pinHash == null;

  // ------------------------------------------------------------ 设置

  Future<void> setupPin({
    required String pin,
    required String hintText,
    required bool enableBiometric,
  }) async {
    final salt = _randomSalt();
    final hash = _hash(pin, salt);

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPinSalt, salt);
    await sp.setString(_kPinHash, hash);
    await sp.setString(_kHint, hintText);
    await sp.setBool(_kBioEnabled, enableBiometric);
    await sp.setBool(_kEnabled, true);

    _pinSalt = salt;
    _pinHash = hash;
    _hint = hintText;
    _bioEnabled = enableBiometric;
    _enabled = true;
    locked = false;
  }

  /// 答对提示语后重设 PIN（旧 PIN 不需要知道）
  Future<void> resetPinAfterHint({
    required String newPin,
    required String newHint,
  }) async {
    final salt = _randomSalt();
    final hash = _hash(newPin, salt);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPinSalt, salt);
    await sp.setString(_kPinHash, hash);
    await sp.setString(_kHint, newHint);
    _pinSalt = salt;
    _pinHash = hash;
    _hint = newHint;
    locked = false;
    // 找回 PIN 成功后必须通知，否则全局锁层不会撤掉。
    notifyListeners();
  }

  /// 校验提示语是否答对（忽略大小写与首尾空格）
  bool checkHint(String answer) {
    final h = (_hint ?? '').trim();
    if (h.isEmpty) return false;
    return h.toLowerCase() == answer.trim().toLowerCase();
  }

  Future<void> disable() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kEnabled, false);
    await sp.remove(_kPinHash);
    await sp.remove(_kPinSalt);
    await sp.remove(_kHint);
    _enabled = false;
    _pinHash = null;
    _pinSalt = null;
    _hint = null;
    locked = false;
  }

  /// 是否改过 PIN（设置页用）
  Future<bool> changePin({required String oldPin, required String newPin}) async {
    if (!verifyPin(oldPin)) return false;
    final salt = _randomSalt();
    final hash = _hash(newPin, salt);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPinSalt, salt);
    await sp.setString(_kPinHash, hash);
    _pinSalt = salt;
    _pinHash = hash;
    return true;
  }

  // ------------------------------------------------------------ 验证

  bool verifyPin(String pin) {
    if (_pinHash == null || _pinSalt == null) return false;
    final computed = _hash(pin, _pinSalt!);
    return _constantTimeEquals(computed, _pinHash!);
  }

  /// 设备是否支持并已录入生物识别
  Future<bool> canUseBiometric() async {
    if (!_bioEnabled) return false;
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return false;
      final available = await _auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 弹出指纹/面容验证
  Future<bool> authenticateBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: '验证身份以查看工资数据',
        options: const AuthenticationOptions(
          biometricOnly: false, // 允许回退到系统密码
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  void unlock() {
    if (!locked) return;
    locked = false;
    masked = false;
    notifyListeners();
  }

  void lockNow() {
    if (!_enabled) return;
    locked = true;
    masked = false;
    notifyListeners();
  }

  /// 进后台前调用：先盖一帧遮罩，系统再拍缩略图。
  void mask() {
    if (masked) return;
    masked = true;
    notifyListeners();
  }

  void unmask() {
    if (!masked) return;
    masked = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ 内部

  String _randomSalt() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Encode(bytes);
  }

  /// 加盐 + 12000 轮 SHA-256。手机上约 100~300ms，肉眼几乎无感，
  /// 但让暴力猜 PIN 的成本提高几个数量级。
  String _hash(String pin, String salt) {
    var digest = sha256.convert(utf8.encode('$salt|$pin')).bytes;
    final saltBytes = utf8.encode(salt);
    for (var i = 0; i < 12000; i++) {
      digest = sha256.convert([...digest, ...saltBytes]).bytes;
    }
    return base64Encode(digest);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
