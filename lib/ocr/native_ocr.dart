import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/crash_log.dart';
import 'ocr_models.dart';

/// 一张图的识别产物：带坐标的文本片段 + 整段纯文本。
///
/// 名字**刻意**不叫 RecognizedText —— 早期用 OCR 插件时，
/// 同名类型会把插件里的官方类型遮蔽掉，编译期报 "isn't a type"。
class OcrText {
  final List<RawLine> lines;
  final String fullText;
  OcrText(this.lines, this.fullText);
}

/// OCR 失败（可直接展示给用户的中文原因）
class OcrException implements Exception {
  final String message;
  OcrException(this.message);
  @override
  String toString() => message;
}

/// 文字识别的 Dart 入口。
///
/// ## 架构：识别在独立进程里跑
/// 原生侧 `OcrService`（`:ocr` 进程）负责分块 + 预处理 + PP-OCRv6 推理；
/// 主进程只通过 `xinji/ocr` 通道收发一份 JSON。
///
/// 这么拆是因为推理是 native 的（ONNX Runtime），在内存紧张的设备上
/// 死掉的时候 Dart 的 try/catch 根本抓不到 —— 用户看到的就是
/// 「导入图片瞬间闪退，日志一片空白」。
///
/// 隔离到独立进程后，那边崩了只是连接断开：这里收到一条普通错误，
/// 界面提示「可以手动填」，图片已经存好了，不用重新截图。
///
/// ## 返回格式
/// 原生返回一段 JSON：
/// ```json
/// {"ok": true, "images": [{"text": "...", "lines": [["实发工资", 12, 300, 220, 330]]}]}
/// ```
/// `lines` 里每项是 `[文字, left, top, right, bottom]`，
/// top 已经是**整图坐标系**（原生按分块偏移换算过），直接用即可。
class NativeOcr {
  static const MethodChannel _channel = MethodChannel('xinji/ocr');

  /// 通道是否可用（只有 Android 有原生实现）
  static bool get available => Platform.isAndroid;

  /// 识别一批图（一次绑定、一次回传，比逐张调用省事也省时间）。
  ///
  /// [deWatermark] = false 时不刷浅灰水印：留给"这张图没有水印、
  /// 但阈值把某个浅色小字也刷掉了"的情况兜底（设置里可关）。
  ///
  /// 引擎只有 PP-OCRv6 一个，没有可切换的备用引擎。
  ///
  /// 失败抛 [OcrException]；原生进程崩溃也算失败，不会带走 App。
  static Future<List<OcrText>> recognize(
    List<String> paths, {
    bool deWatermark = true,
  }) async {
    if (paths.isEmpty) return const <OcrText>[];
    if (!available) {
      throw OcrException('当前系统不支持离线文字识别');
    }

    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>('recognize', {
        'paths': paths,
        'deWatermark': deWatermark,
      });
    } on MissingPluginException {
      throw OcrException('识别组件没装好，请重新安装 App');
    } on PlatformException catch (e) {
      CrashLog.note('识别通道异常 ${e.code}: ${e.message}');
      throw OcrException(e.message ?? '识别失败');
    }

    if (raw == null || raw.isEmpty) {
      throw OcrException('识别没有返回结果');
    }

    Map<String, dynamic> root;
    try {
      root = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      throw OcrException('识别结果解析失败');
    }

    if (root['ok'] != true) {
      throw OcrException(root['error']?.toString() ?? '识别失败');
    }

    final images = (root['images'] as List?) ?? const [];
    final out = <OcrText>[];
    for (final item in images) {
      final map = (item as Map).cast<String, dynamic>();
      final lines = <RawLine>[];
      for (final row in (map['lines'] as List?) ?? const []) {
        final cells = row as List;
        if (cells.length < 5) continue;
        final text = cells[0]?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        lines.add(RawLine(
          text: text,
          left: _num(cells[1]),
          top: _num(cells[2]),
          right: _num(cells[3]),
          bottom: _num(cells[4]),
        ));
      }
      out.add(OcrText(lines, map['text']?.toString() ?? ''));
    }
    return out;
  }

  static double _num(Object? v) => v is num ? v.toDouble() : 0;
}
