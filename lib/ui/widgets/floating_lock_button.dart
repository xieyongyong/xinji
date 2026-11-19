import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_settings.dart';
import '../../security/lock_service.dart';
import '../theme.dart';

/// 应用内悬浮锁定按钮。
///
/// 半透明、可拖动，松手吸附到屏幕左右两侧（默认贴右），点一下立即上锁并退回首页。
/// 纯 Flutter Overlay 实现，退出应用即消失，不需要任何系统权限。
///
/// 只在「已启用应用锁」且设置里打开「悬浮锁定按钮」时显示。
class FloatingLockButton extends StatefulWidget {
  const FloatingLockButton({super.key});

  @override
  State<FloatingLockButton> createState() => _FloatingLockButtonState();
}

class _FloatingLockButtonState extends State<FloatingLockButton> {
  static const _kLeft = 'floating_lock_left';
  static const _kDy = 'floating_lock_dy';
  static const _size = 52.0;
  static const _edge = 6.0;

  /// null 表示还没定位（首帧用默认右侧位置）
  double? _x;
  double? _y;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final sp = await SharedPreferences.getInstance();
    final left = sp.getBool(_kLeft) ?? false;
    final dy = sp.getDouble(_kDy);
    if (!mounted) return;
    final w = MediaQuery.of(context).size.width;
    setState(() {
      _x = left ? _edge : w - _size - _edge;
      _y = dy;
    });
  }

  void _onPanEnd(DragEndDetails d, double maxW, double maxH) {
    if (_x == null || _y == null) return;
    // x 只有左右两种：按松手时中心点判断就近吸附
    final centerX = _x! + _size / 2;
    final toLeft = centerX < maxW / 2;
    final snappedX = toLeft ? _edge : maxW - _size - _edge;
    // y 夹在顶栏和底部之间
    final maxY = maxH - _size - _edge - 70;
    final snappedY = _y!.clamp(_edge + 40.0, maxY < _edge + 40 ? _edge + 40 : maxY).toDouble();
    setState(() {
      _x = snappedX;
      _y = snappedY;
    });
    SharedPreferences.getInstance().then((sp) {
      sp.setBool(_kLeft, toLeft);
      sp.setDouble(_kDy, snappedY);
    });
  }

  void _lock() {
    final lock = context.read<LockService>();
    if (!lock.enabled) return;
    lock.lockNow();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final lock = context.watch<LockService>();
    if (!settings.floatingLock || !lock.enabled) return const SizedBox.shrink();

    final size = MediaQuery.of(context).size;
    // 未恢复完成时先放默认右侧中部，避免闪一下
    final x = _x ?? (size.width - _size - _edge);
    final y = _y ?? (size.height * 0.45);

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            _x = (x + d.delta.dx).clamp(0.0, size.width - _size).toDouble();
            _y = (y + d.delta.dy).clamp(0.0, size.height - _size).toDouble();
          });
        },
        onPanEnd: (d) => _onPanEnd(d, size.width, size.height),
        onTap: _lock,
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kSeed.withOpacity(0.28),
            border: Border.all(color: kSeed.withOpacity(0.55), width: 1.2),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 8),
            ],
          ),
          child: Icon(Icons.lock_outline, size: 24, color: Colors.white),
        ),
      ),
    );
  }
}
