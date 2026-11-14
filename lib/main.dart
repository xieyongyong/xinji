import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'security/lock_service.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/lock_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appState = AppState();
  final lock = LockService();

  await lock.load();
  await appState.init();

  runApp(XinJiApp(state: appState, lock: lock));
}

class XinJiApp extends StatefulWidget {
  final AppState state;
  final LockService lock;

  const XinJiApp({super.key, required this.state, required this.lock});

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
      ],
      child: MaterialApp(
        title: '薪迹',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const _RootGate(),
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
