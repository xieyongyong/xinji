import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局用户偏好。
///
/// 只放"影响显示与计算规则"的小配置，业务数据一律在 SQLite 里。
class AppSettings extends ChangeNotifier {
  static const _kPerfAuto = 'perf_auto';
  static const _kUpColor = 'color_up';
  static const _kDownColor = 'color_down';
  static const _kCompressImages = 'compress_images';
  static const _kDeWatermark = 'de_watermark';
  static const _kOcrEngine = 'ocr_engine';

  /// 识别引擎：`ppocr`（PP-OCRv6，默认）/ `mlkit`（老的兼容模式）
  ///
  /// 留这个开关不是为了"以后再选"，而是引擎级的逃生门：
  /// PP-OCR 走 ONNX Runtime，个别机型/系统上如果加载不起来，
  /// 用户切回 ML Kit 就能继续用，不必等我发新版本。
  String ocrEngine = 'ppocr';

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

  Color get upColor => Color(upColorValue);
  Color get downColor => Color(downColorValue);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    perfAuto = sp.getBool(_kPerfAuto) ?? false;
    upColorValue = sp.getInt(_kUpColor) ?? 0xFFC62828;
    downColorValue = sp.getInt(_kDownColor) ?? 0xFF2E7D32;
    compressImages = sp.getBool(_kCompressImages) ?? true;
    deWatermark = sp.getBool(_kDeWatermark) ?? true;
    ocrEngine = sp.getString(_kOcrEngine) ?? 'ppocr';
    notifyListeners();
  }

  Future<void> setOcrEngine(String v) async {
    ocrEngine = v;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kOcrEngine, v);
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
