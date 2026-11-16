import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 崩溃与异常日志。
///
/// 为什么需要：本地离线 App 出问题时，用户只能描述"闪退了"，
/// 开发者拿不到任何堆栈。把最近的异常落到文件里，至少能在设置页
/// 翻出来看一眼，或者导出给开发者定位。
///
/// 局限要说明白：**原生层的崩溃（例如内存不足被系统 kill）拦不住**，
/// 这里只能抓 Dart 层的异常。
class CrashLog {
  static File? _file;

  /// 最近一次异常摘要，设置页直接展示
  static String? lastError;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File(p.join(dir.path, 'crash.log'));
      await _trimIfTooBig();
    } catch (_) {
      _file = null;
    }

    FlutterError.onError = (details) {
      _write('FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}');
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _write('Uncaught: $error\n$stack');
      return true;
    };
  }

  static void _write(String text) {
    lastError = text;
    final f = _file;
    if (f == null) return;
    try {
      final stamp = DateTime.now().toString().substring(0, 19);
      f.writeAsStringSync('\n===== $stamp =====\n$text\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写不进去也不能影响主流程
    }
  }

  /// 日志超过 200KB 就清空，避免无限增长
  static Future<void> _trimIfTooBig() async {
    final f = _file;
    if (f == null || !await f.exists()) return;
    final len = await f.length();
    if (len > 200 * 1024) await f.delete();
  }

  static Future<String> read() async {
    final f = _file;
    if (f == null || !await f.exists()) return '';
    return f.readAsString();
  }

  static Future<void> clear() async {
    final f = _file;
    if (f != null && await f.exists()) await f.delete();
    lastError = null;
  }
}
