import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局用户偏好。
///
/// 只放"影响显示与计算规则"的小配置，业务数据一律在 SQLite 里。
class AppSettings extends ChangeNotifier {
  static const _kPerfAuto = 'perf_auto';
  static const _kUpColor = 'color_up';
  static const _kDownColor = 'color_down';

  /// 绩效工资是否按「基本绩效 × 绩效系数」自动计算
  bool perfAuto = false;

  /// 上涨颜色（默认红，符合国内习惯）
  int upColorValue = 0xFFC62828;

  /// 下跌颜色（默认绿）
  int downColorValue = 0xFF2E7D32;

  Color get upColor => Color(upColorValue);
  Color get downColor => Color(downColorValue);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    perfAuto = sp.getBool(_kPerfAuto) ?? false;
    upColorValue = sp.getInt(_kUpColor) ?? 0xFFC62828;
    downColorValue = sp.getInt(_kDownColor) ?? 0xFF2E7D32;
    notifyListeners();
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
