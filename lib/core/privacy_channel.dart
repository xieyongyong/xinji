import 'package:flutter/services.dart';

/// 后台隐私保护的开关通道。
///
/// 遮罩本身由**原生 View** 绘制（见 android/.../PrivacyMaskView.kt）：
/// 在 MainActivity.onPause 里同步挂到 FlutterView 之上，onResume 时移除。
///
/// 为什么不用 Flutter 画遮罩：
/// Flutter 收到 inactive 要经过 platform channel → Dart isolate → scheduler
/// → build/layout/paint → raster 一整条链路，而系统在 onPause 之后就抓
/// 「最近任务」缩略图；Activity 不可见后 engine 还会暂停帧调度，
/// 那帧遮罩经常根本画不出来。原生 View 是窗口级的，同步执行，不受此影响。
///
/// 本通道只负责把用户的「后台隐藏内容」开关同步给原生。
class PrivacyChannel {
  static const MethodChannel _channel = MethodChannel('xinji/privacy');

  /// 开启/关闭后台隐私遮罩。启动时推一次，设置页切换时也会推。
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setEnabled', {'enabled': enabled});
    } catch (_) {
      // 通道异常（极少数情况，如引擎未就绪）时静默失败：
      // 原生默认是开启的，比默认关闭更安全。
    }
  }
}
