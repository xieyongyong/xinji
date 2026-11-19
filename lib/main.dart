import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backup/cloud_auto_backup.dart';
import 'core/app_settings.dart';
import 'core/crash_log.dart';
import 'core/privacy_channel.dart';
import 'security/lock_service.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/lock_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/floating_lock_button.dart';
import 'ui/widgets/update_progress_strip.dart';

/// 根 Navigator 的 key：全局锁层在 MaterialApp.builder 里，位于 Navigator 之外，
/// 「忘记 PIN」需要借它把找回页压到最上层。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先装异常捕获，后面任何初始化出错都能落盘
  await CrashLog.init();

  final appState = AppState();
  final lock = LockService();
  final settings = AppSettings();

  await settings.load();
  await lock.load();
  await appState.init();

  // 后台隐私保护交给原生窗口标志位。启动时把用户设置推一次，
  // 之后设置页变更时也会实时同步（见 AppSettings.setPrivacyMask）。
  await PrivacyChannel.setEnabled(settings.privacyMask);
  // 预取应用图标：后台遮罩中央要用，进后台后才能直接用缓存绘制。
  await PrivacyChannel.preloadAppIcon();

  runApp(XinJiApp(state: appState, lock: lock, settings: settings));
}

class XinJiApp extends StatefulWidget {
  final AppState state;
  final LockService lock;
  final AppSettings settings;

  const XinJiApp({
    super.key,
    required this.state,
    required this.lock,
    required this.settings,
  });

  @override
  State<XinJiApp> createState() => _XinJiAppState();
}

class _XinJiAppState extends State<XinJiApp> with WidgetsBindingObserver {
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // inactive 比 paused 早一步，此时窗口仍可见、Flutter engine 仍在渲染。
        // 必须在这里就盖遮罩，系统拍「最近任务」缩略图时才能拍到遮罩；
        // 一旦拖到 paused，engine 已停止出帧，遮罩要等到回前台才画 → 就会「闪一下」。
        if (widget.settings.privacyMask) widget.lock.mask();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 真正切后台：记下时间点供回前台判断重锁，并补一次遮罩（幂等）。
        // 原生 FLAG_SECURE 是系统级双保险，这里 Dart 遮罩是主要可见手段。
        _pausedAt ??= DateTime.now();
        if (widget.settings.privacyMask) widget.lock.mask();
        break;
      case AppLifecycleState.resumed:
        final paused = _pausedAt;
        _pausedAt = null;
        if (paused != null) {
          final delay = widget.settings.lockDelaySeconds;
          if (DateTime.now().difference(paused).inSeconds >= delay) {
            widget.lock.lockNow();
          }
        }
        // 回到前台撤掉遮罩（该上锁时全局锁层会挡）。因为遮罩早已画好，
        // 这里是正常的内容过渡，不会出现 v2.6.0 那种「回前台才画再撤」的闪。
        widget.lock.unmask();
        // 回到前台顺手补一次「这个月该备份了」的检查（内部有互斥和退避）
        CloudAutoBackup.runIfDue(widget.settings);
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: widget.state),
        ChangeNotifierProvider<LockService>.value(value: widget.lock),
        ChangeNotifierProvider<AppSettings>.value(value: widget.settings),
      ],
      child: const _ThemedApp(),
    );
  }
}

/// 单独拆出来 watch 设置：配色/深浅模式变化时重建 MaterialApp 整棵树，
/// 让所有页面的语义色 getter 取到新调色板。
class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    // 只订阅真正影响这里的字段：锁状态变化不再重建整棵 MaterialApp。
    final seedIndex = context.select<AppSettings, int>((s) => s.seedIndex);
    final themeMode = context.select<AppSettings, ThemeMode>((s) => s.materialThemeMode);
    final privacyMask = context.select<AppSettings, bool>((s) => s.privacyMask);
    final masked = context.select<LockService, bool>((l) => l.masked);
    final locked = context.select<LockService, bool>((l) => l.enabled && l.locked);
    // 遮罩只在"切到后台"时出现；回到前台立刻撤掉（该上锁时全局锁层会挡）。
    final showMask = masked && privacyMask;
    return MaterialApp(
      title: '薪迹',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: buildTheme(brightness: Brightness.light, seedIndex: seedIndex),
      darkTheme: buildTheme(brightness: Brightness.dark, seedIndex: seedIndex),
      themeMode: themeMode,
      // 全局浮层：下载进度条/安装提示贴在所有页面底部，切到统计/设置/详情都不消失。
      //
      // 关键：这里每个浮层都带 ValueKey。Stack 按 children 顺序做 diff，
      // 若用无 key 的 children，showMask / locked 条件插入或移除时，
      // 后面的 _LockOverlay 会被错位复用 → LockPage.initState 重跑 → 指纹框反复弹。
      // 加 key 后 Flutter 按 key 匹配，条件变更不会误重建锁层。
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            key: ValueKey('update-strip'),
            left: 0,
            right: 0,
            bottom: 0,
            child: UpdateProgressStrip(),
          ),
          // 应用内悬浮锁定按钮（可拖动、吸附两侧），设置里可开关
          FloatingLockButton(key: const ValueKey('floating-lock'), rootNavigatorKey: rootNavigatorKey),
          // 最后画：遮罩必须盖住包括下载进度条在内的一切
          if (showMask) const Positioned.fill(key: ValueKey('privacy-mask'), child: _PrivacyMask()),
          // 全局锁层：放在 Navigator 之上，锁定时设置页等任何已打开页面都过不了验证。
          // ModalBarrier 兜住背景点击，LockPage 自己处理按键与指纹。
          if (locked) ...[
            const Positioned.fill(
              key: ValueKey('lock-barrier'),
              child: ModalBarrier(dismissible: false, color: Colors.transparent),
            ),
            const Positioned.fill(key: ValueKey('lock-overlay'), child: _LockOverlay()),
          ],
        ],
      ),
      home: const HomePage(),
    );
  }
}

/// 切后台时盖住整屏的遮罩。
///
/// 目的：系统"最近任务"里拍到的缩略图是这一屏，而不是工资明细。
/// 在 inactive（窗口尚可见）时就盖好，回到 App 会自动撤掉。
/// 原生 FLAG_SECURE 另外保证系统级黑屏，两者互补。
class _PrivacyMask extends StatelessWidget {
  const _PrivacyMask();

  @override
  Widget build(BuildContext context) {
    final bytes = PrivacyChannel.appIconBytes;
    // 毛玻璃：模糊底下这一帧的真实内容，不铺纯白/不透明底，也不放任何文字。
    // 中央只放应用图标 + 右下角一个闭眼徽标。
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          // 一层很淡的半透明蒙版，压一压底图、让图标更清楚，但不是纯白
          color: Colors.black.withOpacity(0.28),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.14),
                  border: Border.all(color: Colors.white.withOpacity(0.35), width: 1.2),
                ),
                alignment: Alignment.center,
                child: bytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.memory(bytes, width: 62, height: 62, fit: BoxFit.contain),
                      )
                    : Icon(Icons.visibility_off_outlined, size: 46, color: Colors.white),
              ),
              // 右下角闭眼徽标：明确表达"内容已隐藏"
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kSeed,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.visibility_off, size: 19, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全局锁覆盖层：解锁页和「忘记 PIN」页都在 Navigator 之上、同一层切换。
///
/// 若把找回页 push 到被锁住的 Navigator，它会被锁层盖住，用户以为按钮没反应。
class _LockOverlay extends StatefulWidget {
  const _LockOverlay();

  @override
  State<_LockOverlay> createState() => _LockOverlayState();
}

class _LockOverlayState extends State<_LockOverlay> {
  bool _forgotPin = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: _forgotPin
          ? ForgotPinPage(
              onDone: () => setState(() => _forgotPin = false),
              onCancel: () => setState(() => _forgotPin = false),
            )
          : LockPage(
              rootNavigatorKey: rootNavigatorKey,
              onForgotPin: () => setState(() => _forgotPin = true),
            ),
    );
  }
}