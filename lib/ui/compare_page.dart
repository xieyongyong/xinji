import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../state/app_state.dart';
import '../stats/salary_stats.dart';
import 'theme.dart';

/// 两个月逐项对比：看出哪一项多了、哪一项少了
///
/// 只比「月度工资」。年终奖这类一次性收入混进月度环比会严重失真，
/// 所以奖金在年度页单独看。
class ComparePage extends StatefulWidget {
  final int year;
  final int? focusMonth;

  const ComparePage({super.key, required this.year, this.focusMonth});

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  late int _year;
  int? _monthA;
  int? _monthB;

  @override
  void initState() {
    super.initState();
    _year = widget.year;
    _monthB = widget.focusMonth;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final summary = StatsBuilder.buildYear(state.records, _year);
    final available = summary.months.where((m) => m.monthly.isNotEmpty).toList();

    if (available.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('月份对比')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.compare_arrows, size: 40, color: Color(0xFFC4C9C4)),
                const SizedBox(height: 14),
                Text(
                  available.isEmpty
                      ? '$_year 年还没有月度工资记录'
                      : '$_year 年只有一个月的数据，至少要两个月才能对比',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: Color(0xFF8A8F8A), height: 1.6),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 默认：B 取焦点月（或最后一个月），A 取它前面最近的一个月
    final bMonth = _monthB != null && available.any((m) => m.month == _monthB)
        ? _monthB!
        : available.last.month;
    int aMonth = _monthA != null && available.any((m) => m.month == _monthA) && _monthA != bMonth
        ? _monthA!
        : -1;
    if (aMonth == -1) {
      for (final m in available) {
        if (m.month < bMonth) aMonth = m.month;
      }
      if (aMonth == -1) aMonth = available.first.month == bMonth
          ? available.last.month
          : available.first.month;
      if (aMonth == bMonth && available.length > 1) {
        aMonth = available.firstWhere((m) => m.month != bMonth).month;
      }
    }

    final a = summary.months[aMonth - 1];
    final b = summary.months[bMonth - 1];
    final cmp = StatsBuilder.compare(a, b);

    return Scaffold(
      appBar: AppBar(title: Text('$_year 年 · 月份对比')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _pickerRow(available, aMonth, bMonth),
          const SizedBox(height: 14),
          _headlineCard(cmp),
          const SizedBox(height: 14),
          _totalsCompare(cmp),
          const SizedBox(height: 14),
          _diffCard(
            title: '收入项变化',
            color: kIncome,
            diffs: cmp.incomeDiffs,
            emptyHint: '两月收入项目完全相同',
          ),
          const SizedBox(height: 14),
          if (cmp.deductionDiffs.isNotEmpty)
            _diffCard(
              title: '扣款项变化',
              color: kDeduction,
              diffs: cmp.deductionDiffs,
              emptyHint: '两月扣款项目完全相同',
            ),
          const SizedBox(height: 12),
          const Text(
            '说明：红色表示这项金额变多了，绿色表示变少了。'
            '扣款项变多意味着从工资里扣得更多。',
            style: TextStyle(fontSize: 11, color: Color(0xFFB0B5B0), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _pickerRow(List<MonthSummary> available, int aMonth, int bMonth) {
    Widget dropdown(String label, int value, ValueChanged<int> onChanged) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A))),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE6E8E6)),
            ),
            child: DropdownButton<int>(
              value: value,
              underline: const SizedBox.shrink(),
              isDense: true,
              style: const TextStyle(fontSize: 14, color: Color(0xFF1B1C1B)),
              items: available
                  .map((m) => DropdownMenuItem(
                        value: m.month,
                        child: Text('${m.month}月')),
                      )
                  .toList(),
              onChanged: (v) => onChanged(v ?? value),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: dropdown('对比基准（早）', aMonth, (v) => setState(() => _monthA = v)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 16, 10, 0),
          child: Icon(Icons.arrow_forward, size: 18, color: Color(0xFFB0B5B0)),
        ),
        Expanded(
          child: dropdown('对比月份（晚）', bMonth, (v) => setState(() => _monthB = v)),
        ),
      ],
    );
  }

  Widget _headlineCard(MonthComparison c) {
    final up = c.netDiff > 0;
    final color = c.netDiff == 0
        ? const Color(0xFF6B6F6B)
        : (up ? kUp : kDown);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F5F3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE3E8E4)),
      ),
      child: Row(
        children: [
          Icon(
            c.netDiff == 0
                ? Icons.drag_handle
                : (up ? Icons.trending_up : Icons.trending_down),
            color: color,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.headline,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsCompare(MonthComparison c) {
    Widget row(String label, int a, int b, int diff) {
      final color = diff == 0
          ? const Color(0xFF8A8F8A)
          : (diff > 0 ? kUp : kDown);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Text(label,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
            ),
            Expanded(
              child: Text(
                '${formatCents(a)} → ${formatCents(b)}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF3A3F3A)),
              ),
            ),
            Text(
              diff == 0 ? '持平' : '${diff > 0 ? '+' : ''}${formatCents(diff)}',
              style: TextStyle(
                  fontSize: 13, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: cardDecoration(),
      child: Column(
        children: [
          row('应发', c.a.monthlyGross, c.b.monthlyGross, c.grossDiff),
          const Divider(height: 16),
          row('代扣', c.a.monthlyDeduction, c.b.monthlyDeduction, c.deductionDiff),
          const Divider(height: 16),
          row('实发', c.a.monthlyNet, c.b.monthlyNet, c.netDiff),
        ],
      ),
    );
  }

  Widget _diffCard({
    required String title,
    required Color color,
    required List<ItemDiff> diffs,
    required String emptyHint,
  }) {
    // 只显示有变化的项，没变化的折叠成一行说明
    final changed = diffs.where((d) => d.diff != 0 || d.isNew || d.isGone).toList();
    final unchanged = diffs.length - changed.length;

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
                height: 14,
                decoration:
                    BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${changed.length} 项变化',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A))),
            ],
          ),
          const SizedBox(height: 8),
          if (changed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(emptyHint,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFFB0B5B0))),
            ),
          for (final d in changed) _diffRow(d),
          if (unchanged > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('另有 $unchanged 项没有变化',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFB0B5B0))),
            ),
        ],
      ),
    );
  }

  Widget _diffRow(ItemDiff d) {
    final color = d.diff == 0
        ? const Color(0xFF8A8F8A)
        : (d.diff > 0 ? kUp : kDown);

    String amountText;
    if (d.isNew) {
      amountText = '新增 ${formatCents(d.bCents)}';
    } else if (d.isGone) {
      amountText = '本月无此项';
    } else {
      amountText = '${d.diff > 0 ? '+' : ''}${formatCents(d.diff)}';
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.isNotable ? 7 : 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF1B1C1B),
                    fontWeight: d.isNotable ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (!d.isNew && !d.isGone)
                  Text(
                    '${formatCents(d.aCents)} → ${formatCents(d.bCents)}'
                    '${d.changeRate != null ? '  ${(d.changeRate! * 100).toStringAsFixed(1)}%' : ''}',
                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF9AA09A)),
                  )
                else
                  Text(
                    d.isNew ? '上月没有这项' : '这月没有这项',
                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF9AA09A)),
                  ),
              ],
            ),
          ),
          Text(
            amountText,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
