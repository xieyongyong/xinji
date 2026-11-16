import '../data/models.dart';

/// 一个月的聚合。
///
/// 同一个月可能有多笔（正常发放 + 补发 + 绩效二次发放），
/// 这里把该月所有「月度工资」记录合成一个视图，奖金单独一栏，
/// 避免把年终奖混进月度趋势里让图表失真。
class MonthSummary {
  final int year;
  final int month;
  final List<PayRecord> monthly;
  final List<PayRecord> extras;

  MonthSummary({
    required this.year,
    required this.month,
    this.monthly = const [],
    this.extras = const [],
  });

  bool get isEmpty => monthly.isEmpty && extras.isEmpty;
  bool get hasMultiple => monthly.length > 1;

  int get monthlyGross => monthly.fold(0, (s, r) => s + r.grossCents);
  int get monthlyDeduction => monthly.fold(0, (s, r) => s + r.deductionCents);
  int get monthlyNet => monthly.fold(0, (s, r) => s + r.netCents);
  int get extraNet => extras.fold(0, (s, r) => s + r.netCents);
  int get totalNet => monthlyNet + extraNet;

  /// 该月收入明细（按项目名累加，同名多笔合并）
  Map<String, int> get incomeItems => _itemMap(kCategoryIncome);

  /// 该月扣款明细
  Map<String, int> get deductionItems => _itemMap(kCategoryDeduction);

  Map<String, int> _itemMap(String category) {
    final map = <String, int>{};
    for (final r in monthly) {
      for (final it in r.items) {
        if (it.category != category) continue;
        if (!it.countsInTotal) continue; // 系数、推算值都不是钱
        map[it.name] = (map[it.name] ?? 0) + it.amountCents;
      }
    }
    return map;
  }
}

/// 一年的汇总
class YearSummary {
  final int year;

  /// 长度固定 12，下标 0 = 1 月
  final List<MonthSummary> months;

  YearSummary({required this.year, required this.months});

  int get totalMonthlyNet => months.fold(0, (s, m) => s + m.monthlyNet);
  int get totalMonthlyGross => months.fold(0, (s, m) => s + m.monthlyGross);
  int get totalMonthlyDeduction => months.fold(0, (s, m) => s + m.monthlyDeduction);
  int get totalExtraNet => months.fold(0, (s, m) => s + m.extraNet);
  int get totalNet => totalMonthlyNet + totalExtraNet;

  /// 有记录的月份数（用于算月均，未录入的月份不拉低平均值）
  int get recordedMonths => months.where((m) => !m.isEmpty).length;

  int get avgMonthlyNet =>
      recordedMonths == 0 ? 0 : (totalMonthlyNet / recordedMonths).round();

  MonthSummary? get maxMonth {
    MonthSummary? best;
    for (final m in months) {
      if (m.monthly.isEmpty) continue;
      if (best == null || m.monthlyNet > best.monthlyNet) best = m;
    }
    return best;
  }

  MonthSummary? get minMonth {
    MonthSummary? worst;
    for (final m in months) {
      if (m.monthly.isEmpty) continue;
      if (worst == null || m.monthlyNet < worst.monthlyNet) worst = m;
    }
    return worst;
  }

  /// 项目年度累计：这一年每个项目一共拿了多少 / 扣了多少
  List<MapEntry<String, int>> get itemTotals {
    final map = <String, int>{};
    for (final m in months) {
      m.incomeItems.forEach((k, v) => map[k] = (map[k] ?? 0) + v);
      m.deductionItems.forEach((k, v) => map[k] = (map[k] ?? 0) + v);
    }
    final list = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// 奖金按名目汇总（年终奖、项目奖金……）
  List<MapEntry<String, int>> get extraByLabel {
    final map = <String, int>{};
    for (final m in months) {
      for (final r in m.extras) {
        final label = (r.recordLabel ?? '其他收入').trim();
        map[label] = (map[label] ?? 0) + r.netCents;
      }
    }
    final list = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }
}

/// 单项对比结果
class ItemDiff {
  final String name;
  final int aCents;
  final int bCents;
  final bool inA;
  final bool inB;

  ItemDiff({
    required this.name,
    required this.aCents,
    required this.bCents,
    required this.inA,
    required this.inB,
  });

  int get diff => bCents - aCents;

  /// 变化率（A 为 0 时无意义）
  double? get changeRate => aCents == 0 ? null : diff / aCents;

  /// 只在 B 月有 → 新增
  bool get isNew => !inA && inB;

  /// 只在 A 月有 → 消失
  bool get isGone => inA && !inB;

  /// 是否值得高亮：变动超过 50 元，或超过 5%
  bool get isNotable {
    if (isNew || isGone) return true;
    if (diff.abs() >= 5000) return true;
    final rate = changeRate;
    return rate != null && rate.abs() >= 0.05;
  }
}

/// 两个月对比
class MonthComparison {
  final MonthSummary a;
  final MonthSummary b;
  final List<ItemDiff> incomeDiffs;
  final List<ItemDiff> deductionDiffs;

  MonthComparison({
    required this.a,
    required this.b,
    required this.incomeDiffs,
    required this.deductionDiffs,
  });

  int get grossDiff => b.monthlyGross - a.monthlyGross;
  int get deductionDiff => b.monthlyDeduction - a.monthlyDeduction;
  int get netDiff => b.monthlyNet - a.monthlyNet;

  /// 变化最大的一项，用于生成一句话结论
  ItemDiff? get biggestChange {
    final all = [...incomeDiffs, ...deductionDiffs];
    if (all.isEmpty) return null;
    all.sort((x, y) => y.diff.abs().compareTo(x.diff.abs()));
    return all.first;
  }

  /// 一句话结论，例如："实发 +¥800，主要来自绩效工资 +¥800"
  String get headline {
    if (netDiff == 0) return '两月实发持平';
    final sign = netDiff > 0 ? '多' : '少';
    final base = '实发${netDiff > 0 ? '+' : '-'}¥${(netDiff.abs() / 100).toStringAsFixed(2)}（$sign拿）';
    final big = biggestChange;
    if (big == null || big.diff == 0) return base;
    final dir = big.diff > 0 ? '增加' : '减少';
    return '$base，其中「${big.name}」${dir} ¥${(big.diff.abs() / 100).toStringAsFixed(2)}';
  }
}

/// 统计构建器
class StatsBuilder {
  /// 把某年的记录聚合成年度视图
  static YearSummary buildYear(List<PayRecord> allRecords, int year) {
    final months = <MonthSummary>[];
    for (var m = 1; m <= 12; m++) {
      final inMonth = allRecords
          .where((r) => r.periodYear == year && r.periodMonth == m)
          .toList();
      months.add(MonthSummary(
        year: year,
        month: m,
        monthly: inMonth.where((r) => r.recordType == kTypeMonthly).toList(),
        extras: inMonth.where((r) => r.recordType == kTypeExtra).toList(),
      ));
    }
    return YearSummary(year: year, months: months);
  }

  /// 两个月逐项对比（只比月度工资，奖金不掺进来）
  static MonthComparison compare(MonthSummary a, MonthSummary b) {
    final aIncome = a.incomeItems;
    final bIncome = b.incomeItems;
    final aDed = a.deductionItems;
    final bDed = b.deductionItems;

    return MonthComparison(
      a: a,
      b: b,
      incomeDiffs: _diffMap(aIncome, bIncome),
      deductionDiffs: _diffMap(aDed, bDed),
    );
  }

  static List<ItemDiff> _diffMap(Map<String, int> a, Map<String, int> b) {
    final keys = <String>{...a.keys, ...b.keys};
    final list = keys.map((k) {
      final av = a[k];
      final bv = b[k];
      return ItemDiff(
        name: k,
        aCents: av ?? 0,
        bCents: bv ?? 0,
        inA: av != null,
        inB: bv != null,
      );
    }).toList();

    // 变动大的排前面，方便一眼看到"哪里变了"
    list.sort((x, y) => y.diff.abs().compareTo(x.diff.abs()));
    return list;
  }
}
