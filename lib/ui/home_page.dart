import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'stats_page.dart';
import 'update_dialog.dart';
import 'widgets/update_progress_strip.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _year = DateTime.now().year;

  /// 上一次看到的雇主，用来判断"是不是刚切了雇主"
  int? _lastEmployerId;

  @override
  void initState() {
    super.initState();
    // 排成一条链：先问要不要开锁，再查更新。
    // 两个弹窗同时抢屏会叠在一起，而且"要不要加把锁"优先级更高。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybePromptLock();
      await _maybeCheckUpdate();
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
    final years = state.years;

    // 刚切换雇主时，把年份跳到它最近的记录年份。
    // 为什么不在 build 里无脑判断"今年有没有数据"：那样用户想翻到一个
    // 还没录入的年份时会被立刻弹回来，没法录新一年的第一条。
    final employerId = state.currentEmployer?.id;
    if (_lastEmployerId != employerId) {
      _lastEmployerId = employerId;
      _year = state.scopedRecords.isNotEmpty
          ? state.scopedRecords.first.periodYear
          : DateTime.now().year;
    }
    final year = _year;
    final summary = StatsBuilder.buildYear(state.scopedRecords, year);
    final now = DateTime.now();
    final employer = state.currentEmployer;
    // 已经离职的雇主不该再提醒"这个月还没录入"
    final stillActive = employer == null || employer.covers(now.year, now.month);

    return Scaffold(
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
          // 后台下载更新时只占 3px；完成后变一条"点此安装"。
          // 不弹窗、不跳转，用户继续查数据不受影响。
          const UpdateProgressStrip(),
          if (state.employers.length > 1) _employerBar(state),
          _yearBar(years, year),
          _summaryStrip(summary),
          if (stillActive && year == now.year && summary.months[now.month - 1].isEmpty)
            _missingBanner(now.month),
          Expanded(
            child: ListView.builder(
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
                return _monthCard(m, prev, year);
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
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.tune, size: 18, color: Color(0xFF9AA09A)),
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
                color: selected ? kSeed : const Color(0xFFF2F4F2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Center(
                child: Text(
                  e.name,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: selected ? Colors.white : const Color(0xFF5A5F5A),
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

  Widget _yearBar(List<int> years, int year) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _year = year - 1),
          ),
          Text('$year 年', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: year < DateTime.now().year
                ? () => setState(() => _year = year + 1)
                : null,
          ),
          const Spacer(),
          if (years.length > 1)
            PopupMenuButton<int>(
              tooltip: '切换年份',
              icon: const Icon(Icons.unfold_more, size: 20),
              onSelected: (y) => setState(() => _year = y),
              itemBuilder: (_) => years
                  .map((y) => PopupMenuItem(value: y, child: Text('$y 年')))
                  .toList(),
            ),
        ],
      ),
    );
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
                  formatCents(s.totalNet),
                  style: moneyStyle(size: 24, color: Colors.white),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _stripMini('工资', formatCents(s.totalMonthlyNet)),
              const SizedBox(height: 3),
              _stripMini('奖金', formatCents(s.totalExtraNet)),
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
          const Icon(Icons.error_outline, size: 17, color: Color(0xFF9A6B00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$month 月还没录入。工资条一般一周就失效，记得及时截图导入。',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B4E00), height: 1.45),
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
              border: Border.all(color: const Color(0xFFE6E8E6), style: BorderStyle.solid),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text('${m.month}月',
                      style: const TextStyle(fontSize: 15, color: Color(0xFFB0B5B0))),
                ),
                const Text('未录入', style: TextStyle(fontSize: 13, color: Color(0xFFB0B5B0))),
                const Spacer(),
                const Icon(Icons.add, size: 18, color: Color(0xFFB0B5B0)),
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
                          style: const TextStyle(fontSize: 10.5, color: kSeed)),
                    ),
                  ],
                  const Spacer(),
                  if (delta != null) ...[
                    _deltaChip(delta),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    formatCents(m.totalNet),
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
        ? const Color(0xFF9AA09A)
        : context.watch<AppSettings>().diffColor(delta);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(up ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: color),
        Text(
          formatCents(delta.abs(), withSymbol: false),
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
                color: isExtra ? const Color(0xFFB45309) : kSeed,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                isExtra ? (r.recordLabel ?? '其他收入') : '工资明细',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, color: Color(0xFF4A4F4A)),
              ),
            ),
            if (isExtra) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDF1E7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('额外',
                    style: TextStyle(fontSize: 10, color: Color(0xFFB45309))),
              ),
            ],
            const SizedBox(width: 10),
            Text(
              formatCents(r.netCents),
              style: TextStyle(
                fontSize: 13.5,
                color: const Color(0xFF1B1C1B),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right, size: 16, color: Color(0xFFC4C9C4)),
          ],
        ),
      ),
    );
  }
}
