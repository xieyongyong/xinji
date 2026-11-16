import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crash_log.dart';
import 'native_ocr.dart';
import 'slip_imaging.dart';

// OcrText / OcrException 定义在 native_ocr.dart，这里转出去，
// 让老的 `import '../ocr/ocr_service.dart'` 不用改。
export 'native_ocr.dart' show OcrText, OcrException;

/// 图片相关的门面：识别 + 归档。
///
/// ## 为什么这里几乎没有识别代码了
/// v1.4 之前是把 ML Kit 跑在主进程的 Dart 侧。这条路在长截图上会崩，
/// 而且崩的方式很刁钻：**native 段错误，Dart 层连异常都来不及抛**，
/// 用户看到「导入图片瞬间闪退」，日志里只有半句话。
///
/// 现在识别整条链路（分块 + ML Kit + 去重）搬到了 Android 的 `:ocr` 独立进程
/// （见 `OcrService.kt`），这里只负责转发和错误翻译。
/// 那边崩了，主 App 还活着，能弹「可手动填」。
class OcrService {
  /// 识别一批图，按顺序返回每张图的结果。
  ///
  /// 一次把整批交给原生（一次绑定、一次回传），比逐张调用省一次进程往返，
  /// 也避免每张图都重新唤醒识别器。
  Future<List<OcrText>> recognizeFiles(List<String> paths) async {
    if (paths.isEmpty) return const <OcrText>[];

    CrashLog.note('开始识别 ${paths.length} 张图');
    final result = await NativeOcr.recognize(paths);
    if (result.length != paths.length) {
      throw OcrException(
        '识别结果和图片数量对不上（${result.length}/${paths.length}），请重试',
      );
    }
    CrashLog.note('识别完成 ${result.length} 张');
    return result;
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

  /// 保留这个方法：识别器现在活在原生进程里，Dart 侧没有需要释放的东西。
  void dispose() {}
}
