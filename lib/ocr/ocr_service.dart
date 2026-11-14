import 'dart:io';

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

/// 离线 OCR 服务。
///
/// 用 ML Kit 的中文识别模型：模型随 APK 打包，**完全离线、不联网**，
/// 工资数据一个字节都不出手机。
class OcrService {
  TextRecognizer? _recognizer;

  TextRecognizer get _engine {
    // ML Kit 初始化有成本，复用同一个实例
    _recognizer ??= TextRecognizer(script: TextRecognitionScript.chinese);
    return _recognizer!;
  }

  /// 识别一张图，返回带坐标的文本片段
  Future<RecognizedText> recognizeFile(String path) async {
    final input = InputImage.fromFilePath(path);
    final result = await _engine.processImage(input);

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

  /// 把用户选的图复制进应用私有目录，顺便压缩。
  ///
  /// 压缩策略要注意：工资条截图往往是**长截图**（宽 1080、高 5000+）。
  /// 如果按"长边压到 1600"会把宽度压到 200 多，字全糊了，OCR 直接废掉。
  /// 所以只限制**宽度**上限，高度不限。
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

      // 只在宽度超过 1600 时缩放（平板截图、拍照才会触发）
      img.Image output = decoded;
      const maxWidth = 1600;
      if (decoded.width > maxWidth) {
        output = img.copyResize(decoded, width: maxWidth, interpolation: img.Interpolation.linear);
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
