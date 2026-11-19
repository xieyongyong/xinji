import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 后台隐私保护：把「后台隐藏内容」开关同步给 Android 原生，并预取应用图标。
///
/// 保护分两层，缺一不可：
///
/// 1. **可见层（Flutter 毛玻璃遮罩，见 `main.dart` 的 `_PrivacyMask`）**
///    `inactive` 时就把遮罩盖上去 —— 那一刻窗口仍可见、engine 仍在渲染，
///    所以这一帧来得及画，系统抓「最近任务」缩略图时拍到的是模糊画面。
/// 2. **兜底层（原生 `FLAG_SECURE`）**
///    `onPause` 给窗口加、`onResume` 清。系统抓快照 / 截屏 / 录屏时读到这个
///    flag 会按系统策略处理，不依赖 App 渲染任何一帧。
///
/// Android 13+ 额外用 `setRecentsScreenshotEnabled(true)` 明确允许系统生成
/// 快照 —— 我们要的是「拍到模糊画面」，不是「拍不到给一张白卡」。
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
      // 通道异常（极少数情况，如引擎未就绪）时静默失败：
      // 原生默认是开启的，比默认关闭更安全。
    }
  }

  /// 预取应用图标（PNG 字节）。失败则保持 null，遮罩会退化成纯图标。
  static Future<void> preloadAppIcon() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('appIcon');
      if (bytes != null && bytes.isNotEmpty) appIconBytes = bytes;
    } catch (_) {}
  }

  /// 告诉原生「遮罩那一帧已经画完了，可以允许系统拍快照」。
  ///
  /// 只在 Android 13+ 有意义：那边平时把最近任务快照关着（默认给白卡），
  /// 等遮罩真的进了 Surface 才打开许可，于是拍到的就是模糊画面而不是明文。
  /// 如果这一帧没赶上（超时就不调用），系统保持关闭 → 白卡，绝不泄露内容。
  static Future<void> markMaskVisible() async {
    try {
      await _channel.invokeMethod<bool>('maskVisible');
    } catch (_) {}
  }
}
