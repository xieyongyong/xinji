import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 后台遮罩用的**预渲染磨砂纹理**。
///
/// ## 为什么不用 `BackdropFilter` 做真模糊
/// 全屏高斯在低端机上要 10–30ms，而且每帧还要额外分配一块全屏离屏纹理
/// （1440×3200 就是约 18MB）。而遮罩从插入到被系统抓图只有几十毫秒 ——
/// 点返回键、按 Home 退出时窗口更窄。真模糊经常来不及画完，
/// 结果就是「最近任务里一张白卡」，而慢速手势反而能赶上。
///
/// ## 这张纹理怎么来的
/// 启动时用 `PictureRecorder` 画一次，之后遮罩只做一次纹理采样（1–2ms）：
/// 深色底 + 径向渐变（中心透光）+ 斜向高光 + 细颗粒。
/// 视觉上就是磨砂玻璃，但成本比真模糊低一个数量级，
/// 而且**不随页面复杂度浮动** —— 工资明细页元素最多，真模糊最慢，
/// 偏偏它最需要遮罩。
///
/// 另一个隐藏好处：这张图和当时打开的页面无关，任何页面切后台都是同一张，
/// 连「这一屏是列表还是详情」都不泄露。真模糊做不到这一点。
class FrostTexture {
  /// 已生成的纹理。null 表示还没准备好，遮罩会退化成深色纯色底
  /// （成本同样极低，安全性不受影响）。
  static ui.Image? image;

  /// 生成尺寸。故意远小于屏幕：磨砂本来就没有高频细节，
  /// 放大后正好是柔和的颗粒感，还能省内存和光栅时间。
  /// 宽高比接近主流手机，遮罩用 `BoxFit.cover` 铺，不会明显拉伸。
  static const int _w = 400;
  static const int _h = 880;

  /// 启动时调用一次（`main()` 里）。失败就保持 null，不影响隐私保护本身。
  static Future<void> preload() async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final w = _w.toDouble();
      final h = _h.toDouble();
      final rect = Rect.fromLTWH(0, 0, w, h);

      // 基底
      canvas.drawRect(rect, Paint()..color = const Color(0xFF202329));

      // 中心透光：磨砂玻璃被背后的光打亮的那一块
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(w * 0.5, h * 0.4),
            w * 1.2,
            const [Color(0xFF3A4049), Color(0xFF1B1E23)],
            const [0.0, 1.0],
          ),
      );

      // 斜向高光带：给整块玻璃一点方向感，避免死板的对称渐变
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(w, h),
            [
              Colors.white.withValues(alpha: 0.05),
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: 0.03),
            ],
            const [0.0, 0.5, 1.0],
          ),
      );

      // 颗粒：磨砂质感的关键。没有它，放大后就是一块死板的渐变。
      // 固定种子，每次启动画出来的纹理完全一致（避免观感随机）。
      final rnd = Random(20261119);
      final dot = Paint();
      for (var i = 0; i < 1600; i++) {
        dot.color = Colors.white.withValues(alpha: 0.015 + rnd.nextDouble() * 0.035);
        canvas.drawCircle(
          Offset(rnd.nextDouble() * w, rnd.nextDouble() * h),
          0.5 + rnd.nextDouble(),
          dot,
        );
      }

      final picture = recorder.endRecording();
      image = await picture.toImage(_w, _h);
      picture.dispose();
    } catch (_) {
      // 生成失败就用纯色底兜住，隐私保护不能因此失效
    }
  }
}
