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

  /// 月份列表的滚动控制器：「回到本月」时先回顶再精确定位。
  final ScrollController _monthScrollController = ScrollController();

  /// 本月卡片的 key：卡片高度不固定（有数据/未录入不同高），
  /// 不能用 index × 固定高度估算，靠它做精确滚动定位。
  final GlobalKey _thisMonthKey = GlobalKey();

  /// 左滑手势的起点（记录 global 坐标，用来判定方向 + 避开边缘/顶部横滑区）。
  Offset? _swipeStart;
  Offset? _swipeLatest;

  /// 跟手位移：手指往左移多少，主页就跟着左移多少（始终 <= 0）。
  /// 主页下面垫一层「设置」提示，左移时逐渐露出来。
  double _swipeDx = 0;

  /// 松手后的回弹动画：跟手位移平滑归位。
  late final AnimationController _swipeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// 当前挂着的回弹 listener，重复触发前先摘掉，避免累积。
  VoidCallback? _swipeAnimListener;

  @override
  void dispose() {
    _monthScrollController.dispose();
    final listener = _swipeAnimListener;
    if (listener != null) _swipeController.removeListener(listener);
    _swipeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
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

    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层：左滑时从右边露出来的「设置」提示。
        // 主页左移多少，这层就露多少，给出"要进设置页了"的视觉预期。
        _swipeReveal(),
        // 上层：主页整体跟手左移。
        Transform.translate(
          offset: Offset(_swipeDx, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
            child: GestureDetector(
              // 从右往左滑进入设置页。方向定义：手指向左移 = 当前页左移 = 设置页从右推入，
              // 和系统返回（左边缘右滑）方向相反，不会打架。
              behavior: HitTestBehavior.deferToChild,
              onHorizontalDragStart: _onSwipeStart,
              onHorizontalDragUpdate: _onSwipeUpdate,
              onHorizontalDragEnd: _onSwipeEnd,
              child: Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.receipt_long_outlined, size: 22),
            SizedBox(width: 8),
            Text('薪迹'),
          ],
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
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => _open(const StatsPage()),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const SettingsPage()),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const ImportPage()),
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('导入工资条'),
      ),
              ), // Scaffold
            ), // GestureDetector
          ), // DecoratedBox
        ), // Transform.translate
      ], // Stack children
    );
  }

  // ------------------------------------------------------------ 左滑进设置

  /// 这个起点能不能作为「左滑进设置」的手势：
  /// 避开左右边缘（系统返回 / 悬浮锁按钮）、顶部雇主横滑栏。
  bool _swipeStartAllowed(Offset start, Size size) {
    if (start.dx < 24 || start.dx > size.width - 24) return false;
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

    // 只跟「往左移」的位移；往右直接归零。最多跟到 1/3 屏，避免拖太多露白。
    final dx = d.globalPosition.dx - start.dx;
    final offset = dx >= 0 ? 0.0 : (dx < -size.width / 3 ? -size.width / 3 : dx);
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
    // 距离超过 1/3 屏，或末端速度足够快（快速轻扫），且方向向左 → 进设置。
    final commit = _swipeStartAllowed(start, size) &&
        dx < 0 &&
        (dx <= -size.width / 3 || (v != null && v <= -400));

    if (!commit) {
      // 不满足：跟手位移弹回 0。
      _animateSwipeBack(to: 0);
      return;
    }

    // 满足：先让跟手位移顺势滑完剩下的一小段（到 -1/3 屏），随即 push 设置页。
    // 不在 push 前把主页推到 -屏宽 —— 那样从设置页返回时会先露一瞬绿色底层
    // 再瞬间跳回。这里归零和 push 接在同一个动画尾，返回时主页已在原位。
    _animateSwipeBack(to: -size.width / 3, onDone: () {
      if (!mounted) return;
      // push 期间主页停在左移位；系统路由转场（设置页从右滑入）会盖住底层，
      // pop 返回后把主页复位到 0。
      _open(const SettingsPage()).then((_) {
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

  /// 主页左移时从右边露出来的设置提示层。
  Widget _swipeReveal() {
    return Container(
      color: kSeed,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 40),
      child: Opacity(
        // 跟手位移越大越清晰（0→0，1/3 屏→1）。
        opacity: (_swipeDx / (MediaQuery.of(context).size.width / 3))
            .abs()
            .clamp(0.0, 1.0)
            .toDouble(),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Icon(Icons.settings_outlined, size: 44, color: Colors.white),
            SizedBox(height: 10),
            Text('设置',
                style: TextStyle(
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
          // 回到本月：不论当前翻到哪一年，一键跳回「今年 + 本月」并把该月卡片滚到可见。
          // 和左右箭头/年份弹窗是不同用途 —— 那两个是浏览历史，这个是随时归位。
          IconButton(
            tooltip: '回到本月',
            icon: const Icon(Icons.today_outlined, size: 21),
            onPressed: _goToThisMonth,
          ),
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
