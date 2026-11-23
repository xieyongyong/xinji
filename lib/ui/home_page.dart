import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/cloud_auto_backup.dart';
import '../core/app_settings.dart';
import '../core/app_update.dart';
import '../core/money.dart';
import '../data/employer.dart';
import '../data/models.dart';
import '../security/lock_service.dart';
import '../state/app_state.dart';
import '../stats/salary_stats.dart';
import 'detail_page.dart';
import 'employer_page.dart';
import 'import_page.dart';
import 'lock_page.dart';
import 'review_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets/app_tip.dart';
import 'stats_page.dart';
import 'update_dialog.dart';
import 'year_picker.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  int _year = DateTime.now().year;

  /// 月份列表的滚动控制器：「回到本月」时先回顶，让懒加载的本月卡片 build 出来，
  /// 再用 key 精确定位。
  final ScrollController _monthScrollController = ScrollController();

  /// 本月卡片的 key：卡片高度不固定（有数据/未录入不同高），
  /// 不能用 index × 固定高度估算，靠它做精确滚动定位。
  final GlobalKey _thisMonthKey = GlobalKey();

  /// 横滑手势的起点（记录 global 坐标，用来判定方向 + 避开边缘/顶部横滑区）。
  Offset? _swipeStart;
  Offset? _swipeLatest;

  /// 跟手位移：手指往左移主页左移（负）露统计，往右移主页右移（正）露设置。
  /// 起点限制在屏幕中间偏右，左边缘让给系统返回。
  double _swipeDx = 0;

  /// 松手后要打开的目标页（由本次滑动方向决定），在动画回调里用。
  Widget? _swipeTargetPage;

  /// 导入按钮随列表滚动显隐：向下滚（看历史）隐藏，回到顶部显示。
  bool _fabVisible = true;
  double _lastScrollOffset = 0;

  /// 松手后的回弹动画：跟手位移平滑归位。
  late final AnimationController _swipeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// 当前挂着的回弹 listener，重复触发前先摘掉，避免累积。
  VoidCallback? _swipeAnimListener;

  @override
  void dispose() {
    _monthScrollController.removeListener(_onMonthScroll);
    _monthScrollController.dispose();
    final listener = _swipeAnimListener;
    if (listener != null) _swipeController.removeListener(listener);
    _swipeController.dispose();
    super.dispose();
  }

  /// 月份列表滚动：向下（看历史）隐藏导入按钮，向上（回顶部）显示。
  void _onMonthScroll() {
    if (!_monthScrollController.hasClients || !mounted) return;
    final offset = _monthScrollController.offset;
    final delta = offset - _lastScrollOffset;
    _lastScrollOffset = offset;
    // 留 2px 死区，避免惯性细微抖动导致按钮来回闪。
    if (delta > 2 && _fabVisible) {
      setState(() => _fabVisible = false);
    } else if (delta < -2 && !_fabVisible) {
      setState(() => _fabVisible = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _monthScrollController.addListener(_onMonthScroll);
    // 排成一条链：先问要不要开锁，再查更新。
    // 两个弹窗同时抢屏会叠在一起，而且"要不要加把锁"优先级更高。
    final settings = context.read<AppSettings>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybePromptLock();
      await _maybeCheckUpdate();
      // 排在最后：定时云盘备份是背景活，别跟弹窗抢时间
      await CloudAutoBackup.runIfDue(settings);
    });
  }

  /// 启动时静默检查更新（一天最多一次）。
  ///
  /// 失败一律不打扰：这类"锦上添花"的功能不该在打开 App 时弹错误框。
  /// 想主动看结果去「设置 → 检查更新」。
  Future<void> _maybeCheckUpdate() async {
    final latest = await UpdateChecker.autoCheck();
    if (latest == null || !mounted) return;
    final current = await UpdateChecker.currentVersion();
    if (!mounted) return;
    await showUpdateDialog(context, latest, currentVersion: current, auto: true);
  }

  /// 首次使用时引导开启应用锁（只弹一次，随时可跳过）
  Future<void> _maybePromptLock() async {
    final lock = context.read<LockService>();
    if (lock.enabled || !lock.needsSetup) return;

    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('lock_prompt_shown') == true) return;
    await sp.setBool('lock_prompt_shown', true);
    if (!mounted) return;

    final goSetup = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('要不要加把锁？'),
        content: const Text(
          '工资条属于敏感数据。开启应用锁后，打开薪迹需要指纹或 PIN，'
          '别人拿到你的手机也看不到工资明细。',
          style: TextStyle(height: 1.6, fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('以后再说')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去设置')),
        ],
      ),
    );

    if (goSetup == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SetupLockPage(allowSkip: false)),
      );
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    await context.read<AppState>().reload();
  }

  /// 底部圆形悬浮按钮：主题色半透明底 + 白色图标。
  /// hero 必须两者不同，否则 Flutter 会报「多个 FAB 共用同一个 hero tag」。
  Widget _roundFab({
    required String hero,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return FloatingActionButton(
      heroTag: hero,
      tooltip: tooltip,
      onPressed: onPressed,
      backgroundColor: kSeed.withOpacity(0.88),
      foregroundColor: Colors.white,
      child: Icon(icon, size: 26),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // 金额打码的开关放在顶栏：这是随时要用的"遮挡一下"，不该藏在设置里翻三层
    final hideAmounts = context.watch<AppSettings>().hideAmounts;
    final years = state.years;

    final year = _year;
    final summary = StatsBuilder.buildYear(state.scopedRecords, year);
    // 年份弹窗里每年带一个实发数：光看年份号不知道哪年有数据、哪年多。
    final netByYear = years.length > 1
        ? {
            for (final y in years)
              y: y == year
                  ? summary.totalNet
                  : StatsBuilder.buildYear(state.scopedRecords, y).totalNet,
          }
        : const <int, int>{};
    final now = DateTime.now();
    final employer = state.currentEmployer;
    // 已经离职的雇主不该再提醒"这个月还没录入"
    final stillActive = employer == null || employer.covers(now.year, now.month);

    // 跟手位移对应的渐显进度（0→1）：静止为 0，只用于底层预览层渐显。
    final swipeProgress =
        (_swipeDx.abs() / (MediaQuery.of(context).size.width / 3))
            .clamp(0.0, 1.0)
            .toDouble();
    final home = Scaffold(
      appBar: AppBar(
        // 左上角「薪迹」logo 即设置入口（右上角不再单独放设置按钮）。
        title: GestureDetector(
          onTap: () => _open(const SettingsPage()),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_long_outlined, size: 22),
              SizedBox(width: 8),
              Text('薪迹'),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: hideAmounts ? '显示金额' : '隐藏金额（当着别人查数据时用）',
            icon: Icon(
              hideAmounts
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () {
              context.read<AppSettings>().setHideAmounts(!hideAmounts);
              showTip(context, hideAmounts ? '金额已显示' : '金额已打码，再点一次恢复',
                  duration: const Duration(seconds: 2));
            },
          ),
          IconButton(
            tooltip: '统计（总计 / 年度 / 月度 / 项目 / 雇主）',
            // 柱状图图标，和截图一致（方框内竖条）。
            icon: const Icon(Icons.bar_chart_outlined),
            onPressed: () => _open(const StatsPage()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // 下载进度条已改成全局浮层（见 main.dart），切到任何页面都可见。
          if (state.employers.length > 1) _employerBar(state),
          _yearBar(years, year, netByYear),
          _summaryStrip(summary),
          if (stillActive && year == now.year && summary.months[now.month - 1].isEmpty)
            _missingBanner(now.month),
          Expanded(
            child: ListView.builder(
              controller: _monthScrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              itemCount: 12,
              itemBuilder: (context, index) {
                final month = 12 - index;
                // 当年的未来月份不显示
                if (year == now.year && month > now.month) {
                  return const SizedBox.shrink();
                }
                final m = summary.months[month - 1];
                final prev = month > 1 ? summary.months[month - 2] : null;
                final card = _monthCard(m, prev, year);
                // 只给「今年本月」挂 key，供「回到本月」精确定位；
                // 其他月份不加 key，避免 GlobalKey 重复。
                return year == now.year && month == now.month
                    ? KeyedSubtree(key: _thisMonthKey, child: card)
                    : card;
              },
            ),
          ),
        ],
      ),
      // 底部两个圆形按钮：左下「回到本月」、右下「导入」，主题色半透明。
      // 向下滚看历史时一起缩没，回到顶部时一起弹回来（钱迹式）。
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: AnimatedScale(
        scale: _fabVisible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: _fabVisible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: SizedBox(
            width: MediaQuery.of(context).size.width - 32,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _roundFab(
                  hero: 'fab_this_month',
                  tooltip: '回到本月（重新定位到当前月份）',
                  icon: Icons.my_location,
                  onPressed: _goToThisMonth,
                ),
                _roundFab(
                  hero: 'fab_import',
                  tooltip: '导入工资条',
                  icon: Icons.add,
                  onPressed: () => _open(const ImportPage()),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层双向预览：左滑露统计（右）、右滑露设置（左），跟手渐显。
        Positioned.fill(child: _swipeReveal(swipeProgress)),
        // 上层主页：跟手平移。去掉高斯模糊，只平移露出底层预览层。
        Transform.translate(
          offset: Offset(_swipeDx, 0),
          child: DecoratedBox(
            decoration:
                BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  // 左滑进统计、右滑进设置；起点限制避开系统返回与横滑区。
                  behavior: HitTestBehavior.deferToChild,
                  onHorizontalDragStart: _onSwipeStart,
                  onHorizontalDragUpdate: _onSwipeUpdate,
                  onHorizontalDragEnd: _onSwipeEnd,
                  child: home,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 横滑进统计 / 设置

  /// 这个起点能不能作为横滑手势：
  /// 起点必须在「中间偏右」区域——左边缘 1/3 让给系统返回（右滑），
  /// 左右各 24dp 避开系统边缘与悬浮锁，顶部雇主横滑栏也让开。
  bool _swipeStartAllowed(Offset start, Size size) {
    if (start.dx < size.width / 3 || start.dx > size.width - 24) return false;
    // 雇主栏在 AppBar 之下，起点 y 落在 AppBar 高度 + 雇主栏 40 内让给它。
    final topLimit = kToolbarHeight + 40 + 24;
    if (start.dy < topLimit) return false;
    return true;
  }

  void _onSwipeStart(DragStartDetails d) {
    _swipeStart = d.globalPosition;
    _swipeLatest = d.globalPosition;
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    final start = _swipeStart;
    if (start == null || !mounted) return;
    _swipeLatest = d.globalPosition;

    // 无效起点的手势不让主页跟着动，否则边缘返回、雇主横滑都会带着整页偏。
    final size = MediaQuery.of(context).size;
    if (!_swipeStartAllowed(start, size)) return;

    // 双向跟手：左移露统计（负），右移露设置（正），最多 1/3 屏。
    final limit = size.width / 3;
    final dx = d.globalPosition.dx - start.dx;
    final offset = dx.clamp(-limit, limit);
    if (offset != _swipeDx) setState(() => _swipeDx = offset);
  }

  void _onSwipeEnd(DragEndDetails d) {
    final start = _swipeStart;
    final latest = _swipeLatest;
    _swipeStart = null;
    _swipeLatest = null;
    if (start == null || latest == null || !mounted) return;

    final size = MediaQuery.of(context).size;
    final dx = latest.dx - start.dx;
    final v = d.primaryVelocity;
    final limit = size.width / 3;

    // 距离超过 1/3 屏，或末端速度够快（快速轻扫）即触发；方向决定目标页。
    final farEnough = dx.abs() >= limit;
    final fastEnough = v != null && v.abs() >= 400 && (dx.sign == v.sign);
    final commit = _swipeStartAllowed(start, size) && (farEnough || fastEnough);

    if (!commit) {
      _animateSwipeBack(to: 0);
      return;
    }

    // 左滑（负）→ 统计；右滑（正）→ 设置。
    _swipeTargetPage = dx < 0 ? const StatsPage() : const SettingsPage();
    // 顺势滑完到目标侧 1/3 屏，动画尾 push 目标页；pop 返回后复位到 0。
    _animateSwipeBack(to: dx < 0 ? -limit : limit, onDone: () {
      if (!mounted) return;
      final page = _swipeTargetPage ?? const SettingsPage();
      _swipeTargetPage = null;
      _open(page).then((_) {
        if (mounted) setState(() => _swipeDx = 0);
      });
    });
  }

  /// 松手后把跟手位移动画到 [to]。
  void _animateSwipeBack({required double to, VoidCallback? onDone}) {
    // 上一次动画若还没结束，先摘掉它的 listener，避免多个 listener 叠加 setState。
    final prev = _swipeAnimListener;
    if (prev != null) _swipeController.removeListener(prev);

    final from = _swipeDx;
    if (from == to) {
      onDone?.call();
      return;
    }
    final anim = Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _swipeController, curve: Curves.easeOut),
    );
    void listener() {
      if (!mounted) return;
      setState(() => _swipeDx = anim.value);
    }
    _swipeAnimListener = listener;
    _swipeController
      ..reset()
      ..addListener(listener);
    _swipeController.forward().then((_) {
      _swipeController.removeListener(listener);
      if (identical(_swipeAnimListener, listener)) _swipeAnimListener = null;
      onDone?.call();
    });
  }

  /// 横滑时主页让出的底层预览：左滑露统计（右侧）、右滑露设置（左侧）。
  /// 静态预览层，纯图标+文字，不加下划线。
  Widget _swipeReveal(double progress) {
    final toStats = _swipeDx < 0;
    final icon = toStats ? Icons.bar_chart_outlined : Icons.settings_outlined;
    final label = toStats ? '统计' : '设置';
    return Container(
      color: kSeed,
      alignment: toStats ? Alignment.centerRight : Alignment.centerLeft,
      padding: EdgeInsets.symmetric(horizontal: 40),
      child: Opacity(
        opacity: progress,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              toStats ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 44, color: Colors.white),
            const SizedBox(height: 10),
            Text(label,
                style: const TextStyle(
                    fontSize: 18, color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 顶部区域

  /// 雇主切换。只有一家时不显示 —— 没有可切的东西，白占一行。
  Widget _employerBar(AppState state) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        itemCount: state.employers.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == state.employers.length) {
            return GestureDetector(
              onTap: () => _open(const EmployerPage()),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.tune, size: 18, color: kTextHint),
              ),
            );
          }
          final Employer e = state.employers[i];
          final selected = e.id == state.currentEmployerId;
          return GestureDetector(
            onTap: () => state.switchEmployer(e.id!),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: selected ? kSeed : kSurfaceAlt,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Center(
                child: Text(
                  e.name,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: selected ? Colors.white : kTextMedium,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _yearBar(List<int> years, int year, Map<int, int> netByYear) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _year = year - 1),
          ),
          // 年份本身可点：弹窗里一年一格、带该年实发，比原来那个
          // 「右侧图标 → 弹出下拉菜单」的入口直观，也和多选月份的操作一致。
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: years.length > 1 ? () => _pickYear(years, year, netByYear) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$year 年',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  if (years.length > 1) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more, size: 18, color: kTextHint),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: year < DateTime.now().year
                ? () => setState(() => _year = year + 1)
                : null,
          ),
          // 回到本月已移到左下悬浮按钮，和右下导入按钮对称。
        ],
      ),
    );
  }

  /// 回到实时当前月份：年份切回今年，月份列表滚到本月卡片。
  ///
  /// 卡片高度不固定（有数据的一月可能十几笔、没录入的只有一行），
  /// 所以不能按 index×固定高度 jumpTo —— 用挂在本月卡片上的 GlobalKey
  /// 让 Scrollable 自己算真实偏移。等一帧让新年份的列表 layout 完再滚。
  void _goToThisMonth() {
    final now = DateTime.now();
    setState(() => _year = now.year);
    // 列表是懒加载的：若之前停在底部，本月卡片的 context 还没 build，
    // 直接 ensureVisible 会拿不到目标。先回顶让顶部 item（含本月）建出来，
    // 下一帧再用 key 精确对齐到本月卡片。
    if (_monthScrollController.hasClients) _monthScrollController.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _thisMonthKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.15,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _pickYear(
    List<int> years,
    int year,
    Map<int, int> netByYear,
  ) async {
    final pick = await showYearPicker(
      context,
      years: years,
      initial: year,
      netByYear: netByYear,
    );
    if (pick?.year != null && mounted) setState(() => _year = pick!.year!);
  }

  Widget _summaryStrip(YearSummary s) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: kSeed,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本年实发合计',
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.8)),
                ),
                const SizedBox(height: 4),
                Text(
                  displayCents(s.totalNet),
                  style: moneyStyle(size: 24, color: Colors.white),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _stripMini('工资', displayCents(s.totalMonthlyNet)),
              const SizedBox(height: 3),
              _stripMini('奖金', displayCents(s.totalExtraNet)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stripMini(String label, String value) => Text(
        '$label $value',
        style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.85)),
      );

  Widget _missingBanner(int month) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33E9B949)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 17, color: kWarnIcon),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$month 月还没录入。工资条一般一周就失效，记得及时截图导入。',
              style: TextStyle(fontSize: 12.5, color: kWarnText, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 月份卡片

  Widget _monthCard(MonthSummary m, MonthSummary? prev, int year) {
    if (m.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(ReviewPage.create(year: year, month: m.month)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kDivider, style: BorderStyle.solid),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text('${m.month}月',
                      style: TextStyle(fontSize: 15, color: kTextHint)),
                ),
                Text('未录入', style: TextStyle(fontSize: 13, color: kTextHint)),
                const Spacer(),
                Icon(Icons.add, size: 18, color: kTextHint),
              ],
            ),
          ),
        ),
      );
    }

    final monthlyNet = m.monthlyNet;
    int? delta;
    if (prev != null && prev.monthly.isNotEmpty && m.monthly.isNotEmpty) {
      delta = monthlyNet - prev.monthlyNet;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: cardDecoration(),
        child: Column(
          children: [
            // 卡片头：月份 + 该月合计 + 环比
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('${m.month}月',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  if (m.hasMultiple) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: kInfoBg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${m.monthly.length}笔',
                          style: TextStyle(fontSize: 10.5, color: kSeed)),
                    ),
                  ],
                  const Spacer(),
                  if (delta != null) ...[
                    _deltaChip(delta),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    displayCents(m.totalNet),
                    style: moneyStyle(size: 17),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 每条记录一行（同月多笔：正常 + 补发 + 奖金）
            for (final r in m.monthly) _recordRow(r),
            for (final r in m.extras) _recordRow(r, isExtra: true),
          ],
        ),
      ),
    );
  }

  Widget _deltaChip(int delta) {
    final up = delta > 0;
    final color = delta == 0
        ? kTextHint
        : context.watch<AppSettings>().diffColor(delta);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(up ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: color),
        Text(
          displayCents(delta.abs(), withSymbol: false),
          style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _recordRow(PayRecord r, {bool isExtra = false}) {
    return InkWell(
      onTap: () => _open(DetailPage(recordId: r.id!)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 15,
              decoration: BoxDecoration(
                color: isExtra ? kDeductionFg : kSeed,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                isExtra ? (r.recordLabel ?? '其他收入') : '工资明细',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: kTextBody),
              ),
            ),
            if (isExtra) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: kExtraBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('额外',
                    style: TextStyle(fontSize: 10, color: kDeductionFg)),
              ),
            ],
            const SizedBox(width: 10),
            Text(
              displayCents(r.netCents),
              style: TextStyle(
                fontSize: 13.5,
                color: kTextPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 16, color: kTextFaint),
          ],
        ),
      ),
    );
  }
}
