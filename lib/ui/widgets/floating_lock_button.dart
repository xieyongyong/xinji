import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_settings.dart';
import '../../security/lock_service.dart';
import '../theme.dart';

/// 应用内悬浮锁定按钮。
///
/// 半透明渐变、无实线边框，可拖动；松手按中心点吸附到屏幕左右两侧，
/// 默认让约 1/3 露在屏外，既好按又不挡内容。点一下立即上锁。
/// 纯 Flutter 应用内浮层，退出 App 即消失，不需要系统悬浮窗权限。
///
/// 只在「已启用应用锁」且设置里打开「悬浮锁定按钮」时显示。
class FloatingLockButton extends StatefulWidget {
  const FloatingLockButton({super.key, this.rootNavigatorKey});

  /// 根 Navigator 的 key：浮层在 MaterialApp.builder 里，不一定能直接
  /// Navigator.of(context) 找到路由栈，锁定时借它退回首页。
  final GlobalKey<NavigatorState>? rootNavigatorKey;

  @override
  State<FloatingLockButton> createState() => _FloatingLockButtonState();
}

class _FloatingLockButtonState extends State<FloatingLockButton> {
  static const _kLeft = 'floating_lock_left';
  static const _kDy = 'floating_lock_dy';

  SharedPreferences? _sp;

  /// 是否已恢复位置。未恢复时用默认右侧中部。
  double? _y;

  /// 是否正在拖动。拖动中允许自由移动，松手才吸附。
  bool _dragging = false;
  double? _dragX;

  /// (true=左, false=右) 位置单独持久化，和当前尺寸解耦。
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final sp = await SharedPreferences.getInstance();
    _sp = sp;
    if (!mounted) return;
    final left = sp.getBool(_kLeft) ?? false;
    final dy = sp.getDouble(_kDy);
    if (!mounted) return;
    setState(() {
      _left = left;
      _y = dy;
    });
  }

  /// 吸附位置：约 1/3 在屏外，2/3 留在屏内；图标稍微往屏内偏，避免被切到。
  double _snappedX(double width, double size, bool left) {
    return left ? -size / 3 : width - size * 2 / 3;
  }

  void _onPanEnd(double size, double width, double minY, double maxY) {
    if (!_dragging) return;
    final centerX = (_dragX ?? _snappedX(width, size, _left)) + size / 2;
    _left = centerX < width / 2;
    _y = (_y ?? 0).clamp(minY, maxY).toDouble();
    _dragging = false;
    _dragX = null;
    setState(() {});
    _sp?.setBool(_kLeft, _left);
    _sp?.setDouble(_kDy, _y!);
  }

  void _lock() {
    if (_dragging) return;
    final lock = context.read<LockService>();
    if (!lock.enabled) return;
    lock.lockNow();
    final nav = widget.rootNavigatorKey?.currentState;
    if (nav != null) {
      nav.popUntil((route) => route.isFirst);
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppSettings, bool>((s) => s.floatingLock);
    final sizeSetting = context.select<AppSettings, int>((s) => s.floatingLockSize);
    final enabled = context.select<LockService, bool>((l) => l.enabled);
    final locked = context.select<LockService, bool>((l) => l.locked);
    if (!settings || !enabled || locked) return const SizedBox.shrink();

    final media = MediaQuery.of(context).size;
    final size = sizeSetting.toDouble();
    const minY = 40.0;
    final maxY = (media.height - size - 70).clamp(minY, media.height).toDouble();
    final snappedX = _snappedX(media.width, size, _left);
    final x = _dragging ? (_dragX ?? snappedX) : snappedX;
    final y = (_y ?? media.height * 0.45).clamp(minY, maxY).toDouble();

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          _dragging = true;
          _dragX = x;
          _y = y;
        },
        onPanUpdate: (d) {
          setState(() {
            _dragX = ((_dragX ?? x) + d.delta.dx)
                .clamp(-size * 0.45, media.width - size * 0.55)
                .toDouble();
            _y = ((_y ?? y) + d.delta.dy).clamp(minY, maxY).toDouble();
          });
        },
        onPanEnd: (_) => _onPanEnd(size, media.width, minY, maxY),
        onTap: _lock,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 渐变透明，没有实线 border；边缘自然淡出，贴边时不显生硬。
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 0.95,
                colors: [
                  kSeed.withOpacity(0.62),
                  kSeed.withOpacity(0.30),
                  kSeed.withOpacity(0.06),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: kSeed.withOpacity(0.20),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Transform.translate(
              // 图标朝屏幕内侧偏一点，1/3 贴边时也不会被切掉。
              offset: Offset(_left ? 4 : -4, 0),
              child: Icon(
                Icons.lock_outline,
                size: size * 0.46,
                color: Colors.white.withOpacity(0.92),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
