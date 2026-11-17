import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_settings.dart';
import 'core/crash_log.dart';
import 'security/lock_service.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/lock_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/update_progress_strip.dart';

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

  /// 切后台超过 30 秒，回来要重新验证
  static const Duration _relockAfter = Duration(seconds: 30);

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
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pausedAt = DateTime.now();
        break;
      case AppLifecycleState.resumed:
        final paused = _pausedAt;
        _pausedAt = null;
        if (paused != null && DateTime.now().difference(paused) >= _relockAfter) {
          widget.lock.lockNow();
        }
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
    final settings = context.watch<AppSettings>();
    return MaterialApp(
      title: '薪迹',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness: Brightness.light, seedIndex: settings.seedIndex),
      darkTheme: buildTheme(brightness: Brightness.dark, seedIndex: settings.seedIndex),
      themeMode: settings.materialThemeMode,
      // 全局浮层：下载进度条/安装提示贴在所有页面底部，切到统计/设置/详情都不消失。
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: UpdateProgressStrip(),
          ),
        ],
      ),
      home: const _RootGate(),
    );
  }
}

/// 进门前先过锁
class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<LockService>();
    if (lock.enabled && lock.locked) {
      return const LockPage();
    }
    return const HomePage();
  }
}
