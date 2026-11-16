import '../data/models.dart';

/// 一年内某个月的聚合（跨年统计时用来把 1~12 月各月合并）
class MonthAgg {
  final int month;

  /// 这几年的这个月一共出现过几次（有记录的月份数，不是 12）
  final int times;
  final int net;
  final int gross;
  final int deduction;

  MonthAgg({
    required this.month,
    required this.times,
    required this.net,
    required this.gross,
    required this.deduction,
  });

  bool get isEmpty => times == 0;

  int get avgNet => times == 0 ? 0 : (net / times).round();
}

/// 一年的聚合
class YearAgg {
  final int year;
  final int net;
  final int gross;
  final int deduction;
  final int monthlyNet;
  final int extraNet;
  final int recordCount;

  /// 有记录的月份数（未录入的月份不拉低月均）
  final int months;

  YearAgg({
    required this.year,
    required this.net,
    required this.gross,
    required this.deduction,
    required this.monthlyNet,
    required this.extraNet,
    required this.recordCount,
    required this.months,
  });

  int get avgNet => months == 0 ? 0 : (monthlyNet / months).round();
}

/// 任意范围的汇总（全部年份 / 某一年）。
///
/// 之所以单独做一层，是因为原来只有 [YearSummary]：只能一年年看，
/// 想看"这几年一共拿了多少"就必须自己心算。
/// 这里把口径固定成三句话，避免各页面各算一套：
/// - 实发 = 应发 - 代扣（直接取记录上的 net_cents，不做二次推导）
/// - 月均 = 月度实发 / **有记录的月份数**（没录入的月份不算 0）
/// - 奖金单独列，不混进月均，否则年终奖会把月均拉飞
class RangeSummary {
  final List<PayRecord> records;

  RangeSummary(this.records);

  bool get isEmpty => records.isEmpty;

  int _sum(int Function(PayRecord) f) => records.fold(0, (s, r) => s + f(r));

  int get totalNet => _sum((r) => r.netCents);
  int get totalGross => _sum((r) => r.grossCents);
  int get totalDeduction => _sum((r) => r.deductionCents);

  List<PayRecord> get _monthly =>
      records.where((r) => r.recordType == kTypeMonthly).toList();
  List<PayRecord> get _extras =>
      records.where((r) => r.recordType == kTypeExtra).toList();

  int get monthlyNet => _monthly.fold(0, (s, r) => s + r.netCents);
  int get extraNet => _extras.fold(0, (s, r) => s + r.netCents);

  /// 有记录的月份数（同一个月多笔只算一个月）
  int get monthCount =>
      _monthly.map((r) => r.periodYear * 100 + r.periodMonth).toSet().length;

  int get avgNet => monthCount == 0 ? 0 : (monthlyNet / monthCount).round();

  int get recordCount => records.length;

  /// 最早 / 最晚一笔的"年-月"标签，用来告诉用户这个总计覆盖到哪
  String get periodLabel {
    if (records.isEmpty) return '';
    final keys = records.map((r) => r.periodYear * 100 + r.periodMonth).toList()
      ..sort();
    final a = keys.first;
    final b = keys.last;
    final s = '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    final e = '${b ~/ 100}.${(b % 100).toString().padLeft(2, '0')}';
    return s == e ? s : '$s – $e';
  }

  /// 每个项目一共拿了多少（收入）
  List<MapEntry<String, int>> get incomeByItem => _itemMap(kCategoryIncome);

  /// 每个项目一共扣了多少
  List<MapEntry<String, int>> get deductionByItem => _itemMap(kCategoryDeduction);

  List<MapEntry<String, int>> _itemMap(String category) {
    final map = <String, int>{};
    for (final r in records) {
      for (final it in r.items) {
        if (it.category != category) continue;
        // 系数、推算值都不是钱，卷进合计会让"项目累计"对不上应发
        if (!it.countsInTotal) continue;
        map[it.name] = (map[it.name] ?? 0) + it.amountCents;
      }
    }
    final list = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// 按年份汇总（倒序）
  List<YearAgg> get byYear {
    final groups = <int, List<PayRecord>>{};
    for (final r in records) {
      groups.putIfAbsent(r.periodYear, () => []).add(r);
    }
    final years = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return years.map((y) {
      final list = groups[y]!;
      final monthly = list.where((r) => r.recordType == kTypeMonthly).toList();
      return YearAgg(
        year: y,
        net: list.fold(0, (s, r) => s + r.netCents),
        gross: list.fold(0, (s, r) => s + r.grossCents),
        deduction: list.fold(0, (s, r) => s + r.deductionCents),
        monthlyNet: monthly.fold(0, (s, r) => s + r.netCents),
        extraNet: list
            .where((r) => r.recordType == kTypeExtra)
            .fold(0, (s, r) => s + r.netCents),
        recordCount: list.length,
        months: monthly.map((r) => r.periodMonth).toSet().length,
      );
    }).toList();
  }

  /// 1~12 月跨年合并：看"哪个月通常拿得多"，比单年曲线更能看出规律
  List<MonthAgg> get byMonthOfYear {
    final nets = List<int>.filled(13, 0);
    final gross = List<int>.filled(13, 0);
    final ded = List<int>.filled(13, 0);
    final seen = <int, Set<String>>{};

    for (final r in _monthly) {
      final m = r.periodMonth;
      if (m < 1 || m > 12) continue;
      nets[m] += r.netCents;
      gross[m] += r.grossCents;
      ded[m] += r.deductionCents;
      seen.putIfAbsent(m, () => <String>{}).add('${r.periodYear}-$m');
    }

    return [
      for (var m = 1; m <= 12; m++)
        MonthAgg(
          month: m,
          times: seen[m]?.length ?? 0,
          net: nets[m],
          gross: gross[m],
          deduction: ded[m],
        ),
    ];
  }

  /// 奖金按名目汇总
  List<MapEntry<String, int>> get extraByLabel {
    final map = <String, int>{};
    for (final r in _extras) {
      final label = (r.recordLabel ?? '其他收入').trim();
      map[label] = (map[label] ?? 0) + r.netCents;
    }
    final list = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// 按雇主汇总（跨雇主的总计才用得上）
  List<MapEntry<int, int>> get netByEmployer {
    final map = <int, int>{};
    for (final r in records) {
      final id = r.employerId ?? -1;
      map[id] = (map[id] ?? 0) + r.netCents;
    }
    final list = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }
}
