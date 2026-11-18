import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backup/cloud_auto_backup.dart';
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
        // inactive 比 paused 早一步：先盖住画面，系统拍最近任务缩略图时
        // 拍到的就是遮罩而不是工资明细。
        if (widget.settings.privacyMask) widget.lock.mask();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pausedAt = DateTime.now();
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
/// 目的只有一个：系统"最近任务"里拍到的缩略图是这一屏，
/// 而不是你上个月的工资明细。回到 App 会自动撤掉。
class _PrivacyMask extends StatelessWidget {
  const _PrivacyMask();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kScaffold,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: kSurfaceAlt,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(Icons.visibility_off_outlined, size: 30, color: kTextSecondary),
          ),
          const SizedBox(height: 14),
          Text('薪迹 · 内容已隐藏',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: kTextBody)),
          const SizedBox(height: 6),
          Text('回到应用后自动显示',
              style: TextStyle(fontSize: 11.5, color: kTextHint)),
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
