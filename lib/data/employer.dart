/// 雇主（发薪单位）。
///
/// 为什么需要这个维度：跳槽之后，旧公司的工资条**不能**和新公司混在一起算。
/// 混着算会出这些问题：
/// - 年度实发合计变成"两家公司加在一起"，看着像涨薪其实不是；
/// - 月度环比拿新公司第一个月和旧公司最后一个月比，涨跌幅毫无意义；
/// - 明细对比里会出现一堆"这项本月消失了"（其实是换了套工资项目）。
///
/// 所以每条工资记录都挂一个雇主，首页/年度/对比默认只看当前雇主，
/// 需要回看历史时切回去即可。
///
/// 起止年月是**可选**的，只用来"录入时自动选中该月份对应的雇主"，
/// 不做强制校验 —— 用户的入职离职日期经常记不清，别拿它卡流程。
class Employer {
  final int? id;
  final String name;

  /// 起薪年月（null = 不限）
  final int? startYear;
  final int? startMonth;

  /// 最后一个月（null = 至今）
  final int? endYear;
  final int? endMonth;

  final int sortOrder;
  final int createdAt;

  Employer({
    this.id,
    required this.name,
    this.startYear,
    this.startMonth,
    this.endYear,
    this.endMonth,
    this.sortOrder = 0,
    this.createdAt = 0,
  });

  /// 某年某月是否属于这家公司（用于录入时自动选中）
  bool covers(int year, int month) {
    final ym = year * 100 + month;
    final s = (startYear != null && startMonth != null) ? startYear! * 100 + startMonth! : null;
    final e = (endYear != null && endMonth != null) ? endYear! * 100 + endMonth! : null;
    if (s != null && ym < s) return false;
    if (e != null && ym > e) return false;
    return true;
  }

  /// 在职区间文案，例如「2024.03 – 2025.06」「2024.03 起」「— 2025.06」
  String get periodLabel {
    final hasStart = startYear != null && startMonth != null;
    final hasEnd = endYear != null && endMonth != null;
    final s = hasStart
        ? '$startYear.${startMonth!.toString().padLeft(2, '0')}'
        : '';
    final e = hasEnd ? '$endYear.${endMonth!.toString().padLeft(2, '0')}' : '';
    if (hasStart && hasEnd) return '$s – $e';
    if (hasStart) return '$s 起';
    if (hasEnd) return '— $e';
    return '';
  }

  bool get hasPeriod => startYear != null || endYear != null;

  Employer copyWith({
    int? id,
    String? name,
    int? startYear,
    int? startMonth,
    int? endYear,
    int? endMonth,
    int? sortOrder,
    int? createdAt,
    bool clearStart = false,
    bool clearEnd = false,
  }) =>
      Employer(
        id: id ?? this.id,
        name: name ?? this.name,
        startYear: clearStart ? null : (startYear ?? this.startYear),
        startMonth: clearStart ? null : (startMonth ?? this.startMonth),
        endYear: clearEnd ? null : (endYear ?? this.endYear),
        endMonth: clearEnd ? null : (endMonth ?? this.endMonth),
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'start_year': startYear,
        'start_month': startMonth,
        'end_year': endYear,
        'end_month': endMonth,
        'sort_order': sortOrder,
        'created_at': createdAt,
      };

  factory Employer.fromMap(Map<String, Object?> m) => Employer(
        id: m['id'] as int?,
        name: (m['name'] as String?) ?? '',
        startYear: m['start_year'] as int?,
        startMonth: m['start_month'] as int?,
        endYear: m['end_year'] as int?,
        endMonth: m['end_month'] as int?,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}
