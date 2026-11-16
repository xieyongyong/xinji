import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../data/employer.dart';
import '../state/app_state.dart';
import '../stats/salary_stats.dart';
import 'compare_page.dart';
import 'theme.dart';

/// 年度总览：工资 / 奖金 / 总收入三个口径 + 月度趋势 + 项目年度榜
class YearlyPage extends StatefulWidget {
  final int year;

  const YearlyPage({super.key, required this.year});

  @override
  State<YearlyPage> createState() => _YearlyPageState();
}

class _YearlyPageState extends State<YearlyPage> {
  late int _year;
  bool _showAllItems = false;

  @override
  void initState() {
    super.initState();
    _year = widget.year;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final years = state.years;
    final summary = StatsBuilder.buildYear(state.scopedRecords, _year);

    return Scaffold(
      appBar: AppBar(
        title: const Text('年度总览'),
        actions: [
          IconButton(
            icon: const Icon(Icons.compare_arrows),
            tooltip: '月份对比',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ComparePage(year: _year)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          // 年份切换
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _year--),
              ),
              Text('$_year 年',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _year < DateTime.now().year
                    ? () => setState(() => _year++)
                    : null,
              ),
              const Spacer(),
              if (years.length > 1)
                PopupMenuButton<int>(
                  icon: const Icon(Icons.unfold_more, size: 20),
                  onSelected: (y) => setState(() => _year = y),
                  itemBuilder: (_) => years
                      .map((y) => PopupMenuItem(value: y, child: Text('$y 年')))
                      .toList(),
                ),
            ],
          ),
          const SizedBox(height: 6),
          _totalCard(summary),
          const SizedBox(height: 14),
          _chartCard(summary),
          const SizedBox(height: 14),
          _metricsCard(summary),
          const SizedBox(height: 14),
          _itemRankCard(summary),
          if (summary.extraByLabel.isNotEmpty) ...[
            const SizedBox(height: 14),
            _extraCard(summary),
          ],
          if (state.employers.length > 1) ...[
            const SizedBox(height: 14),
            _employerBreakdown(state),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 卡片

  /// 分雇主合计。
  ///
  /// 为什么要单独一块：跳槽那年"全年总收入"到底是多少，
  /// 只有在跨雇主的口径下才看得出来；但各家的项目结构不同，
  /// 所以这里只汇总金额，不做明细对比。
  Widget _employerBreakdown(AppState state) {
    final rows = <MapEntry<Employer, int>>[];
    for (final e in state.employers) {
      final list = state.records
          .where((r) => r.employerId == e.id && r.periodYear == _year)
          .toList();
      if (list.isEmpty) continue;
      rows.add(MapEntry(e, list.fold(0, (s, r) => s + r.netCents)));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final total = rows.fold(0, (s, r) => s + r.value);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('$_year 年 · 分雇主合计',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(formatCents(total),
                  style: moneyStyle(size: 14, color: const Color(0xFF3A3F3A))),
            ],
          ),
          const SizedBox(height: 8),
          for (final row in rows)
            InkWell(
              onTap: () => state.switchEmployer(row.key.id!),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 13,
                      decoration: BoxDecoration(
                        color: row.key.id == state.currentEmployerId
                            ? kSeed
                            : const Color(0xFFD6DAD6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        row.key.name +
                            (row.key.id == state.currentEmployerId ? '（当前）' : ''),
                        style: const TextStyle(fontSize: 13, color: Color(0xFF3A3F3A)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(formatCents(row.value),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Text('点击可切换过去查看该雇主的明细',
              style: TextStyle(fontSize: 10.5, color: Color(0xFFB0B5B0))),
        ],
      ),
    );
  }

  Widget _totalCard(YearSummary s) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kSeed,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('全年总收入',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.8))),
          const SizedBox(height: 6),
          Text(formatCents(s.totalNet), style: moneyStyle(size: 30, color: Colors.white)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _totalBlock('工资收入', s.totalMonthlyNet),
              ),
              Container(width: 1, height: 32, color: Colors.white.withOpacity(0.18)),
              Expanded(child: _totalBlock('奖金 / 额外', s.totalExtraNet)),
              Container(width: 1, height: 32, color: Colors.white.withOpacity(0.18)),
              Expanded(child: _totalBlock('已录月份', s.recordedMonths, unit: '个月', isMoney: false)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totalBlock(String label, int value, {String unit = '', bool isMoney = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10.5, color: Colors.white.withOpacity(0.7))),
        const SizedBox(height: 3),
        Text(
          isMoney ? formatCents(value) : '$value$unit',
          style: const TextStyle(
            fontSize: 13.5,
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// 手写柱状图：只画月度工资，奖金单独列，避免柱子被年终奖拉爆失真
  Widget _chartCard(YearSummary s) {
    final maxNet = s.months.fold<int>(0, (m, e) => e.monthlyNet > m ? e.monthlyNet : m);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('月度实发趋势',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            maxNet == 0 ? '还没有数据' : '最高的一个月 ${formatCents(maxNet)}',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A)),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 132,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final m in s.months)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: m.monthly.isEmpty
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => ComparePage(
                                  year: _year,
                                  focusMonth: m.month,
                                ),
                              )),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (m.monthly.isNotEmpty && m.monthlyNet == maxNet)
                            const Text('高',
                                style: TextStyle(fontSize: 9, color: kUp)),
                          Container(
                            height: maxNet == 0
                                ? 2
                                : (m.monthlyNet == 0
                                    ? 2
                                    : (m.monthlyNet / maxNet) * 92 + 2),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: m.monthly.isEmpty
                                  ? const Color(0xFFEDEFED)
                                  : kSeed,
                              borderRadius:
                                  const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${m.month}',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: m.monthly.isEmpty
                                  ? const Color(0xFFC4C9C4)
                                  : const Color(0xFF6B6F6B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricsCard(YearSummary s) {
    final maxM = s.maxMonth;
    final minM = s.minMonth;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(),
      child: Column(
        children: [
          _metricRow('月均实发', formatCents(s.avgMonthlyNet)),
          const SizedBox(height: 10),
          _metricRow(
            '最高月',
            maxM == null ? '—' : '${maxM.month}月 · ${formatCents(maxM.monthlyNet)}',
          ),
          const SizedBox(height: 10),
          _metricRow(
            '最低月',
            minM == null ? '—' : '${minM.month}月 · ${formatCents(minM.monthlyNet)}',
          ),
          const SizedBox(height: 10),
          _metricRow('年度应发 / 代扣',
              '${formatCents(s.totalMonthlyGross)} / ${formatCents(s.totalMonthlyDeduction)}'),
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value) => Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1B1C1B))),
        ],
      );

  Widget _itemRankCard(YearSummary s) {
    final all = s.itemTotals;
    final shown = _showAllItems ? all : all.take(8).toList();
    if (all.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('项目年度累计',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          const Text('这一年每个项目一共拿了 / 扣了多少',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A))),
          const SizedBox(height: 10),
          for (final entry in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(entry.key,
                        style: const TextStyle(fontSize: 13, color: Color(0xFF3A3F3A))),
                  ),
                  Text(formatCents(entry.value),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          if (all.length > 8)
            TextButton(
              onPressed: () => setState(() => _showAllItems = !_showAllItems),
              child: Text(_showAllItems ? '收起' : '展开全部 ${all.length} 项'),
            ),
        ],
      ),
    );
  }

  Widget _extraCard(YearSummary s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('奖金 / 额外收入',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (final e in s.extraByLabel)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 13,
                    decoration: BoxDecoration(
                      color: const Color(0xFFB45309),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(e.key, style: const TextStyle(fontSize: 13)),
                  ),
                  Text(formatCents(e.value),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFB45309))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
