import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// 后台隐私保护：把「后台隐藏内容」开关同步给 Android 原生，并预取应用图标。
///
/// 保护分两层，缺一不可：
///
/// 1. **可见层（Flutter 毛玻璃遮罩，见 `main.dart` 的 `_PrivacyMask`）**
///    `inactive` 时就把遮罩盖上去 —— 那一刻窗口仍可见、engine 仍在渲染，
///    所以这一帧来得及画，系统抓「最近任务」缩略图时拍到的是模糊画面。
/// 2. **兜底层（系统级标记）**
///    Android 13+：`setRecentsScreenshotEnabled` 动态闸门，默认禁止拍（白卡），
///    遮罩画完才放行；Android 12 及以下：`FLAG_SECURE` 常驻。
class PrivacyChannel {
  static const MethodChannel _channel = MethodChannel('xinji/privacy');

  /// **已解码**的应用图标。
  ///
  /// 这是遮罩能不能画出图标的关键：遮罩从插入到被系统抓图只有一两帧，
  /// 而 `Image.memory` 走异步解码（IO 线程 + event loop），那时根本来不及，
  /// 结果就是圆盘里一片空白 —— 也就是「中心没有应用图标」。
  /// 启动时先解好成 [ui.Image]，遮罩里用 `RawImage` **同步**绘制，零等待。
  static ui.Image? appIconImage;

  /// 把开关状态推给原生。启动时和设置变更时各调用一次。
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setEnabled', {'enabled': enabled});
    } catch (_) {
      // 通道异常（极少数情况，如引擎未就绪）时静默失败：
      // 原生默认是开启的，比默认关闭更安全。
    }
  }

  /// 预取并**预解码**应用图标。失败则保持 null，遮罩会退化成纯图标。
  static Future<void> preloadAppIcon() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('appIcon');
      if (bytes == null || bytes.isEmpty) return;
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        appIconImage = frame.image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // 解码失败就退化成文字图标，不影响遮罩本身
    }
  }

  /// 告诉原生「遮罩那一帧已经画完了，可以允许系统拍快照」。
  ///
  /// 只在 Android 13+ 有意义：那边平时把最近任务快照关着（默认给白卡），
  /// 等遮罩真的画进 Surface 才打开许可，于是拍到的就是模糊画面而不是明文。
  /// 如果这一帧没赶上（超时就不调用），系统保持关闭 → 白卡，绝不泄露内容。
  ///
  /// 原生侧还会用 `foreground` 挡掉迟到的调用（上一轮的放行晚于 onResume 到达），
  /// 避免它把新一轮刚做的重置又打开。
  static Future<void> markMaskVisible() async {
    try {
      await _channel.invokeMethod<bool>('maskVisible');
    } catch (_) {}
  }
}
