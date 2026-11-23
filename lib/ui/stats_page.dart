import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../data/employer.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../stats/range_stats.dart';
import 'compare_page.dart';
import 'theme.dart';
import 'year_picker.dart';

/// 统计维度。用户嘴上说的"按维度看"，落到代码就是这四种切换：
/// 年度（每年拿了多少）/ 月度（哪个月通常高）/ 项目（钱从哪来、扣在哪）/ 雇主（跳槽前后的对比）
enum StatsDimension { year, month, item, employer }

extension on StatsDimension {
  String get label => switch (this) {
        StatsDimension.year => '年度',
        StatsDimension.month => '月度',
        StatsDimension.item => '项目',
        StatsDimension.employer => '雇主',
      };
}

/// 统计页：范围可切「全部 / 某一年」，维度可切「年度 / 月度 / 项目 / 雇主」。
///
/// 为什么要有「全部」这一档：原来只能一年年看，想知道"毕业到现在一共拿了多少"
/// 得自己把数字加起来。总计是工资记录类应用最常被问的一句话。
class StatsPage extends StatefulWidget {
  /// 进来时先看哪一年；为空表示「全部年份」
  final int? initialYear;

  const StatsPage({super.key, this.initialYear});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int? _year;
  StatsDimension _dim = StatsDimension.year;
  bool _showAllItems = false;

  /// 月度维度：是否把不同年份的同一个月合并看（默认不合并，改按年折线）
  bool _monthMerged = false;

  /// 月度折线当前看哪一年（为空则取最近一年）
  int? _chartYear;

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final years = state.years;

    // 切到旧雇主时，选中的年份可能在它名下没有记录 —— 退回「全部」，
    // 而不是给一屏空白
    if (_year != null && !years.contains(_year)) _year = null;

    final base = state.scopedRecords;
    final inScope = _year == null
        ? base
        : base.where((r) => r.periodYear == _year).toList();
    final sum = RangeSummary(inScope);

    // 「雇主」维度要看全部雇主的记录，不能只用当前雇主那一份；
    // 数据在 build 里算好一次传下去，页面内各处复用同一个 RangeSummary（内部有懒缓存）。
    final crossEmployer = _year == null
        ? state.records
        : state.records.where((r) => r.periodYear == _year).toList();
    final crossSum = _dim == StatsDimension.employer
        ? RangeSummary(crossEmployer)
        : sum;

    // 年份弹窗里每年带实发数，顺便替代原来那排「全部 / 2026 年 / 2025 年」
    // 横滑 chips —— 年份一多就得滚，还不知道哪年有数据。
    final netByYear = _yearNetByYear(base);

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: [
          if (_year != null)
            IconButton(
              icon: const Icon(Icons.compare_arrows),
              tooltip: '月份对比',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ComparePage(year: _year!)),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          _scopeBar(years, netByYear),
          const SizedBox(height: 14),
          _overview(sum, state),
          const SizedBox(height: 14),
          _dimensionSwitch(),
          const SizedBox(height: 14),
          ..._content(state, sum, crossSum),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 范围选择

  Widget _scopeBar(List<int> years, Map<int, int> netByYear) {
    final label = _year == null ? '全部年份' : '$_year 年';
    // 只有一个年份时没什么可切，也让它可点（能顺手看到"全部"那一档）
    final tappable = years.length > 1 || _year != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tappable ? () => _pickScope(years, netByYear) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDivider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_outlined, size: 16, color: kTextSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: kTextPrimary,
                ),
              ),
              if (tappable) ...[
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 16, color: kTextHint),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickScope(List<int> years, Map<int, int> netByYear) async {
    final pick = await showYearPicker(
      context,
      years: years,
      initial: _year,
      allowAll: true,
      netByYear: netByYear,
      title: '统计范围',
    );
    // pick 为 null 是取消；pick.year 为 null 是选了「全部年份」，要区分开
    if (pick != null && mounted) setState(() => _year = pick.year);
  }

  /// 每年实发合计（分），给年份弹窗做副标题
  Map<int, int> _yearNetByYear(List<PayRecord> records) {
    final out = <int, int>{};
    for (final r in records) {
      out[r.periodYear] = (out[r.periodYear] ?? 0) + r.netCents;
    }
    return out;
  }

  // ------------------------------------------------------------ 总览

  Widget _overview(RangeSummary s, AppState state) {
    final title = _year == null ? '全部年份总计' : '$_year 年';
    final sub = s.isEmpty
        ? '这个范围还没有记录'
        : (s.periodLabel.isEmpty ? '' : '覆盖 ${s.periodLabel} · ${s.recordCount} 笔');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSeed,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13.5, color: Colors.white.withOpacity(0.9))),
              const Spacer(),
              if (sub.isNotEmpty)
                Text(sub,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.white.withOpacity(0.7))),
            ],
          ),
          const SizedBox(height: 6),
          Text(displayCents(s.totalNet),
              style: moneyStyle(size: 30, color: Colors.white)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _block('工资收入', s.monthlyNet)),
              _vline(),
              Expanded(child: _block('奖金 / 额外', s.extraNet)),
              _vline(),
              Expanded(
                child: _block('月均', s.avgNet, hint: '${s.monthCount} 个月'),
              ),
            ],
          ),
          if (s.totalGross > 0) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: Colors.white.withOpacity(0.15)),
            const SizedBox(height: 9),
            Row(
              children: [
                Text('应发 ${displayCents(s.totalGross)}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.8))),
                const Spacer(),
                Text('代扣 ${displayCents(s.totalDeduction)}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.8))),
                const Spacer(),
                Text('实发率 ${_percent(s.monthlyNet, s.totalGross)}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.8))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _vline() =>
      Container(width: 1, height: 30, color: Colors.white.withOpacity(0.18));

  Widget _block(String label, int value, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10.5, color: Colors.white.withOpacity(0.7))),
        const SizedBox(height: 3),
        Text(displayCents(value), style: moneyStyle(size: 13.5, color: Colors.white)),
        if (hint != null)
          Text(hint,
              style: TextStyle(
                  fontSize: 9.5, color: Colors.white.withOpacity(0.55))),
      ],
    );
  }

  /// 实发率：实发 / 应发。总比"扣了多少"更有体感
  String _percent(int part, int whole) {
    if (whole <= 0) return '—';
    return '${(part / whole * 100).toStringAsFixed(1)}%';
  }

  // ------------------------------------------------------------ 维度切换

  Widget _dimensionSwitch() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<StatsDimension>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: [
          for (final d in StatsDimension.values)
            ButtonSegment(
              value: d,
              label: Text(d.label, style: const TextStyle(fontSize: 12.5)),
            ),
        ],
        selected: {_dim},
        onSelectionChanged: (s) => setState(() => _dim = s.first),
      ),
    );
  }

  List<Widget> _content(
      AppState state, RangeSummary sum, RangeSummary crossSum) {
    if (sum.isEmpty && _dim != StatsDimension.employer) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 60),
          child: Column(
            children: [
              Icon(Icons.insights_outlined, size: 40, color: kTextFaint),
              SizedBox(height: 12),
              Text('这个范围还没有数据',
                  style: TextStyle(fontSize: 13.5, color: kTextSecondary)),
            ],
          ),
        ),
      ];
    }

    switch (_dim) {
      case StatsDimension.year:
        return [_yearCard(sum), if (sum.extraByLabel.isNotEmpty) ...[
          const SizedBox(height: 14),
          _extraCard(sum),
        ]];
      case StatsDimension.month:
        return [_monthCard(sum)];
      case StatsDimension.item:
        return [
          _itemCard(sum, kCategoryIncome),
          const SizedBox(height: 14),
          _itemCard(sum, kCategoryDeduction),
          if (sum.extraByLabel.isNotEmpty) ...[
            const SizedBox(height: 14),
            _extraCard(sum),
          ],
        ];
      case StatsDimension.employer:
        return [_employerCard(state, crossSum)];
    }
  }

  // ------------------------------------------------------------ 年度

  Widget _yearCard(RangeSummary s) {
    final years = s.byYear;
    final maxNet = years.fold<int>(1, (m, y) => y.net > m ? y.net : m);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('按年份',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (years.length > 1)
                Text('总计 ${displayCents(s.totalNet)}',
                    style: TextStyle(
                        fontSize: 11.5, color: kTextSecondary)),
            ],
          ),
          const SizedBox(height: 10),
          for (final y in years) ...[
            InkWell(
              onTap: () => setState(() {
                _year = y.year;
                _dim = StatsDimension.month;
              }),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text('${y.year}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: (y.net / maxNet).clamp(0.0, 1.0).toDouble(),
                              minHeight: 8,
                              backgroundColor: kBorder,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(kSeed),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 96,
                          child: Text(
                            displayCents(y.net),
                            textAlign: TextAlign.right,
                            style: _amount(),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 52, top: 3),
                      child: Text(
                        '${y.months} 个月 · 月均 ${displayCents(y.avgNet)}'
                        '${y.extraNet > 0 ? ' · 含奖金 ${displayCents(y.extraNet)}' : ''}',
                        style: TextStyle(
                            fontSize: 10.5, color: kTextHint),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 2),
          Text('点某一年可切到它的月度明细',
              style: TextStyle(fontSize: 10.5, color: kTextHint)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 月度

  /// 月度维度。
  ///
  /// 默认**按年折线**：折线比柱子更容易看出"哪个月往下掉"。
  /// 「跨年合并」是另一条路（把每年同一个月加在一起），因为它会把
  /// 2025 和 2026 的 3 月叠成一个数，容易误读，所以不设默认，需要用户主动切。
  Widget _monthCard(RangeSummary s) {
    final years = s.byYear.map((e) => e.year).toList()..sort((a, b) => b.compareTo(a));
    if (s.isEmpty || years.isEmpty) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        decoration: cardDecoration(),
        child: Text('这个范围还没有数据',
            style: TextStyle(fontSize: 13, color: kTextSecondary)),
      );
    }

    final showMerged = _year == null && _monthMerged && years.length > 1;
    final chartYear = _year ??
        (_chartYear != null && years.contains(_chartYear) ? _chartYear! : years.first);
    final net = _monthlyNetOf(s, chartYear);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  showMerged ? '各月累计（跨年合并）' : '$chartYear 年 · 月度实发',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              if (_year == null && years.length > 1)
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('折线')),
                    ButtonSegment(value: true, label: Text('合并')),
                  ],
                  selected: {_monthMerged},
                  onSelectionChanged: (v) =>
                      setState(() => _monthMerged = v.first),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            showMerged
                ? '把每年的同一个月份加在一起看长期规律（会叠加不同年份）'
                : '点数据点可打开该月与上月的逐项对比',
            style: TextStyle(fontSize: 11.5, color: kTextSecondary),
          ),
          if (!showMerged && _year == null && years.length > 1) ...[
            const SizedBox(height: 10),
            _chartYearPicker(chartYear, years, s),
          ],
          const SizedBox(height: 12),
          if (showMerged)
            _mergedBars(s)
          else
            _lineChart(chartYear, net),
          if (!showMerged) _lineSummary(net),
        ],
      ),
    );
  }

  /// 折线图看哪一年：点开弹窗选，跟对比页、统计范围共用一套选年手感。
  /// 以前是一排年份 chip 横滑，年份多了要滚着找，也看不出哪年数据多少。
  Widget _chartYearPicker(int year, List<int> years, RangeSummary s) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final pick = await showYearPicker(
            context,
            years: years,
            initial: year,
            netByYear: {for (final a in s.byYear) a.year: a.net},
            title: '图表年份',
          );
          if (pick?.year != null && mounted) {
            setState(() => _chartYear = pick!.year!);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: kSurfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDivider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$year 年',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: kTextPrimary,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 16, color: kTextHint),
            ],
          ),
        ),
      ),
    );
  }

  /// 某一年 12 个月的月度实发（分）。`has[i]` 表示这个月有没有记录。
  ({List<int> values, List<bool> has}) _monthlyNetOf(RangeSummary s, int year) {
    final values = List<int>.filled(12, 0);
    final has = List<bool>.filled(12, false);
    for (final r in s.records) {
      if (r.recordType != kTypeMonthly || r.periodYear != year) continue;
      final m = r.periodMonth;
      if (m < 1 || m > 12) continue;
      values[m - 1] += r.netCents;
      has[m - 1] = true;
    }
    return (values: values, has: has);
  }

  Widget _lineChart(int year, ({List<int> values, List<bool> has}) data) {
    return SizedBox(
      height: 172,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _MonthLinePainter(
                values: data.values,
                has: data.has,
                line: kSeed,
                grid: kDivider,
                label: kTextHint,
                dotBg: kSurface,
                masked: kMaskAmounts,
              ),
            ),
          ),
          // 透明点击区，精确到每个月：点 3 月就打开 3 月对比
          Positioned(
            left: _MonthLinePainter.leftPad,
            right: _MonthLinePainter.rightPad,
            top: _MonthLinePainter.topPad,
            bottom: _MonthLinePainter.bottomPad,
            child: Row(
              children: [
                for (var m = 0; m < 12; m++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: data.has[m]
                          ? () => _openPeriod(year, m + 1)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 折线下方的三个关键数字
  Widget _lineSummary(({List<int> values, List<bool> has}) data) {
    var maxMonth = -1;
    var maxVal = 0;
    var sum = 0;
    var count = 0;
    for (var i = 0; i < 12; i++) {
      if (!data.has[i]) continue;
      count++;
      sum += data.values[i];
      if (data.values[i] > maxVal) {
        maxVal = data.values[i];
        maxMonth = i + 1;
      }
    }
    final avg = count == 0 ? 0 : (sum / count).round();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: _miniStat('最高',
                maxMonth > 0 ? '${maxMonth}月 ${displayCents(maxVal)}' : '—'),
          ),
          Expanded(child: _miniStat('月均', displayCents(avg))),
          Expanded(child: _miniStat('有记录', '$count 个月')),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: kTextHint)),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _amount()),
      ],
    );
  }

  /// 跨年合并：原来的柱状视图（把每年同月加总）
  Widget _mergedBars(RangeSummary s) {
    final months = s.byMonthOfYear;
    final maxNet = months.fold<int>(0, (m, e) => e.net > m ? e.net : m);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final m in months)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: maxNet == 0
                            ? 2
                            : (m.net == 0 ? 2 : (m.net / maxNet) * 92 + 2),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: m.isEmpty ? kBorder : kSeed,
                          borderRadius:
                              const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${m.month}',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: m.isEmpty ? kTextFaint : kTextMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 22),
        for (final m in months)
          if (!m.isEmpty && m.times > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text('${m.month} 月',
                        style: TextStyle(fontSize: 12, color: kTextMedium)),
                  ),
                  Text('${m.times} 年',
                      style: TextStyle(fontSize: 11, color: kTextHint)),
                  const Spacer(),
                  Text(
                    '合计 ${displayCents(m.net)} · 平均 ${displayCents(m.avgNet)}',
                    style: _amount(),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  void _openPeriod(int year, int month) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ComparePage(year: year, focusMonth: month)),
    );
  }

  // ------------------------------------------------------------ 项目

  Widget _itemCard(RangeSummary s, String category) {
    final isIncome = category == kCategoryIncome;
    final list = isIncome ? s.incomeByItem : s.deductionByItem;
    final total = list.fold<int>(0, (a, e) => a + e.value);
    // 跟随主题的前景语义色：收入红、扣款绿（深色模式自动变亮）。
    final color = isIncome ? kIncomeFg : kDeductionFg;
    final shown = _showAllItems ? list : list.take(10).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _colorBar(color),
              const SizedBox(width: 8),
              Text(isIncome ? '钱从哪来' : '钱扣在哪',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(displayCents(total), style: _amount(color: color)),
            ],
          ),
          const SizedBox(height: 8),
          if (list.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('这个范围没有相关记录',
                  style: TextStyle(fontSize: 12, color: kTextHint)),
            ),
          for (final e in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(e.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: kTextBody)),
                  ),
                  SizedBox(
                    width: 46,
                    child: Text(
                      total == 0
                          ? ''
                          : '${(e.value / total * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 10.5, color: kTextHint),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 92,
                    child: Text(displayCents(e.value),
                        textAlign: TextAlign.right,
                        style: _amount()),
                  ),
                ],
              ),
            ),
          if (list.length > 10)
            TextButton(
              onPressed: () => setState(() => _showAllItems = !_showAllItems),
              child: Text(_showAllItems ? '收起' : '展开全部 ${list.length} 项'),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 雇主

  Widget _employerCard(AppState state, RangeSummary sum) {
    final rows = sum.netByEmployer;
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        decoration: cardDecoration(),
        child: Text('这个范围还没有记录',
            style: TextStyle(fontSize: 13, color: kTextSecondary)),
      );
    }
    final total = rows.fold<int>(0, (s, e) => s + e.value);
    final maxNet = rows.fold<int>(1, (m, e) => e.value > m ? e.value : m);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('按雇主',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(displayCents(total),
                  style: moneyStyle(size: 13, color: kTextBody)),
            ],
          ),
          const SizedBox(height: 10),
          for (final row in rows)
            InkWell(
              onTap: row.key <= 0
                  ? null
                  : () => state.switchEmployer(row.key),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _colorBar(row.key == state.currentEmployerId
                            ? kSeed
                            : kBorder),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _employerName(state, row.key) +
                                (row.key == state.currentEmployerId
                                    ? '（当前）'
                                    : ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: kTextBody),
                          ),
                        ),
                        Text(displayCents(row.value), style: _amount()),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 11),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: (row.value / maxNet).clamp(0.0, 1.0).toDouble(),
                          minHeight: 6,
                          backgroundColor: kBorder,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            row.key == state.currentEmployerId
                                ? kSeed
                                : kTextFaint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 2),
          Text('点某一家可切换过去查看它的明细',
              style: TextStyle(fontSize: 10.5, color: kTextHint)),
        ],
      ),
    );
  }

  String _employerName(AppState state, int id) {
    if (id <= 0) return '未归属雇主';
    final Employer? e = state.employerById(id);
    return e?.name ?? '已删除的雇主';
  }

  // ------------------------------------------------------------ 奖金

  Widget _extraCard(RangeSummary s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('奖金 / 额外收入',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final e in s.extraByLabel)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  _colorBar(kIncomeFg),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(e.key, style: const TextStyle(fontSize: 13))),
                  Text(displayCents(e.value), style: _amount(color: kIncomeFg)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 统一样式

  /// 金额样式：等宽数字（逐位对齐，这是"金额列对不齐"的根因），
  /// 全页金额统一走这里，字号只有 13（常规）/ 15（强调）两档。
  TextStyle _amount({Color? color, bool strong = false}) => moneyStyle(
        size: strong ? 15 : 13,
        weight: strong ? FontWeight.w600 : FontWeight.w500,
        color: color,
      );

  /// 统一的卡片标题行：左标题 14/w600，右侧可放汇总数值。
  Widget _cardTitle(String text, {Widget? trailing}) => Row(
        children: [
          Text(text,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      );

  /// 统一的小色条（项目 / 雇主卡左侧）。
  Widget _colorBar(Color color) => Container(
        width: 3,
        height: 14,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(1.5)),
      );
}

/// 月度折线图（自绘，不引入图表库）。
///
/// 只画 12 个点，不做缩放/滑动：工资条一年就 12 个月，
/// 一屏看得完，比任何可交互图表都直观。
class _MonthLinePainter extends CustomPainter {
  static const double leftPad = 46;
  static const double rightPad = 10;
  static const double topPad = 12;
  static const double bottomPad = 22;

  final List<int> values;
  final List<bool> has;
  final Color line;
  final Color grid;
  final Color label;
  final Color dotBg;

  /// 开了「金额打码」时，纵轴刻度也不显示具体数值
  final bool masked;

  _MonthLinePainter({
    required this.values,
    required this.has,
    required this.line,
    required this.grid,
    required this.label,
    required this.dotBg,
    this.masked = false,
  });

  static String _short(int cents) {
    final yuan = cents / 100;
    if (yuan.abs() >= 10000) return '${(yuan / 10000).toStringAsFixed(1)}万';
    return yuan.toStringAsFixed(0);
  }

  void _text(Canvas canvas, String s, Offset at,
      {bool center = false, bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: 9.5, color: label)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (center) dx -= tp.width / 2;
    if (right) dx -= tp.width;
    tp.paint(canvas, Offset(dx, at.dy));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - leftPad - rightPad;
    final h = size.height - topPad - bottomPad;
    if (w <= 0 || h <= 0) return;

    final maxV = values.fold<int>(0, (m, v) => v > m ? v : m);
    final maxY = maxV <= 0 ? 100 : (maxV * 1.15).round();

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;

    // 三条横线 + 左侧刻度
    for (var i = 0; i <= 2; i++) {
      final y = topPad + h * (1 - i / 2);
      canvas.drawLine(
          Offset(leftPad, y), Offset(size.width - rightPad, y), gridPaint);
      _text(canvas, masked ? '—' : _short((maxY * i) ~/ 2),
          Offset(leftPad - 6, y - 6),
          right: true);
    }

    // X 轴月份
    for (var m = 0; m < 12; m++) {
      final x = leftPad + w * (m + 0.5) / 12;
      _text(canvas, '${m + 1}', Offset(x, size.height - bottomPad + 5),
          center: true);
    }

    Offset pos(int m) {
      final ratio = maxY == 0 ? 0.0 : values[m] / maxY;
      return Offset(leftPad + w * (m + 0.5) / 12, topPad + h * (1 - ratio));
    }

    // 折线：只连相邻且有记录的月份，避免跨过空月画出假趋势
    final path = Path();
    int? prev;
    for (var m = 0; m < 12; m++) {
      if (!has[m]) {
        prev = null;
        continue;
      }
      final p = pos(m);
      if (prev == m - 1) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
      }
      prev = m;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 数据点（空心圆，压在折线上看得清）
    for (var m = 0; m < 12; m++) {
      if (!has[m]) continue;
      final p = pos(m);
      canvas.drawCircle(p, 4.5, Paint()..color = dotBg);
      canvas.drawCircle(p, 3.2, Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(covariant _MonthLinePainter old) =>
      old.values != values ||
      old.has != has ||
      old.line != line ||
      old.grid != grid ||
      old.label != label ||
      old.dotBg != dotBg ||
      old.masked != masked;
}
