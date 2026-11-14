import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

/// 主色：偏沉稳的墨绿，工资/账目类应用用这个色系不刺眼
const Color kSeed = Color(0xFF2E7D6B);

/// 中国习惯：涨用红、跌用绿（和欧美相反，别搞反）
const Color kUp = Color(0xFFC62828);
const Color kDown = Color(0xFF2E7D32);

/// 收入 / 扣款
const Color kIncome = Color(0xFF2E7D6B);
const Color kDeduction = Color(0xFFB45309);

/// 提示条底色
const Color kWarnBg = Color(0xFFFFF6E5);
const Color kWarnBorder = Color(0xFFE9B949);
const Color kInfoBg = Color(0xFFEAF3F1);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kSeed);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF7F8F7),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: Color(0xFFF7F8F7),
      foregroundColor: Color(0xFF1B1C1B),
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1B1C1B),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE6E8E6),
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 卡片统一外观，避免 Flutter 版本间 CardTheme 类型差异带来的编译问题
BoxDecoration cardDecoration({double radius = 16}) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFFEDEFED)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0A000000),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ],
    );

/// 金额文本样式（等宽数字，对齐好看）
TextStyle moneyStyle({
  double size = 20,
  FontWeight weight = FontWeight.w600,
  Color color = const Color(0xFF1B1C1B),
}) =>
    TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
