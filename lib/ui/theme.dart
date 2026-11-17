import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

/// 一套可选配色：只定义一个种子色，整套配色由 ColorScheme.fromSeed 派生。
class SeedScheme {
  final String name;
  final Color seed;
  const SeedScheme(this.name, this.seed);
}

/// 5 套预设主色。顺序即设置页里的顺序，index 存进 SharedPreferences，别随意调整。
const kSeedSchemes = <SeedScheme>[
  SeedScheme('靛蓝', Color(0xFF3F6FB5)),
  SeedScheme('墨绿', Color(0xFF2E7D6B)),
  SeedScheme('紫罗兰', Color(0xFF7B5EA7)),
  SeedScheme('暖橙', Color(0xFFB4671E)),
  SeedScheme('玫红', Color(0xFFB4434C)),
];

/// 涨跌色、收入/扣款色是语义色，不随主色方案变，避免"收入突然变紫"这种困惑。
const Color kUp = Color(0xFFC62828);
const Color kDown = Color(0xFF2E7D32);
const Color kIncome = Color(0xFF2E7D6B);
const Color kDeduction = Color(0xFFB45309);

/// 调色板：把散落在各页面的硬编码颜色收敛成一组语义色。
///
/// 浅色/深色各一套。所有 getter（kSurface/kTextPrimary...）都从 [appPalette] 读，
/// 切换主题时只要替换 appPalette，整棵树 rebuild 后自然取到新颜色。
class AppPalette {
  final bool dark;
  final Color seed;
  final ColorScheme scheme;

  late final Color scaffold =
      dark ? const Color(0xFF121417) : const Color(0xFFF7F8F7);
  late final Color surface = dark ? const Color(0xFF1E2225) : Colors.white;
  late final Color surfaceAlt =
      dark ? const Color(0xFF292E32) : const Color(0xFFF2F4F2);
  late final Color border =
      dark ? const Color(0xFF34393D) : const Color(0xFFEDEFED);
  late final Color divider =
      dark ? const Color(0xFF2C3134) : const Color(0xFFE6E8E6);

  late final Color textPrimary =
      dark ? const Color(0xFFECEFEC) : const Color(0xFF1B1C1B);
  late final Color textBody =
      dark ? const Color(0xFFD5DAD5) : const Color(0xFF3A3F3A);
  late final Color textMedium =
      dark ? const Color(0xFFA8AEA8) : const Color(0xFF6B6F6B);
  late final Color textSecondary =
      dark ? const Color(0xFF9AA09A) : const Color(0xFF8A8F8A);
  late final Color textHint =
      dark ? const Color(0xFF7E857E) : const Color(0xFFB0B5B0);
  late final Color textFaint =
      dark ? const Color(0xFF6B726B) : const Color(0xFFC4C9C4);

  late final Color warnBg =
      dark ? const Color(0xFF3A2E12) : const Color(0xFFFFF6E5);
  late final Color warnBorder =
      dark ? const Color(0xFF7A5E1E) : const Color(0xFFE9B949);
  late final Color warnIcon =
      dark ? const Color(0xFFD9A93A) : const Color(0xFF9A6B00);
  late final Color warnText =
      dark ? const Color(0xFFF0D18A) : const Color(0xFF6B4E00);
  late final Color warnLink =
      dark ? const Color(0xFFE8B95C) : const Color(0xFF8A6A1F);

  late final Color infoBg =
      dark ? const Color(0xFF12302C) : const Color(0xFFEAF3F1);
  late final Color infoText =
      dark ? const Color(0xFF9FD8CC) : const Color(0xFF3D5A54);

  late final Color income =
      dark ? const Color(0xFF6FCF97) : kIncome;
  late final Color deduction =
      dark ? const Color(0xFFE8A34A) : kDeduction;
  late final Color extra =
      dark ? const Color(0xFFE8A34A) : const Color(0xFF7A4B12);
  late final Color extraBg =
      dark ? const Color(0xFF3A2A12) : const Color(0xFFFDF1E7);

  AppPalette({required this.dark, required this.seed})
      : scheme = ColorScheme.fromSeed(seedColor: seed, brightness: dark ? Brightness.dark : Brightness.light);
}

AppPalette _current = AppPalette(dark: false, seed: kSeedSchemes.first.seed);
AppPalette get appPalette => _current;

/// 由 AppSettings.load()/setter 调用，切换配色与深浅模式。
void applyAppTheme({required int seedIndex, required ThemeMode mode, required Brightness platformBrightness}) {
  final i = seedIndex < 0 || seedIndex >= kSeedSchemes.length ? 0 : seedIndex;
  final dark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system && platformBrightness == Brightness.dark);
  _current = AppPalette(dark: dark, seed: kSeedSchemes[i].seed);
}

/// 按主色调生成 ThemeData。
ThemeData buildTheme({Brightness brightness = Brightness.light, int seedIndex = 0}) {
  final i = seedIndex < 0 || seedIndex >= kSeedSchemes.length ? 0 : seedIndex;
  final seed = kSeedSchemes[i].seed;
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final dark = brightness == Brightness.dark;
  final scaffold = dark ? const Color(0xFF121417) : const Color(0xFFF7F8F7);
  final onBg = dark ? const Color(0xFFECEFEC) : const Color(0xFF1B1C1B);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffold,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: scaffold,
      foregroundColor: onBg,
      titleTextStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: onBg),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF2C3134) : const Color(0xFFE6E8E6),
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// 下面这组 getter 供各页面使用：不再写 const Color(0xFF...)，统一走语义色。
Color get kSeed => appPalette.seed;
Color get kSurface => appPalette.surface;
Color get kSurfaceAlt => appPalette.surfaceAlt;
Color get kBorder => appPalette.border;
Color get kDivider => appPalette.divider;
Color get kScaffold => appPalette.scaffold;
Color get kTextPrimary => appPalette.textPrimary;
Color get kTextBody => appPalette.textBody;
Color get kTextMedium => appPalette.textMedium;
Color get kTextSecondary => appPalette.textSecondary;
Color get kTextHint => appPalette.textHint;
Color get kTextFaint => appPalette.textFaint;
Color get kWarnBg => appPalette.warnBg;
Color get kWarnBorder => appPalette.warnBorder;
Color get kWarnIcon => appPalette.warnIcon;
Color get kWarnText => appPalette.warnText;
Color get kWarnLink => appPalette.warnLink;
Color get kInfoBg => appPalette.infoBg;
Color get kInfoText => appPalette.infoText;
Color get kIncomeFg => appPalette.income;
Color get kDeductionFg => appPalette.deduction;
Color get kExtra => appPalette.extra;
Color get kExtraBg => appPalette.extraBg;

/// 卡片统一外观。跟随主题，深色下是深灰卡片而非白块。
BoxDecoration cardDecoration({double radius = 16}) => BoxDecoration(
      color: kSurface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kBorder),
      boxShadow: const [
        BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 2)),
      ],
    );

/// 金额文本样式（等宽数字，对齐好看）。默认色跟随主题前景。
TextStyle moneyStyle({
  double size = 20,
  FontWeight weight = FontWeight.w600,
  Color? color,
}) =>
    TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color ?? kTextPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
