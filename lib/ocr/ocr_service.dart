import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crash_log.dart';
import 'ocr_models.dart';
import 'slip_imaging.dart';

/// 一张图的识别结果。
///
/// 名字**不能**叫 RecognizedText —— google_mlkit_text_recognition 里正好有
/// 一个同名类型（processImage 的返回值），一旦同名就会把官方类型遮蔽掉，
/// 编译期报 "isn't a type"。这里用 OcrText，跟官方彻底错开。
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

/// 离线 OCR 服务。
///
/// 用 ML Kit 的中文识别模型：模型随 APK 打包，**完全离线、不联网**，
/// 工资数据一个字节都不出手机。
///
/// ## 为什么长截图必须分块（这是"选完图就闪退"的根因）
/// 工资条常是长截图：宽 1080、高 8000~15000 像素。
/// 整张丢给 ML Kit，它内部要生成同等尺寸的位图（1080×12000 ≈ 50MB），
/// 再叠加解码缓冲，**中低端机直接 OOM 被系统杀掉**，
/// 表现就是"选完图片瞬间闪退"，Dart 层连异常都来不及抛。
///
/// 所以这里**不在 Dart 里解码整图**，而是调原生
/// [SlipImaging.tiles]：Android 的 BitmapRegionDecoder 一次只解一块
/// （约 7MB），逐块识别后按 top 偏移拼回去，最后去掉重叠区的重复行。
///
/// 顺带修复了两个"看起来是 OCR 不准、其实是流程错"的问题：
/// - `image_picker` 传 imageQuality 会让插件在原生侧整图解码，
///   长截图在**拍照/选图阶段**就被 kill（跟识别无关，所以怎么优化识别都没用）
/// - 系数行（绩效系数 1.2）以前被 `hasAmount` 过滤掉，既不进明细也不参与
///   重叠比对，导致"两张图没有重叠"的误报
class OcrService {
  TextRecognizer? _recognizer;

  /// 单块高度：1400 是实测的平衡点，太小会切碎表格行，太大省不了内存
  static const int _tileHeight = 1400;

  /// 相邻块重叠高度：保证跨块的一行文字至少完整出现在其中一块里
  static const int _tileOverlap = 120;

  /// 送进识别的图像最大宽度（再宽也不会提升准确率，只增加内存）
  static const int _maxWidth = 1600;

  /// Dart 回退路径的图像最大总像素（超过必须等比缩小，否则必崩）
  static const int _maxPixels = 12000000; // 12MP

  TextRecognizer get _engine {
    // ML Kit 初始化有成本，复用同一个实例
    _recognizer ??= TextRecognizer(script: TextRecognitionScript.chinese);
    return _recognizer!;
  }

  /// 识别一张图，返回带坐标的文本片段
  Future<OcrText> recognizeFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw OcrException('图片文件不存在，可能已被系统清理');
    }

    // ---- 首选：原生分块。Android 上这条路径不会把整图读进内存
    final native = await _tryNativeTiles(path);
    if (native != null) return native;

    // ---- 回退：Dart 解码（小图 / 非 Android / 原生通道异常）
    return _recognizeInDart(path);
  }

  // ------------------------------------------------------------ 原生分块

  Future<OcrText?> _tryNativeTiles(String path) async {
    if (!SlipImaging.available) return null;

    final dir = await getTemporaryDirectory();
    final tag = 'ocrt${DateTime.now().microsecondsSinceEpoch}';

    List<SlipTile> tiles;
    try {
      tiles = await SlipImaging.tiles(
        path: path,
        outDir: dir.path,
        tag: tag,
        tileHeight: _tileHeight,
        overlap: _tileOverlap,
        maxWidth: _maxWidth,
      );
    } catch (e) {
      // 不是致命错：交给 Dart 回退再试一次，同时留条面包屑方便定位
      CrashLog.note('原生分块失败 ${p.basename(path)}: $e');
      return null;
    }

    CrashLog.note('分块识别 ${tiles.length} 块 · ${p.basename(path)}');
    try {
      final lines = <RawLine>[];
      final textParts = <String>[];

      for (var i = 0; i < tiles.length; i++) {
        final t = tiles[i];
        final part = await _recognizeSingleFile(t.path);
        for (final line in part.lines) {
          lines.add(RawLine(
            text: line.text,
            left: line.left,
            top: line.top + t.top,
            right: line.right,
            bottom: line.bottom + t.top,
          ));
        }
        textParts.add(part.fullText);
        // 让出一次事件循环，避免长时间占着主线程让界面假死
        await Future<void>.delayed(Duration.zero);
      }

      return OcrText(_dedupeOverlap(lines), textParts.join('\n'));
    } finally {
      await _cleanupTiles(tiles);
    }
  }

  Future<void> _cleanupTiles(List<SlipTile> tiles) async {
    for (final t in tiles) {
      try {
        final f = File(t.path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 临时文件删不掉不影响业务，系统会自己清
      }
    }
  }

  // ------------------------------------------------------------ Dart 回退

  /// 纯 Dart 路径。只在原生通道不可用时兜底，处理不了特别大的图，
  /// 所以先按文件大小拦一道，宁可给一句人话也不要 OOM。
  Future<OcrText> _recognizeInDart(String path) async {
    final file = File(path);
    final size = await file.length();
    if (size > 40 * 1024 * 1024) {
      throw OcrException(
        '这张图有 ${(size / 1024 / 1024).toStringAsFixed(0)}MB，'
        '超出安全处理范围。请重新截图（或裁掉空白部分）后再导入',
      );
    }

    img.Image? decoded;
    try {
      decoded = img.decodeImage(await file.readAsBytes());
    } catch (e) {
      CrashLog.note('Dart 解码异常 $e');
      decoded = null;
    }

    // 解不出来（HEIC/特殊格式）：先让原生压成一张有界的图再识别，
    // 绝不把原文件直接丢给 ML Kit —— 那正是旧版闪退的路径
    if (decoded == null) {
      final bounded = await _boundedTempCopy(path);
      if (bounded != null) {
        try {
          return await _recognizeSingleFile(bounded);
        } finally {
          try {
            final f = File(bounded);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      throw OcrException('这张图的格式识别不了，请用手机截图而不是原图，或换一张重试');
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
      await Future<void>.delayed(Duration.zero);
    }

    return OcrText(_dedupeOverlap(lines), textParts.join('\n'));
  }

  /// 用原生压出一张有界的临时图（宽度、像素都被限制），失败返回 null
  Future<String?> _boundedTempCopy(String path) async {
    if (!SlipImaging.available) return null;
    try {
      final dir = await getTemporaryDirectory();
      final dest = p.join(
          dir.path, 'ocrb_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final ok = await SlipImaging.compress(
        src: path,
        dest: dest,
        maxWidth: _maxWidth,
        maxPixels: _maxPixels,
        quality: 90,
      );
      return ok ? dest : null;
    } catch (_) {
      return null;
    }
  }

  /// 按宽度与总像素双重限制缩小（只缩不放）
  img.Image _shrinkForOcr(img.Image src) {
    var out = src;
    if (out.width > _maxWidth) {
      out = img.copyResize(out,
          width: _maxWidth, interpolation: img.Interpolation.linear);
    }
    final pixels = out.width * out.height;
    if (pixels > _maxPixels) {
      final scale = math.sqrt(_maxPixels / pixels);
      final newW = math.max(1, (out.width * scale).round());
      out = img.copyResize(out,
          width: newW, interpolation: img.Interpolation.linear);
    }
    return out;
  }

  /// 把 JPEG 字节写成临时文件再交给 ML Kit。
  ///
  /// 为什么不用 InputImage.fromBytes：那条路要求传原始像素格式（nv21/bgra8888），
  /// 得自己转换格式，反而更容易出错；写临时文件多一次磁盘 IO 但最稳。
  Future<OcrText> _recognizeJpegBytes(List<int> bytes, {required int index}) async {
    Directory? tmpDir;
    File? tmpFile;
    try {
      tmpDir = await getTemporaryDirectory();
      tmpFile = File(p.join(tmpDir.path,
          'ocr_tile_${DateTime.now().microsecondsSinceEpoch}_$index.jpg'));
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

  Future<OcrText> _recognizeSingleFile(String path) async {
    final input = InputImage.fromFilePath(path);
    final lines = <RawLine>[];
    final text = StringBuffer();

    // 注意：这里**不能**写 `final TextRecognitionResult result;`。
    // 这个包的返回类型在版本之间换过名字（`TextRecognitionResult` 在
    // 0.13 里根本不存在），写死名字会在 CI 上直接编译失败；
    // 交给类型推断就没有这个风险。
    try {
      final result = await _engine.processImage(input);
      for (final block in result.blocks) {
        for (final line in block.lines) {
          final t = line.text.trim();
          if (t.isEmpty) continue;
          final rect = line.boundingBox;
          lines.add(RawLine(
            text: t,
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
          ));
        }
      }
      text.write(result.text);
    } catch (e) {
      throw OcrException('文字识别失败：$e');
    }

    return OcrText(lines, text.toString());
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
  /// 所以只限制**宽度**上限，高度只受总像素兜底；并且整件事交给原生做，
  /// Dart 侧不 decode（decode 一张 13MP 长图就是一次 OOM 风险）。
  Future<String> importImage(File source, {String? fileNameHint}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imageDir = Directory(p.join(docsDir.path, 'slips'));
    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final targetName = '${stamp}_${fileNameHint ?? 'slip'}.jpg';
    final targetPath = p.join(imageDir.path, targetName);

    // ---- 首选：原生压缩（内存安全）
    try {
      final ok = await SlipImaging.compress(
        src: source.path,
        dest: targetPath,
        maxWidth: 1600,
        // 放宽到 20MP：归档图是拿来"看"的，压太狠字就糊了。
        // OCR 不走这张图（走原图），所以这里只需要防极端大图。
        maxPixels: 20000000,
        quality: 88,
      );
      if (ok) return targetPath;
    } catch (e) {
      CrashLog.note('原生压缩失败，退回原图拷贝：$e');
    }

    // ---- 回退：小图走 Dart 压缩，大图直接原样拷贝（宁可占空间也不能丢图）
    try {
      final len = await source.length();
      if (len <= 12 * 1024 * 1024) {
        final raw = await source.readAsBytes();
        final decoded = img.decodeImage(raw);
        if (decoded != null) {
          var output = decoded;
          if (decoded.width > 1600) {
            output = img.copyResize(decoded,
                width: 1600, interpolation: img.Interpolation.linear);
          }
          await File(targetPath).writeAsBytes(img.encodeJpg(output, quality: 88));
          return targetPath;
        }
      }
    } catch (_) {
      // 落到原样拷贝
    }

    await source.copy(targetPath);
    return targetPath;
  }

  void dispose() {
    _recognizer?.close();
    _recognizer = null;
  }
}
