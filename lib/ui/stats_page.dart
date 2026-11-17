import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../data/employer.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../stats/range_stats.dart';
import 'compare_page.dart';
import 'theme.dart';

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

    // 「雇主」维度要看全部雇主的记录，不能只用当前雇主那一份
    final crossEmployer = _year == null
        ? state.records
        : state.records.where((r) => r.periodYear == _year).toList();

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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _scopeBar(years),
          const SizedBox(height: 10),
          _overview(sum, state),
          const SizedBox(height: 14),
          _dimensionSwitch(),
          const SizedBox(height: 12),
          ..._content(state, sum, crossEmployer),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 范围选择

  Widget _scopeBar(List<int> years) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _scopeChip('全部', _year == null, () => setState(() => _year = null)),
          for (final y in years)
            _scopeChip('$y 年', _year == y, () => setState(() => _year = y)),
        ],
      ),
    );
  }

  Widget _scopeChip(String text, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? kSeed : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? kSeed : kDivider,
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : kTextMedium,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 总览

  Widget _overview(RangeSummary s, AppState state) {
    final title = _year == null ? '全部年份总计' : '$_year 年';
    final sub = s.isEmpty
        ? '这个范围还没有记录'
        : (s.periodLabel.isEmpty ? '' : '覆盖 ${s.periodLabel} · ${s.recordCount} 笔');

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kSeed,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 12, color: Colors.white.withOpacity(0.85))),
              const Spacer(),
              if (sub.isNotEmpty)
                Text(sub,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.white.withOpacity(0.7))),
            ],
          ),
          const SizedBox(height: 6),
          Text(formatCents(s.totalNet),
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
                Text('应发 ${formatCents(s.totalGross)}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.8))),
                const Spacer(),
                Text('代扣 ${formatCents(s.totalDeduction)}',
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
        Text(formatCents(value),
            style: const TextStyle(
                fontSize: 13.5,
                color: Colors.white,
                fontWeight: FontWeight.w600)),
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
      AppState state, RangeSummary sum, List<PayRecord> crossEmployer) {
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
        return [_employerCard(state, crossEmployer)];
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
                Text('总计 ${formatCents(s.totalNet)}',
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
                            formatCents(y.net),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 52, top: 3),
                      child: Text(
                        '${y.months} 个月 · 月均 ${formatCents(y.avgNet)}'
                        '${y.extraNet > 0 ? ' · 含奖金 ${formatCents(y.extraNet)}' : ''}',
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

  Widget _monthCard(RangeSummary s) {
    final months = s.byMonthOfYear;
    final maxNet = months.fold<int>(0, (m, e) => e.net > m ? e.net : m);
    final hasData = maxNet > 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_year == null ? '各月累计（跨年合并）' : '$_year 年 · 月度实发',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            hasData
                ? (_year == null
                    ? '把每年的同一个月份加在一起，看长期规律'
                    : '最高的一个月 ${formatCents(maxNet)}')
                : '还没有数据',
            style: TextStyle(fontSize: 11.5, color: kTextSecondary),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final m in months)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: m.isEmpty
                          ? null
                          : () => _openMonth(m),
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
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4)),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${m.month}',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: m.isEmpty
                                  ? kTextFaint
                                  : kTextMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 22),
          for (final m in months)
            if (!m.isEmpty && (_year == null ? m.times > 1 : true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text('${m.month} 月',
                          style: TextStyle(
                              fontSize: 12, color: kTextMedium)),
                    ),
                    if (_year == null)
                      Text('${m.times} 年',
                          style: TextStyle(
                              fontSize: 11, color: kTextHint)),
                    const Spacer(),
                    Text(
                      _year == null
                          ? '合计 ${formatCents(m.net)} · 平均 ${formatCents(m.avgNet)}'
                          : formatCents(m.net),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
          if (_year != null)
            Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('点柱子可打开该月明细对比',
                  style: TextStyle(fontSize: 10.5, color: kTextHint)),
            ),
        ],
      ),
    );
  }

  void _openMonth(MonthAgg m) {
    final y = _year;
    if (y == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ComparePage(year: y, focusMonth: m.month)),
    );
  }

  // ------------------------------------------------------------ 项目

  Widget _itemCard(RangeSummary s, String category) {
    final isIncome = category == kCategoryIncome;
    final list = isIncome ? s.incomeByItem : s.deductionByItem;
    final total = list.fold<int>(0, (a, e) => a + e.value);
    final color = isIncome ? kIncome : kDeduction;
    final shown = _showAllItems ? list : list.take(10).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 13,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              Text(isIncome ? '钱从哪来' : '钱扣在哪',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(formatCents(total),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: color)),
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
                    child: Text(formatCents(e.value),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w500)),
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

  Widget _employerCard(AppState state, List<PayRecord> crossEmployer) {
    final sum = RangeSummary(crossEmployer);
    final rows = sum.netByEmployer;
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
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
              Text(formatCents(total),
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
                        Container(
                          width: 3,
                          height: 13,
                          decoration: BoxDecoration(
                            color: row.key == state.currentEmployerId
                                ? kSeed
                                : kBorder,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
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
                        Text(formatCents(row.value),
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w500)),
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
                  Container(
                    width: 3,
                    height: 13,
                    decoration: BoxDecoration(
                      color: kDeductionFg,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(e.key, style: const TextStyle(fontSize: 13))),
                  Text(formatCents(e.value),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: kDeductionFg)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
