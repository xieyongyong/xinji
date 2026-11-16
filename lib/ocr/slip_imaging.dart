import 'dart:io';

import 'package:flutter/services.dart';

/// 一块切好的图。
///
/// [top] 已经是**识别图坐标系**下的偏移：原生侧换算过比例，
/// 这里直接 `line.top + top` 就能拼回整图，不用自己再乘缩放系数。
class SlipTile {
  final String path;
  final int top;
  final int width;
  final int height;

  const SlipTile({
    required this.path,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// 原生图片处理通道（Android）。
///
/// 存在的唯一理由：**长截图不能整张读进内存**。
/// 一张 1080×12000 的工资条截图解码后约 50MB，Dart 侧再叠加
/// 缩放 / 编码的副本，峰值能到 150MB 以上，中低端机直接被系统 kill，
/// 表现就是"选完图瞬间闪退、日志里什么都没有"。
///
/// 这里把解码、切块、缩放、编码全部交给 Android 的
/// BitmapRegionDecoder，一块一块处理，峰值只有一块（约 7MB）。
///
/// 任何异常都返回 null / 抛 [ImagingException]，**不会**让 App 崩掉。
class SlipImaging {
  static const MethodChannel _channel = MethodChannel('xinji/imaging');

  /// 通道是否可用（非 Android 平台没有原生实现）
  static bool get available => Platform.isAndroid;

  /// 只读尺寸，不解码像素。失败返回 null。
  static Future<({int width, int height, int rotation})?> probe(String path) async {
    if (!available) return null;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('probe', {'path': path});
      if (r == null) return null;
      return (
        width: (r['width'] as num?)?.toInt() ?? 0,
        height: (r['height'] as num?)?.toInt() ?? 0,
        rotation: (r['rotation'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 分块解码到 [outDir]，返回每块的文件路径与 top 偏移。
  ///
  /// 失败抛 [ImagingException]，调用方应回退到别的方案或给用户提示。
  static Future<List<SlipTile>> tiles({
    required String path,
    required String outDir,
    required String tag,
    int tileHeight = 1400,
    int overlap = 120,
    int maxWidth = 1600,
    int quality = 92,
  }) async {
    if (!available) throw ImagingException('当前平台不支持分块识别');
    try {
      final list = await _channel.invokeListMethod<dynamic>('tiles', {
        'path': path,
        'outDir': outDir,
        'tag': tag,
        'tileHeight': tileHeight,
        'overlap': overlap,
        'maxWidth': maxWidth,
        'quality': quality,
      });
      if (list == null || list.isEmpty) {
        throw ImagingException('分块结果为空');
      }
      return list.map((e) {
        final m = (e as Map).cast<String, dynamic>();
        return SlipTile(
          path: m['path'] as String,
          top: (m['top'] as num?)?.toInt() ?? 0,
          width: (m['width'] as num?)?.toInt() ?? 0,
          height: (m['height'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    } on PlatformException catch (e) {
      throw ImagingException(e.message ?? '图片分块失败');
    }
  }

  /// 归档压缩（限制宽度与总像素），写完后返回目标路径。
  /// 失败返回 null，调用方自行决定降级。
  static Future<bool> compress({
    required String src,
    required String dest,
    int maxWidth = 1600,
    int maxPixels = 20000000,
    int quality = 88,
  }) async {
    if (!available) return false;
    try {
      final r = await _channel.invokeMethod<dynamic>('compress', {
        'src': src,
        'dest': dest,
        'maxWidth': maxWidth,
        'maxPixels': maxPixels,
        'quality': quality,
      });
      return r != null && await File(dest).exists();
    } catch (_) {
      return false;
    }
  }
}

/// 原生处理失败（可直接展示给用户的中文原因）
class ImagingException implements Exception {
  final String message;
  ImagingException(this.message);
  @override
  String toString() => message;
}
