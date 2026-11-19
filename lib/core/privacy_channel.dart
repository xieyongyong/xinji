import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 后台隐私保护：把「后台隐藏内容」开关同步给 Android 原生。
///
/// 真正的保护在原生层做——切后台时给窗口加 [FLAG_SECURE]，系统拍
/// 「最近任务」缩略图、截屏、录屏时只能拍到黑屏。
///
/// 为什么不再用 Flutter 画遮罩：App 进入后台后 Flutter engine 停止消费
/// 绘制帧，Dart 里 setState 加的遮罩永远不会被画到窗口上，缩略图仍是工资
/// 内容；而遮罩状态会拖到回前台才第一次上屏，表现为「闪一下」。FLAG_SECURE
/// 是系统级窗口属性，不依赖 Flutter 渲染，所以既真正盖住、又不闪。
class PrivacyChannel {
  static const MethodChannel _channel = MethodChannel('xinji/privacy');

  /// 应用图标的 PNG 字节，启动时预取缓存。
  /// 遮罩在切后台瞬间绘制，那时 engine 即将停帧，不能现读，必须提前备好。
  static Uint8List? appIconBytes;

  /// 把开关状态推给原生。启动时和设置变更时各调用一次。
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setEnabled', {'enabled': enabled});
    } catch (_) {
      // 非 Android 平台或通道未注册时静默忽略，不影响 UI。
    }
  }

  /// 预取应用图标（PNG 字节）。失败则保持 null，遮罩会退化成纯图标。
  static Future<void> preloadAppIcon() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('appIcon');
      if (bytes != null && bytes.isNotEmpty) appIconBytes = bytes;
    } catch (_) {}
  }
}
