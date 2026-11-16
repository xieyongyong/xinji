import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ocr_models.dart';

/// 一张图的识别结果
class RecognizedText {
  final List<RawLine> lines;
  final String fullText;
  RecognizedText(this.lines, this.fullText);
}

/// OCR 失败（可直接展示给用户的中文原因）
class OcrException implements Exception {
  final String message;
  OcrException(this.message);
  @override
  String toString() => message;
}

/// 离线 OCR 服务。
///
/// 用 ML Kit 的中文识别模型：模型随 APK 打包，**完全离线、不联网**，
/// 工资数据一个字节都不出手机。
///
/// ## 为什么要分块识别（这是 v1 闪退的根因）
/// 工资条常是"长截图"：宽 1080、高 8000~15000 像素。
/// 整张丢给 ML Kit，它内部要生成同等尺寸的位图（1080×12000 ≈ 50MB），
/// 再叠加 Dart 侧 decode 的缓冲，**中低端机直接 OOM 被系统杀掉**，
/// 表现就是"选完图片瞬间闪退"，Dart 层连异常都来不及抛。
///
/// 解决办法：把长图竖直切成 1600px 高的小块（相邻块重叠 120px 防止切字），
/// 逐块识别后按 y 偏移拼回去，最后去掉重叠区的重复行。
/// 峰值内存从"整张"降到"一块"，同时识别准确率反而更高
/// （ML Kit 对超长图本来就会降采样）。
class OcrService {
  TextRecognizer? _recognizer;

  /// 单块高度：1600 是实测的平衡点，太小会切碎表格行，太大省不了内存
  static const int _tileHeight = 1600;

  /// 相邻块重叠高度：保证跨块的一行文字至少完整出现在其中一块里
  static const int _tileOverlap = 120;

  /// 送进识别的图像最大宽度（再宽也不会提升准确率，只增加内存）
  static const int _maxWidth = 1600;

  /// 送进识别的图像最大总像素（超过就必须等比缩小，否则必崩）
  static const int _maxPixels = 12000000; // 12MP

  TextRecognizer get _engine {
    // ML Kit 初始化有成本，复用同一个实例
    _recognizer ??= TextRecognizer(script: TextRecognitionScript.chinese);
    return _recognizer!;
  }

  /// 识别一张图，返回带坐标的文本片段
  Future<RecognizedText> recognizeFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw OcrException('图片文件不存在，可能已被系统清理');
    }

    img.Image? decoded;
    try {
      decoded = img.decodeImage(await file.readAsBytes());
    } catch (_) {
      decoded = null;
    }

    // 解不出来（格式特殊）就交给 ML Kit 直接读原文件，别让流程卡死
    if (decoded == null) {
      final raw = await _recognizeSingleFile(path);
      return raw;
    }

    final prepared = _shrinkForOcr(decoded);
    final w = prepared.width;
    final h = prepared.height;

    // 不太高：整张识别，少写临时文件
    if (h <= _tileHeight + _tileOverlap) {
      final bytes = img.encodeJpg(prepared, quality: 90);
      return _recognizeJpegBytes(bytes, index: 0);
    }

    // 长截图：竖直分块
    final lines = <RawLine>[];
    final textParts = <String>[];
    var top = 0;
    var index = 0;

    while (top < h) {
      final bottom = math.min(top + _tileHeight, h);
      final tileH = bottom - top;
      if (tileH <= 8) break; // 末尾残条，忽略

      final tile = img.copyCrop(prepared, x: 0, y: top, width: w, height: tileH);
      final bytes = img.encodeJpg(tile, quality: 90);
      final part = await _recognizeJpegBytes(bytes, index: index);

      for (final line in part.lines) {
        lines.add(RawLine(
          text: line.text,
          left: line.left,
          top: line.top + top,
          right: line.right,
          bottom: line.bottom + top,
        ));
      }
      textParts.add(part.fullText);

      if (bottom >= h) break;
      top = bottom - _tileOverlap;
      index++;
      // 让出一次事件循环，避免长时间占满主线程导致界面假死
      await Future<void>.delayed(Duration.zero);
    }

    return RecognizedText(_dedupeOverlap(lines), textParts.join('\n'));
  }

  /// 按宽度与总像素双重限制缩小（只缩不放）
  img.Image _shrinkForOcr(img.Image src) {
    var out = src;
    if (out.width > _maxWidth) {
      out = img.copyResize(out, width: _maxWidth, interpolation: img.Interpolation.linear);
    }
    final pixels = out.width * out.height;
    if (pixels > _maxPixels) {
      final scale = math.sqrt(_maxPixels / pixels);
      final newW = math.max(1, (out.width * scale).round());
      out = img.copyResize(out, width: newW, interpolation: img.Interpolation.linear);
    }
    return out;
  }

  /// 把 JPEG 字节写成临时文件再交给 ML Kit。
  ///
  /// 为什么不用 InputImage.fromBytes：那条路要求传原始像素格式（nv21/bgra8888），
  /// 得自己转换格式，反而更容易出错；写临时文件多一次磁盘 IO 但最稳。
  Future<RecognizedText> _recognizeJpegBytes(List<int> bytes, {required int index}) async {
    Directory? tmpDir;
    File? tmpFile;
    try {
      tmpDir = await getTemporaryDirectory();
      tmpFile = File(p.join(tmpDir.path, 'ocr_tile_${DateTime.now().microsecondsSinceEpoch}_$index.jpg'));
      await tmpFile.writeAsBytes(bytes, flush: true);
      return await _recognizeSingleFile(tmpFile.path);
    } finally {
      if (tmpFile != null) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {
          // 临时文件删不掉不影响识别
        }
      }
    }
  }

  Future<RecognizedText> _recognizeSingleFile(String path) async {
    final input = InputImage.fromFilePath(path);
    final TextRecognitionResult result;
    try {
      result = await _engine.processImage(input);
    } catch (e) {
      throw OcrException('文字识别失败：$e');
    }

    final lines = <RawLine>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        final rect = line.boundingBox;
        lines.add(RawLine(
          text: text,
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
        ));
      }
    }
    return RecognizedText(lines, result.text);
  }

  /// 去掉分块重叠区被重复识别的行。
  ///
  /// 判重条件：文字完全相同，且纵向位置相差不到 40px（同一行）。
  /// 只跟"最近若干行"比，避免 O(n²) 在大图上变慢。
  List<RawLine> _dedupeOverlap(List<RawLine> lines) {
    final kept = <RawLine>[];
    for (final line in lines) {
      var duplicate = false;
      final start = math.max(0, kept.length - 60);
      for (var i = start; i < kept.length; i++) {
        final prev = kept[i];
        if (prev.text == line.text && (prev.top - line.top).abs() < 40) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) kept.add(line);
    }
    return kept;
  }

  /// 把用户选的图复制进应用私有目录，顺便压缩。
  ///
  /// 压缩策略要注意：工资条截图往往是**长截图**（宽 1080、高 5000+）。
  /// 如果按"长边压到 1600"会把宽度压到 200 多，字全糊了，OCR 直接废掉。
  /// 所以只限制**宽度**上限，高度不限；另外加一道总像素保险，
  /// 防止极端长图在解码/编码阶段就吃光内存。
  Future<String> importImage(File source, {String? fileNameHint}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imageDir = Directory(p.join(docsDir.path, 'slips'));
    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final targetName = '${stamp}_${fileNameHint ?? 'slip'}.jpg';
    final targetPath = p.join(imageDir.path, targetName);

    try {
      final raw = await source.readAsBytes();
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        // 解不出来（格式怪）就直接原样拷贝，保证不丢用户数据
        await File(targetPath).writeAsBytes(raw);
        return targetPath;
      }

      img.Image output = decoded;
      const maxWidth = 1600;
      if (decoded.width > maxWidth) {
        output = img.copyResize(decoded, width: maxWidth, interpolation: img.Interpolation.linear);
      }
      // 存档也设一道像素上限（24MP），保证打开大图时不会瞬时爆内存
      const maxStorePixels = 24000000;
      final pixels = output.width * output.height;
      if (pixels > maxStorePixels) {
        final scale = math.sqrt(maxStorePixels / pixels);
        output = img.copyResize(output,
            width: math.max(1, (output.width * scale).round()),
            interpolation: img.Interpolation.linear);
      }

      final jpg = img.encodeJpg(output, quality: 88);
      await File(targetPath).writeAsBytes(jpg);
      return targetPath;
    } catch (_) {
      // 任何异常都退回原始拷贝，宁可占空间也不能让用户丢原图
      await source.copy(targetPath);
      return targetPath;
    }
  }

  void dispose() {
    _recognizer?.close();
    _recognizer = null;
  }
}
