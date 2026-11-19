import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 后台隐私保护辅助通道。
///
/// 现在的后台隐藏**完全由 Flutter 遮罩**完成（见 main.dart 的 _PrivacyMask）：
/// 在 inactive（窗口仍可见、仍在出帧）时就盖上毛玻璃，系统拍「最近任务」
/// 缩略图拍到的就是遮罩这一屏，按 Home 键或返回键退出都能生效。
///
/// 不再用原生 FLAG_SECURE：它会让系统直接给空白卡片（上黑线+下白屏），
/// 还会和 Flutter 遮罩帧抢截图时机，表现不稳定。
/// 本通道现在只负责一样东西——预取应用图标字节给遮罩中央当 logo。
class PrivacyChannel {
  static const MethodChannel _channel = MethodChannel('xinji/privacy');

  /// 应用图标的 PNG 字节，启动时预取缓存。
  /// 遮罩在切后台瞬间绘制，那时 engine 即将停帧，不能现读，必须提前备好。
  static Uint8List? appIconBytes;

  /// 预取应用图标（PNG 字节）。失败则保持 null，遮罩会退化成纯图标。
  static Future<void> preloadAppIcon() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('appIcon');
      if (bytes != null && bytes.isNotEmpty) appIconBytes = bytes;
    } catch (_) {}
  }
}
