import 'package:flutter/services.dart';

/// 后台隐私保护的开关通道。
///
/// 真正的保护在原生层：`MainActivity` 在 `onPause` 给窗口加 `FLAG_SECURE`、
/// `onResume` 清掉。系统抓最近任务缩略图 / 截屏 / 录屏时读到这个 flag 就直接
/// 出黑帧 —— 不依赖 App 渲染任何一帧，所以上滑手势、返回键、Home、锁屏都拦得住。
/// 只在后台加、回前台清，前台的截屏录屏投屏不受影响。
///
/// 为什么不用 Flutter 画遮罩：
/// Flutter 收到 inactive 要经过 platform channel → Dart isolate → scheduler
/// → build/layout/paint → raster 一整条链路，而系统在 onPause 之后就抓
/// 「最近任务」缩略图；Activity 不可见后 engine 还会暂停帧调度，
/// 那帧遮罩经常根本画不出来。这一点已经用 v2.7.1 ~ v2.7.6 五个版本验证过。
///
/// 本通道只负责把用户的「后台隐藏内容」开关同步给原生。
class PrivacyChannel {
  static const MethodChannel _channel = MethodChannel('xinji/privacy');

  /// 开启/关闭后台隐私保护。启动时推一次，设置页切换时也会推。
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setEnabled', {'enabled': enabled});
    } catch (_) {
      // 通道异常（极少数情况，如引擎未就绪）时静默失败：
      // 原生默认是开启的，比默认关闭更安全。
    }
  }
}
