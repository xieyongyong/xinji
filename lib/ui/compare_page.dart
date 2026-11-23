import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../core/money.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../stats/salary_stats.dart';
import 'theme.dart';

/// 两期逐项对比：看出哪一项多了、哪一项少了。
///
/// 两个关键点：
/// 1. **可以跨年**（2025-12 ↔ 2026-01）—— 只按"年"取数据时，跨年对比根本选不出来；
/// 2. 除了钱，还比**绩效系数**和**信息项**（部门、应出勤天数…）——
///    "绩效工资少了 800" 往往答案在系数上，只有金额对比看不出来。
///
/// 两种对比模式：
/// - 「月度工资」：逐项环比（收入/扣款/系数/信息项），奖金不掺进来以免失真；
/// - 「奖金」：两笔额外收入对比（按记录选，因为奖金不定期、同月可多笔）。
class ComparePage extends StatefulWidget {
  /// 进来时优先看哪一年（可空：空则取最近两期）
  final int? year;

  /// 进来时 B 侧优先看这个月（从统计页点柱子进来时用）
  final int? focusMonth;

  /// 进来时默认模式：extra = 奖金对比
  final bool initialExtra;

  const ComparePage({
    super.key,
    this.year,
    this.focusMonth,
    this.initialExtra = false,
  });

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  /// false = 月度工资对比，true = 奖金对比
  late bool _extraMode = widget.initialExtra;

  /// 期间键：year * 100 + month（月度模式）
  int? _keyA;
  int? _keyB;

  /// 奖金记录 id（奖金模式）
  int? _extraIdA;
  int? _extraIdB;

  /// 哪些卡片展开了"无变化项目"
  final Set<String> _expandedGroups = {};

  AppSettings get _settings => context.watch<AppSettings>();

  static int _keyOf(MonthSummary m) => m.year * 100 + m.month;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final employerName = state.currentEmployer?.name;

    // 奖金模式：两笔额外收入对比
    if (_extraMode) return _buildExtraCompare(state, employerName);

    // 只看当前雇主，且只看有月度工资的期
    final periods = StatsBuilder.buildPeriods(state.scopedRecords)
        .where((m) => m.monthly.isNotEmpty)
        .toList();

    if (periods.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('月份对比')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.compare_arrows, size: 40, color: kTextFaint),
                const SizedBox(height: 14),
                Text(
                  periods.isEmpty
                      ? '还没有月度工资记录'
                      : '只有一个月的数据，至少要两个月才能对比',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13.5, color: kTextSecondary, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final keys = periods.map(_keyOf).toList();
    final bKey = _keyB != null && keys.contains(_keyB) ? _keyB! : _defaultB(periods);
    final aKey =
        _keyA != null && keys.contains(_keyA) && _keyA != bKey ? _keyA! : _defaultA(keys, bKey);

    final a = periods.firstWhere((m) => _keyOf(m) == aKey);
    final b = periods.firstWhere((m) => _keyOf(m) == bKey);
    final cmp = StatsBuilder.compare(a, b);

    return Scaffold(
      appBar: AppBar(
        title: _modeSwitch(),
        bottom: employerName == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('$employerName · 可跨年选择',
                      style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
                ),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _pickerRow(periods, aKey, bKey),
          const SizedBox(height: 14),
          _headlineCard(cmp),
          const SizedBox(height: 14),
          _totalsCompare(cmp),
          const SizedBox(height: 14),
          _diffCard(
            title: '收入项变化',
            color: kIncomeFg,
            diffs: cmp.incomeDiffs,
            emptyHint: '两期收入项目完全相同',
          ),
          const SizedBox(height: 14),
          if (cmp.deductionDiffs.isNotEmpty)
            _diffCard(
              title: '扣款项变化',
              color: kDeductionFg,
              diffs: cmp.deductionDiffs,
              emptyHint: '两期扣款项目完全相同',
            ),
          const SizedBox(height: 14),
          if (cmp.coefDiffs.isNotEmpty || cmp.derivedDiffs.isNotEmpty)
            _metricCard(cmp),
          const SizedBox(height: 14),
          if (cmp.infoDiffs.isNotEmpty) _infoCard(cmp.infoDiffs),
          const SizedBox(height: 12),
          Text(
            '说明：金额变多与变少用不同颜色区分（红涨绿跌，可在设置里改配色）。'
            '扣款项变多意味着从工资里扣得更多。系数与信息项只做参考，不计入合计。',
            style: TextStyle(fontSize: 11, color: kTextHint, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 默认 B：优先焦点月（且优先 widget.year 那年），否则最近一期
  int _defaultB(List<MonthSummary> periods) {
    final focus = widget.focusMonth;
    final year = widget.year;
    for (final m in periods.reversed) {
      if (year != null && m.year != year) continue;
      if (focus != null && m.month != focus) continue;
      return _keyOf(m);
    }
    return _keyOf(periods.last);
  }

  /// 默认 A：B 的前一期；B 已经是第一期就取最后一期
  int _defaultA(List<int> keys, int bKey) {
    final i = keys.indexOf(bKey);
    if (i > 0) return keys[i - 1];
    return keys.last;
  }

  Widget _pickerRow(List<MonthSummary> periods, int aKey, int bKey) {
    return Row(
      children: [
        Expanded(
          child: _periodField('对比基准（早）', aKey, bKey, periods,
              (v) => setState(() => _keyA = v)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
          child: Icon(Icons.arrow_forward, size: 18, color: kTextHint),
        ),
        Expanded(
          child: _periodField('对比月份（晚）', bKey, aKey, periods,
              (v) => setState(() => _keyB = v)),
        ),
      ],
    );
  }

  Widget _periodField(
    String label,
    int value,
    int otherKey,
    List<MonthSummary> periods,
    ValueChanged<int> onPicked,
  ) {
    final m = periods.firstWhere((e) => _keyOf(e) == value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
        const SizedBox(height: 4),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            final picked = await _pickPeriod(periods,
                exclude: otherKey, initial: value, selected: {value, otherKey});
            if (picked != null) onPicked(picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDivider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${m.year}年${m.month}月',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: kTextPrimary),
                  ),
                ),
                Icon(Icons.expand_more, size: 18, color: kTextHint),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 选月份：年份一行 + 12 个月格子。
  ///
  /// 为什么不用下拉：月份一多（三年就 36 项）下拉列表要滚很久，
  /// 而且"哪个月有记录"完全看不出来，只能盲选。格子铺开后一眼看全，
  /// 没记录的月份直接置灰点不动。
  Future<int?> _pickPeriod(
    List<MonthSummary> periods, {
    required int exclude,
    required int initial,
    required Set<int> selected,
  }) {
    final byKey = {for (final m in periods) _keyOf(m): m};
    final years = periods.map((e) => e.year).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    var year = initial ~/ 100;
    if (!years.contains(year)) year = years.first;

    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: kSurface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('选择月份',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                if (years.length > 1)
                  SizedBox(
                    height: 34,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: years.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final y = years[i];
                        final selected = y == year;
                        return GestureDetector(
                          onTap: () => setSheet(() => year = y),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected ? kSeed : kSurfaceAlt,
                              borderRadius: BorderRadius.circular(17),
                            ),
                            child: Text(
                              '$y 年',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: selected ? Colors.white : kTextMedium,
                                fontWeight:
                                    selected ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (years.length > 1) const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.5,
                  children: [
                    for (var m = 1; m <= 12; m++)
                      _monthCell(
                        ctx,
                        year: year,
                        month: m,
                        summary: byKey[year * 100 + m],
                        isOtherSide: year * 100 + m == exclude,
                        selected: selected.contains(year * 100 + m),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _monthCell(
    BuildContext sheetCtx, {
    required int year,
    required int month,
    required MonthSummary? summary,
    required bool isOtherSide,
    required bool selected,
  }) {
    final key = year * 100 + month;
    // 没记录的月份、以及另一侧已经选中的月份都不让点（两边同一期没有意义）
    final enabled = summary != null && !isOtherSide;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? () => Navigator.pop(sheetCtx, key) : null,
      child: Container(
        decoration: BoxDecoration(
          color: enabled ? (selected ? kInfoBg : kSurfaceAlt) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected && enabled ? kSeed : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$month 月',
              style: TextStyle(
                fontSize: 13,
                fontWeight: enabled ? FontWeight.w600 : FontWeight.normal,
                color: enabled ? kTextPrimary : kTextFaint,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              summary == null
                  ? '—'
                  : (isOtherSide ? '已选' : displayCents(summary.monthlyNet)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: enabled ? kTextHint : kTextFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headlineCard(MonthComparison c) {
    final up = c.netDiff > 0;
    final color = _settings.diffColor(c.netDiff);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSurfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
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
              style: TextStyle(
                  fontSize: 13.5, height: 1.6, color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsCompare(MonthComparison c) {
    Widget row(String label, int a, int b, int diff) {
      final color = _settings.diffColor(diff);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child:
                  Text(label, style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
            ),
            Expanded(
              child: Text(
                '${displayCents(a)} → ${displayCents(b)}',
                style: TextStyle(fontSize: 13, color: kTextBody),
              ),
            ),
            Text(
              diff == 0 ? '持平' : displayCents(diff, withSign: true),
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
    // 有变化的默认展开；无变化的默认收起，点一下才看得到具体哪几项没动
    final changed = diffs.where((d) => d.diff != 0 || d.isNew || d.isGone).toList();
    final unchanged = diffs.where((d) => !(d.diff != 0 || d.isNew || d.isGone)).toList();
    final expanded = _expandedGroups.contains(title);

    return _cardShell(
      title: title,
      color: color,
      trailing: '${changed.length} 项变化',
      children: [
        if (changed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(emptyHint, style: TextStyle(fontSize: 12.5, color: kTextHint)),
          ),
        for (final d in changed) _diffRow(d),
        if (unchanged.isNotEmpty) ...[
          const SizedBox(height: 4),
          _expandToggle(
            title: title,
            expanded: expanded,
            count: unchanged.length,
          ),
          if (expanded)
            for (final d in unchanged)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: _diffRow(d),
              ),
        ],
      ],
    );
  }

  Widget _expandToggle({
    required String title,
    required bool expanded,
    required int count,
  }) {
    return InkWell(
      onTap: () => setState(() {
        if (expanded) {
          _expandedGroups.remove(title);
        } else {
          _expandedGroups.add(title);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(
              expanded ? '收起无变化项目' : '查看 $count 项无变化项目',
              style: TextStyle(fontSize: 11.8, color: kSeed),
            ),
            Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 15, color: kSeed),
          ],
        ),
      ),
    );
  }

  Widget _cardShell({
    required String title,
    required Color color,
    required String trailing,
    required List<Widget> children,
  }) {
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
              Text(trailing,
                  style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _diffRow(ItemDiff d) {
    final color = _settings.diffColor(d.diff);

    final flat = d.diff == 0;
    // 新增 / 消失也要给真实金额："本月无此项"看不出到底差了多少
    final amountText = flat ? '持平' : displayCents(d.diff, withSign: true);

    String subtitle;
    if (d.isNew) {
      subtitle = '上月没有这项';
    } else if (d.isGone) {
      subtitle = '本月没有 · 上月 ${displayCents(d.aCents)}';
    } else {
      subtitle = '${displayCents(d.aCents)} → ${displayCents(d.bCents)}'
          '${d.changeRate != null ? '  ${(d.changeRate! * 100).toStringAsFixed(1)}%' : ''}';
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
                    color: kTextPrimary,
                    fontWeight: d.isNotable ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 10.5, color: kTextHint),
                ),
              ],
            ),
          ),
          Text(
            amountText,
            style: TextStyle(
              fontSize: 13,
              color: flat ? kTextHint : color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 绩效与系数：系数型 + 推算值
  Widget _metricCard(MonthComparison c) {
    final changedCoef = c.coefDiffs.where((d) => d.changed).toList();
    final unchangedCoef = c.coefDiffs.where((d) => !d.changed).toList();
    final changedDerived = c.derivedDiffs.where((d) => d.diff != 0).toList();
    final unchangedDerived = c.derivedDiffs.where((d) => d.diff == 0).toList();
    final expanded = _expandedGroups.contains('绩效与系数');
    final totalChanged = changedCoef.length + changedDerived.length;

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
                decoration: BoxDecoration(
                    color: kSeed, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              const Text('绩效与系数',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$totalChanged 项变化',
                  style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '系数不是钱，但它决定了绩效工资按几倍发',
            style: TextStyle(fontSize: 11, color: kTextHint),
          ),
          const SizedBox(height: 8),
          if (changedCoef.isEmpty && changedDerived.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('两期系数与基数完全相同',
                  style: TextStyle(fontSize: 12.5, color: kTextHint)),
            ),
          for (final d in changedCoef) _coefRow(d),
          for (final d in changedDerived) _diffRow(d),
          if (unchangedCoef.isNotEmpty || unchangedDerived.isNotEmpty) ...[
            const SizedBox(height: 4),
            _expandToggle(
              title: '绩效与系数',
              expanded: expanded,
              count: unchangedCoef.length + unchangedDerived.length,
            ),
            if (expanded) ...[
              for (final d in unchangedCoef) _coefRow(d),
              for (final d in unchangedDerived) _diffRow(d),
            ],
          ],
        ],
      ),
    );
  }

  Widget _coefRow(CoefDiff d) {
    final Color color;
    if (!d.changed) {
      color = kTextHint;
    } else if (d.diff >= 0) {
      color = kSeed;
    } else {
      color = kDeductionFg;
    }

    String right;
    if (!d.changed) {
      right = '持平';
    } else if (d.isNew) {
      right = '新增 ${d.b!.toStringAsFixed(2)}';
    } else if (d.isGone) {
      right = '本月无 · 上月 ${d.a!.toStringAsFixed(2)}';
    } else {
      right = '${d.diff > 0 ? '+' : ''}${d.diff.toStringAsFixed(2)}';
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.changed ? 7 : 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: kTextPrimary,
                    fontWeight: d.changed ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                Text(
                  '${d.a?.toStringAsFixed(2) ?? '—'} → ${d.b?.toStringAsFixed(2) ?? '—'}',
                  style: TextStyle(fontSize: 10.5, color: kTextHint),
                ),
              ],
            ),
          ),
          Text(
            right,
            style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// 信息项：部门、薪级、应出勤天数这些只记录不前合计的内容
  Widget _infoCard(List<InfoDiff> diffs) {
    final changed = diffs.where((d) => d.changed).toList();
    final unchanged = diffs.where((d) => !d.changed).toList();
    final expanded = _expandedGroups.contains('信息项变化');

    return _cardShell(
      title: '信息项变化',
      color: kTextMedium,
      trailing: '${changed.length} 项变化',
      children: [
        if (changed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('两期信息项完全相同',
                style: TextStyle(fontSize: 12.5, color: kTextHint)),
          ),
        for (final d in changed) _infoRow(d),
        if (unchanged.isNotEmpty) ...[
          const SizedBox(height: 4),
          _expandToggle(
            title: '信息项变化',
            expanded: expanded,
            count: unchanged.length,
          ),
          if (expanded)
            for (final d in unchanged) _infoRow(d),
        ],
      ],
    );
  }

  Widget _infoRow(InfoDiff d) {
    final a = d.inA ? d.aValue : '—';
    final b = d.inB ? d.bValue : '—';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.changed ? 7 : 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              d.name,
              style: TextStyle(
                fontSize: 12.5,
                color: kTextPrimary,
                fontWeight: d.changed ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '$a → $b',
              style: TextStyle(
                fontSize: 12.5,
                color: d.changed ? kTextBody : kTextHint,
                height: 1.4,
              ),
            ),
          ),
          if (d.changed)
            Text('已变化',
                style: TextStyle(fontSize: 10.5, color: kSeed)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 模式切换

  Widget _modeSwitch() {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(value: false, label: Text('月度工资')),
        ButtonSegment(value: true, label: Text('奖金')),
      ],
      selected: {_extraMode},
      onSelectionChanged: (s) => setState(() => _extraMode = s.first),
    );
  }

  // ------------------------------------------------------------ 奖金对比

  Widget _buildExtraCompare(AppState state, String? employerName) {
    // 奖金 = 额外收入记录。按月/名目排列，供两笔互相比。
    final extras = state.scopedRecords
        .where((r) => r.recordType == kTypeExtra)
        .toList()
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    final ids = extras.map((r) => r.id).whereType<int>().toList();

    Widget empty(String msg) => Scaffold(
          appBar: AppBar(title: _modeSwitch(), bottom: employerName == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(20),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('$employerName · 两笔奖金逐项对比',
                        style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
                  ),
                )),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.card_giftcard_outlined, size: 40, color: kTextFaint),
                  const SizedBox(height: 14),
                  Text(msg,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5, color: kTextSecondary, height: 1.6)),
                ],
              ),
            ),
          ),
        );

    if (extras.length < 2) {
      return empty(extras.isEmpty
          ? '还没有奖金 / 额外收入记录'
          : '只有一笔奖金，至少要两笔才能对比');
    }

    // 默认 B 取最新一笔，A 取次新；无效 id（如新记录还没存库）回退到默认
    final bId = _extraIdB != null && ids.contains(_extraIdB)
        ? _extraIdB!
        : ids.first;
    final aId = _extraIdA != null && ids.contains(_extraIdA) && _extraIdA != bId
        ? _extraIdA!
        : (ids.length > 1 ? ids[1] : ids.first);

    final a = extras.firstWhere((r) => r.id == aId);
    final b = extras.firstWhere((r) => r.id == bId);
    final diff = b.netCents - a.netCents;
    final color = _settings.diffColor(diff);

    return Scaffold(
      appBar: AppBar(
        title: _modeSwitch(),
        bottom: employerName == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('$employerName · 两笔奖金逐项对比',
                      style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
                ),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Row(
            children: [
              Expanded(
                  child: _extraField('对比基准（早）', a, extras, bId,
                      (v) => setState(() => _extraIdA = v))),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
                child: Icon(Icons.arrow_forward, size: 18, color: kTextHint),
              ),
              Expanded(
                  child: _extraField('对比奖金（晚）', b, extras, aId,
                      (v) => setState(() => _extraIdB = v))),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kSeed,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(diff == 0 ? '两笔实发持平' : (diff > 0 ? '后一笔多拿' : '后一笔少拿'),
                    style: TextStyle(
                        fontSize: 12, color: Colors.white.withOpacity(0.85))),
                const SizedBox(height: 6),
                Text(displayCents(diff, withSign: true),
                    style: moneyStyle(size: 28, color: Colors.white)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _cardShell(
            title: '金额变化',
            color: color,
            trailing: '实发差额',
            children: [
              _extraRow('应发', a.grossCents, b.grossCents),
              const Divider(height: 16),
              _extraRow('代扣', a.deductionCents, b.deductionCents),
              const Divider(height: 16),
              _extraRow('实发', a.netCents, b.netCents),
            ],
          ),
          const SizedBox(height: 14),
          _cardShell(
            title: '基本信息',
            color: kSeed,
            trailing: '两笔对比',
            children: [
              _extraInfoRow('名目', a.displayTitle, b.displayTitle),
              _extraInfoRow('期间', '${a.periodYear}-${a.periodMonth}',
                  '${b.periodYear}-${b.periodMonth}'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '奖金不定期发放、同月可能多笔，因此按记录对比而非按月份。'
            '金额变多/变少用不同颜色区分（红涨绿跌，可在设置里改配色）。',
            style: TextStyle(fontSize: 11, color: kTextHint, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _extraField(String label, PayRecord current, List<PayRecord> extras,
      int otherId, ValueChanged<int> onPicked) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
        const SizedBox(height: 4),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            final picked = await showModalBottomSheet<int>(
              context: context,
              showDragHandle: true,
              backgroundColor: kSurface,
              builder: (ctx) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in extras)
                      if (r.id != null && r.id != otherId)
                        ListTile(
                          title: Text(r.displayTitle,
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(displayCents(r.netCents),
                              style: TextStyle(fontSize: 11.5, color: kTextHint)),
                          onTap: () => Navigator.pop(ctx, r.id),
                        ),
                  ],
                ),
              ),
            );
            if (picked != null) onPicked(picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDivider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    current.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: kTextPrimary),
                  ),
                ),
                Icon(Icons.expand_more, size: 18, color: kTextHint),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _extraRow(String label, int a, int b) {
    final diff = b - a;
    final color = _settings.diffColor(diff);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(label,
                style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
          ),
          Expanded(
            child: Text('${displayCents(a)} → ${displayCents(b)}',
                style: TextStyle(fontSize: 13, color: kTextBody)),
          ),
          Text(diff == 0 ? '持平' : displayCents(diff, withSign: true),
              style: TextStyle(
                  fontSize: 13, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _extraInfoRow(String label, String a, String b) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(label,
                style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
          ),
          Expanded(
            child: Text(a,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: kTextBody)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(b,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: kTextBody)),
          ),
        ],
      ),
    );
  }
}
