import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';
import 'money.dart';

/// 全局用户偏好。
///
/// 只放"影响显示与计算规则"的小配置，业务数据一律在 SQLite 里。
class AppSettings extends ChangeNotifier {
  static const _kPerfAuto = 'perf_auto';
  static const _kUpColor = 'color_up';
  static const _kDownColor = 'color_down';
  static const _kCompressImages = 'compress_images';
  static const _kDeWatermark = 'de_watermark';
  static const _kSeedIndex = 'theme_seed_index';
  static const _kThemeMode = 'theme_mode'; // 0=system 1=light 2=dark
  static const _kPrivacyMask = 'privacy_mask';
  static const _kLockDelay = 'lock_delay_seconds';
  static const _kHideAmounts = 'hide_amounts';
  static const _kFloatingLock = 'floating_lock';
  static const _kFloatingLockSize = 'floating_lock_size';
  // 贴边档位：0=贴边(1/2出屏) 1=微贴边(1/3) 2=不贴边(完整显示)
  static const _kFloatingLockEdge = 'floating_lock_edge';
  static const _kCloudAuto = 'cloud_auto_backup';
  static const _kCloudAutoDay = 'cloud_auto_backup_day';
  static const _kCloudAutoLast = 'cloud_auto_backup_last_at';
  static const _kCloudAutoTry = 'cloud_auto_backup_last_try';

  /// 绩效工资是否按「基本绩效 × 绩效系数」自动计算
  bool perfAuto = false;

  /// 保存工资条图片时是否压缩。
  ///
  /// 默认开（省空间）。关掉后原图入库：截图本来就是最好的一份"原始凭证"，
  /// 重新编码一次总会损失细节，有人宁愿多占空间也要原样留着。
  bool compressImages = true;

  /// 识别前是否刷掉浅灰水印。
  ///
  /// 默认开。极少数图（正文里有很浅的灰色小字）可能被一起刷白，
  /// 那时候关掉重试即可 —— 有这个开关，用户就不用等我改代码。
  bool deWatermark = true;

  /// 上涨颜色（默认红，符合国内习惯）
  int upColorValue = 0xFFC62828;

  /// 下跌颜色（默认绿）
  int downColorValue = 0xFF2E7D32;

  /// 主题配色序号（对应 kSeedSchemes），默认 0=靛蓝
  int seedIndex = 0;

  /// 深浅模式：0=跟随系统 1=浅色 2=深色
  int themeMode = 0;

  /// 切后台时是否盖住整屏（最近任务里看不到工资内容）。默认开。
  bool privacyMask = true;

  /// 切后台多久回来要重新验证：0=立即，15/30/60/300 秒。
  int lockDelaySeconds = 30;

  /// 金额打码：把界面上的金额显示成 ¥****（不影响导出和录入）
  bool hideAmounts = false;

  /// 应用内悬浮锁定按钮：半透明渐变、可拖动、吸附屏幕两侧，点一下立即上锁。
  /// 只在启用应用锁时才有意义。默认关。
  bool floatingLock = false;

  /// 悬浮按钮直径（dp）。档位 40~68，默认 52。
  int floatingLockSize = 52;

  /// 悬浮按钮贴边档位：0=贴边(约1/2出屏) 1=微贴边(约1/3) 2=不贴边(完整在屏内)。默认 0。
  /// 用户希望锁图标跟随底层一起被屏幕边缘裁掉一部分，比整图标露出更自然。
  int floatingLockEdge = 0;

  /// 贴边档位可选文案，设置弹框的分段控件直接用它。
  static const floatingLockEdgeLabels = <int, String>{
    0: '贴边',
    1: '微贴',
    2: '不贴',
  };

  /// 把任意整数夹到 0~2，避免老配置/手改配置越界。
  static int normalizeFloatingLockEdge(int v) => v < 0 ? 0 : (v > 2 ? 2 : v);

  /// 把任意整数夹到 40~68 且对齐到 4 的倍数，避免老配置/手改配置越界。
  static int normalizeFloatingLockSize(int v) {
    if (v < 40) return 40;
    if (v > 68) return 68;
    return 40 + ((v - 40) / 4).round() * 4;
  }

  /// 每月自动备份到云盘
  bool cloudAutoBackup = false;

  /// 每月几号备份（1-28；不给 29-31 是因为二月没有，选 31 号会整月不触发）
  int cloudAutoBackupDay = 1;

  /// 上次**成功**自动备份的时间（毫秒）。判断"本月做过了没"用它。
  int cloudAutoBackupLastAt = 0;

  /// 上次**尝试**自动备份的时间（毫秒），失败退避用
  int cloudAutoBackupLastTry = 0;

  /// 上次自动备份失败的原因（成功后清空）
  String cloudAutoBackupError = '';

  /// 1-28，超出范围一律夹回来
  static int normalizeBackupDay(int day) => day < 1 ? 1 : (day > 28 ? 28 : day);

  ThemeMode get materialThemeMode {
    if (themeMode == 1) return ThemeMode.light;
    if (themeMode == 2) return ThemeMode.dark;
    return ThemeMode.system;
  }

  Color get upColor => Color(upColorValue);
  Color get downColor => Color(downColorValue);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    perfAuto = sp.getBool(_kPerfAuto) ?? false;
    upColorValue = sp.getInt(_kUpColor) ?? 0xFFC62828;
    downColorValue = sp.getInt(_kDownColor) ?? 0xFF2E7D32;
    compressImages = sp.getBool(_kCompressImages) ?? true;
    deWatermark = sp.getBool(_kDeWatermark) ?? true;
    seedIndex = sp.getInt(_kSeedIndex) ?? 0;
    themeMode = sp.getInt(_kThemeMode) ?? 0;
    privacyMask = sp.getBool(_kPrivacyMask) ?? true;
    lockDelaySeconds = sp.getInt(_kLockDelay) ?? 30;
    hideAmounts = sp.getBool(_kHideAmounts) ?? false;
    kMaskAmounts = hideAmounts;
    floatingLock = sp.getBool(_kFloatingLock) ?? false;
    floatingLockSize = normalizeFloatingLockSize(sp.getInt(_kFloatingLockSize) ?? 52);
    floatingLockEdge = normalizeFloatingLockEdge(sp.getInt(_kFloatingLockEdge) ?? 0);
    cloudAutoBackup = sp.getBool(_kCloudAuto) ?? false;
    cloudAutoBackupDay = normalizeBackupDay(sp.getInt(_kCloudAutoDay) ?? 1);
    cloudAutoBackupLastAt = sp.getInt(_kCloudAutoLast) ?? 0;
    cloudAutoBackupLastTry = sp.getInt(_kCloudAutoTry) ?? 0;
    // 错误只在内存里（不落盘、不进备份），重载时清掉
    cloudAutoBackupError = '';
    _syncPalette();
    notifyListeners();
  }

  /// 「切后台重新锁定」的可选档位（秒）。0 表示切走就锁。
  static const lockDelayOptions = <int, String>{
    0: '立即锁定',
    15: '15 秒',
    30: '30 秒',
    60: '1 分钟',
    300: '5 分钟',
  };

  String get lockDelayLabel => lockDelayOptions[lockDelaySeconds] ?? '$lockDelaySeconds 秒';

  /// 把当前偏好同步给全局调色板（语义色 getter 从这里读）。
  /// platformBrightness 在 App 启动时用系统值；切模式后 MaterialApp 会 rebuild。
  void _syncPalette() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    applyAppTheme(seedIndex: seedIndex, mode: materialThemeMode, platformBrightness: platform);
  }

  Future<void> setSeedIndex(int v) async {
    seedIndex = v < 0 || v >= kSeedSchemes.length ? 0 : v;
    _syncPalette();
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kSeedIndex, seedIndex);
  }

  Future<void> setThemeMode(int v) async {
    themeMode = v < 0 || v > 2 ? 0 : v;
    _syncPalette();
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kThemeMode, themeMode);
  }

  Future<void> setPrivacyMask(bool v) async {
    privacyMask = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrivacyMask, v);
    // 遮罩完全由 Flutter 绘制（见 main.dart 的 _PrivacyMask），
    // 不再需要像原生推 FLAG_SECURE 那样同步开关。
  }

  Future<void> setFloatingLock(bool v) async {
    floatingLock = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kFloatingLock, v);
  }

  Future<void> setFloatingLockSize(int v) async {
    floatingLockSize = normalizeFloatingLockSize(v);
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kFloatingLockSize, floatingLockSize);
  }

  Future<void> setFloatingLockEdge(int v) async {
    floatingLockEdge = normalizeFloatingLockEdge(v);
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kFloatingLockEdge, floatingLockEdge);
  }

  Future<void> setLockDelay(int seconds) async {
    lockDelaySeconds = lockDelayOptions.containsKey(seconds) ? seconds : 30;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLockDelay, lockDelaySeconds);
  }

  Future<void> setHideAmounts(bool v) async {
    hideAmounts = v;
    kMaskAmounts = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kHideAmounts, v);
  }

  Future<void> setCloudAutoBackup(bool v) async {
    cloudAutoBackup = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kCloudAuto, v);
  }

  Future<void> setCloudAutoBackupDay(int day) async {
    cloudAutoBackupDay = normalizeBackupDay(day);
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kCloudAutoDay, cloudAutoBackupDay);
  }

  /// 记录一次尝试（失败退避用）
  Future<void> markCloudAutoBackupTry() async {
    cloudAutoBackupLastTry = DateTime.now().millisecondsSinceEpoch;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kCloudAutoTry, cloudAutoBackupLastTry);
  }

  /// 备份成功：记下时间、清掉上次的错误
  Future<void> markCloudAutoBackupDone() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    cloudAutoBackupLastAt = now;
    cloudAutoBackupLastTry = now;
    cloudAutoBackupError = '';
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kCloudAutoLast, cloudAutoBackupLastAt);
    await sp.setInt(_kCloudAutoTry, now);
  }

  /// 备份失败：只留在页面上给人看，不弹窗打断
  Future<void> markCloudAutoBackupError(String message) async {
    cloudAutoBackupError = message;
    notifyListeners();
  }

  Future<void> setCompressImages(bool v) async {
    compressImages = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kCompressImages, v);
  }

  Future<void> setDeWatermark(bool v) async {
    deWatermark = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kDeWatermark, v);
  }

  Future<void> setPerfAuto(bool v) async {
    perfAuto = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPerfAuto, v);
  }

  Future<void> setUpColor(int argb) async {
    upColorValue = argb;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kUpColor, argb);
  }

  Future<void> setDownColor(int argb) async {
    downColorValue = argb;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kDownColor, argb);
  }

  /// 涨跌统一取色：正数用上涨色，负数用下跌色，0 用灰
  Color diffColor(int cents) {
    if (cents == 0) return const Color(0xFF8A8F8A);
    return cents > 0 ? upColor : downColor;
  }
}
