import 'dart:async';

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

  // 后台隐私保护交给原生窗口标志位。启动时把用户设置推一次，
  // 之后设置页变更时也会实时同步（见 AppSettings.setPrivacyMask）。
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
        // 回到前台撤掉遮罩（该上锁时 _RootGate 会挡）。因为遮罩早已画好，
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
    final settings = context.watch<AppSettings>();
    final lock = context.watch<LockService>();
    // 遮罩只在"切到后台"时出现；回到前台立刻撤掉（该上锁时 _RootGate 会挡）
    final showMask = lock.masked && settings.privacyMask;
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
          // 最后画：遮罩必须盖住包括下载进度条在内的一切
          if (showMask) const Positioned.fill(child: _PrivacyMask()),
        ],
      ),
      home: const _RootGate(),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      // 柔和渐变底，深色/浅色各一套；比原来的纯色块更像"锁屏"而不是"出错"
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF0E1320), const Color(0xFF1A2233)]
              : [const Color(0xFFF5F7FB), const Color(0xFFE8ECF5)],
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kSeed.withOpacity(dark ? 0.16 : 0.10),
              border: Border.all(color: kSeed.withOpacity(0.35), width: 1.5),
            ),
            child: Icon(Icons.lock_outlined, size: 38, color: kSeed),
          ),
          const SizedBox(height: 20),
          Text('薪迹',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: kTextPrimary)),
          const SizedBox(height: 8),
          Text('内容已隐藏 · 回到应用后自动显示',
              style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
        ],
      ),
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
