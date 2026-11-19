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

  // 后台隐私保护：真正的保障是原生的 FLAG_SECURE（切后台给窗口加、回前台清），
  // 系统抓图时直接出黑帧，不依赖 App 渲染任何一帧。
  // Flutter 这层不需要画遮罩，只负责把开关值同步过去。
  await PrivacyChannel.setEnabled(settings.privacyMask);

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
        // 后台遮罩已交给原生（MainActivity.onPause 里同步挂 PrivacyMaskView），
        // 这里不需要再驱动任何绘制 —— 正是为了绕开「Dart 这帧来不及画」的问题。
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 记下时间点供回前台判断是否重锁。遮罩由原生负责，这里不再重复处理。
        _pausedAt ??= DateTime.now();
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
    final locked = context.select<LockService, bool>((l) => l.enabled && l.locked);
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
      // 若用无 key 的 children，locked 条件插入或移除时，
      // 后面的 _LockOverlay 会被错位复用 → LockPage.initState 重跑 → 指纹框反复弹。
      // 加 key 后 Flutter 按 key 匹配，条件变更不会误重建锁层。
      //
      // 后台隐私遮罩不在这里：它由原生 PrivacyMaskView 在 onPause 同步挂载，
      // Flutter 这一层根本来不及画（详见 PrivacyMaskView.kt 的注释）。
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