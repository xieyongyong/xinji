import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backup/cloud_auto_backup.dart';
import 'core/app_settings.dart';
import 'core/crash_log.dart';
import 'core/frost_texture.dart';
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

  // 后台隐私保护分两层：
  //   可见层 —— Flutter 毛玻璃遮罩（见下方 _PrivacyMask），inactive 时画上；
  //   兜底层 —— 原生 FLAG_SECURE，onPause 加、onResume 清。
  // 启动时把用户设置推一次，之后设置页变更时也会实时同步（见 AppSettings.setPrivacyMask）。
  await PrivacyChannel.setEnabled(settings.privacyMask);
  // 预取应用图标 + 预渲染磨砂纹理：后台遮罩要用，进后台后才画就来不及了。
  // 两者互不依赖，并行做，别串起来拖慢启动。
  await Future.wait([
    PrivacyChannel.preloadAppIcon(),
    FrostTexture.preload(),
  ]);

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

  /// 切后台那一刻是否正处于锁定态。
  ///
  /// 冷启动锁屏页弹系统指纹框时，App 也会被推到 paused；验证成功 unlock 后
  /// 系统框关闭触发 resumed。若只看「暂停时长 >= lockDelay」就重锁，
  /// 而 lockDelay 设成 0（立即锁定）或验证稍慢，就会出现
  /// 「指纹解开了却又弹回锁屏页」——必须杀进程重开才正常。
  /// 记住暂停时的锁态：本来就锁着的那次暂停，回来一律不再重锁。
  bool _wasLockedWhenPaused = false;

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
        // 真正切后台：记下时间点和当时的锁态，供回前台判断重锁；补一次遮罩（幂等）。
        // 只在第一次进入后台时记，后续 hidden/paused 抖动不覆盖。
        if (_pausedAt == null) {
          _pausedAt = DateTime.now();
          _wasLockedWhenPaused = widget.lock.locked;
        }
        if (widget.settings.privacyMask) widget.lock.mask();
        break;
      case AppLifecycleState.resumed:
        final paused = _pausedAt;
        final wasLocked = _wasLockedWhenPaused;
        _pausedAt = null;
        _wasLockedWhenPaused = false;
        // 只有「当时是解锁着看内容」的切后台才需要判断超时重锁。
        // 冷启动锁屏页弹指纹框那种暂停，wasLocked=true，回来一律不重锁 ——
        // 否则刚指纹解开又会被锁上，表现为停在锁屏页、要重开 App 才恢复。
        if (paused != null && !wasLocked) {
          final delay = widget.settings.lockDelaySeconds;
          if (DateTime.now().difference(paused).inSeconds >= delay) {
            widget.lock.lockNow();
          }
        }
        // 回到前台立刻撤遮罩（该上锁时锁层会挡）。
        // 遮罩在 inactive 就画好了，这里是正常的内容过渡，不会「回前台才画再撤」的闪。
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
    final locked = context.select<LockService, bool>((l) => l.enabled && l.locked);
    // 遮罩只在「切到后台」时出现；回到前台立刻撤掉（该上锁时锁层会挡）
    final masked = context.select<LockService, bool>((l) => l.masked);
    final privacyMask = context.select<AppSettings, bool>((s) => s.privacyMask);
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
      // 若用无 key 的 children，locked 条件插入或移除时，
      // 后面的 _LockOverlay 会被错位复用 → LockPage.initState 重跑 → 指纹框反复弹。
      // 加 key 后 Flutter 按 key 匹配，条件变更不会误重建锁层。
      //
      // 后台隐私遮罩：`inactive` 时画上、`resumed` 撤掉。
      // 它必须是 Stack 的最后一个孩子 —— 要盖住包含下载进度条、悬浮按钮在内的一切。
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
          // 最后画：后台遮罩必须盖住上面所有层
          if (showMask)
            const Positioned.fill(key: ValueKey('privacy-mask'), child: _PrivacyMask()),
        ],
      ),
      home: const HomePage(),
    );
  }
}

/// 切后台时盖住整屏的磨砂遮罩。
///
/// 目的：系统「最近任务」里拍到的缩略图是这一屏，而不是工资明细。
/// 在 `inactive`（窗口尚可见）时就盖好，回到 App 会自动撤掉。
///
/// 底图是 [FrostTexture] 预渲染的磨砂纹理，**不是 `BackdropFilter`**。
/// 真模糊要 10–30ms 光栅 + 一块全屏离屏纹理，点返回键 / 按 Home 时来不及画完，
/// 系统就会拍到上一帧；换成纹理后整条链路压到 20ms 以内。
///
/// 还有一个不显眼但很关键的职责：**告诉原生「遮罩已就绪」**。
/// Android 13+ 平时把最近任务快照关着（默认白卡），遮罩画好后才置就绪、
/// 原生立刻放行 —— 所以拍到的要么是磨砂画面，要么是白卡，绝不会是明文。
/// 为什么不能等 `onPause` 再放行：荣耀 MagicOS 在 `onPause` 之前就抓图了。
/// 详见 [PrivacyChannel.markMaskReady]。
class _PrivacyMask extends StatefulWidget {
  const _PrivacyMask();

  @override
  State<_PrivacyMask> createState() => _PrivacyMaskState();
}

class _PrivacyMaskState extends State<_PrivacyMask> {
  /// 遮罩代数：每次新建遮罩都拿一个新号，原生据此丢弃上一轮的迟到消息。
  /// 必须是静态的（跨 State 实例递增），否则新实例从 1 开始，反而比旧的还小。
  static int _seqCounter = 0;

  late final int _seq;

  @override
  void initState() {
    super.initState();
    _seq = ++_seqCounter;
    _allowRecentsScreenshot();
  }

  /// 等遮罩上屏，再告诉原生「本轮就绪」。
  ///
  /// 原生收到就**立刻放行**（不等 `onPause`）—— 荣耀 MagicOS 在 `onPause`
  /// 之前就把最近任务缩略图抓走了，等 `onPause` 必然白卡。
  ///
  /// 这里只等**一帧 + 4ms**，不是之前的「两帧 + 16ms」：
  /// 遮罩已经换成预渲染纹理（光栅 1–2ms，无离屏层），一帧结束时基本已经画完；
  /// 再多等就是白白错过系统抓图的窗口 —— 点返回键 / 按 Home 退出时窗口只有
  /// 几十毫秒，之前 46ms 的链路正好卡在外面，表现为「动画里能看到模糊，
  /// 卡片却是白卡」。
  ///
  /// 200ms 是硬上限，超时就**不置就绪** → 原生保持「禁止拍」→ 白卡。
  /// 宁可白卡也不能拍到明文。
  Future<void> _allowRecentsScreenshot() async {
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 200));
      if (!mounted) return;
      // 纹理光栅很快，这里只留一点余量给 raster 线程收尾
      await Future<void>.delayed(const Duration(milliseconds: 4));
    } catch (_) {
      return; // 超时：不置就绪，交白卡
    }
    if (!mounted) return; // 遮罩已经被撤掉（比如瞬间又回到前台），没必要置就绪
    await PrivacyChannel.markMaskReady(_seq);
  }

  @override
  Widget build(BuildContext context) {
    // 必须用**已解码**的 ui.Image + RawImage。
    // Image.memory 是异步解码（IO 线程 + event loop），而遮罩从插入到被系统
    // 抓图只有一两帧，解码根本来不及 —— 表现就是圆盘里空着，
    // 也就是「频繁切换时中心没有应用图标」。RawImage 是同步绘制，零等待。
    final icon = PrivacyChannel.appIconImage;
    final frost = FrostTexture.image;
    // 磨砂底是**预渲染纹理**，不是 BackdropFilter。
    // 全屏高斯要 10–30ms，还要每帧分配一块全屏离屏纹理（约 18MB）；
    // 而点返回键 / 按 Home 退出时，留给遮罩的时间只有几十毫秒，
    // 真模糊经常来不及画完 → 系统拍到的是上一帧 → 白卡。
    // 换成一次纹理采样（1–2ms），链路才挤得进那个窗口。
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (frost != null)
            RawImage(
              image: frost,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
            )
          else
            // 纹理没生成好时的兜底：深色纯色，成本更低、同样不泄露内容
            const ColoredBox(color: Color(0xFF1E2126)),
          // 中央只放应用图标 + 右下角一个闭眼徽标，不放任何文字
          Center(
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1.2),
                  ),
                  alignment: Alignment.center,
                  child: icon != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: RawImage(
                            image: icon,
                            width: 62,
                            height: 62,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                          ),
                        )
                      : const Icon(Icons.visibility_off_outlined, size: 46, color: Colors.white),
                ),
                // 右下角闭眼徽标：明确表达「内容已隐藏」
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
        ],
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