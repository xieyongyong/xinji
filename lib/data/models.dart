import 'dart:convert';

import '../core/money.dart';

/// 记录类型：月度工资 / 其他收入（年终奖、项目奖金等）
const String kTypeMonthly = 'monthly';
const String kTypeExtra = 'extra';

/// 明细分类
const String kCategoryIncome = 'income';
const String kCategoryDeduction = 'deduction';

/// 明细值类型：金额 / 系数（如绩效系数 1.20）/ 推算值
///
/// 推算值（derived）是为了「基本绩效」这类字段：
/// 工资条上只印「本月绩效系数 1.1」和「实发绩效工资 1826」，
/// 基本绩效 = 1826 ÷ 1.1 = 1660 —— 它是**反推出来的基数**，
/// 已经体现在实发绩效里，再算进应发就会重复计算。
/// 所以它要能被看见、能被公式引用，但**结构上不参与任何合计**。
const String kValueAmount = 'amount';
const String kValueCoefficient = 'coefficient';
const String kValueDerived = 'derived';

/// 发薪模板字段分类：收入 / 扣款 / 信息（信息项不参与任何合计）
const String kFieldInfo = 'info';

/// 一条收入记录（一次发放）。
///
/// 主表只保留**任何公司都必然存在**的字段：
/// 年月、类型、应发/代扣/实发三个合计。
/// 薪级、基薪、公司名、备注等非通用信息全部塞进 [extra]（JSON），
/// 这样换公司、加工资条格式都不用改表结构。
class PayRecord {
  final int? id;
  final int periodYear;
  final int periodMonth;
  final String recordType;
  final String? recordLabel;

  /// 应发合计（分）
  final int grossCents;

  /// 代扣合计（分）
  final int deductionCents;

  /// 实发合计（分）
  final int netCents;

  /// 扩展信息：{"grade": "P6", "base": 8000, "company": "...", "note": "..."}
  final Map<String, dynamic>? extra;

  final int createdAt;
  final int updatedAt;

  /// 加载后填充，不落库
  List<PayItem> items;
  List<PayImage> images;

  /// 信息项：只记录、不计入合计（姓名、工号、业务单位、应出勤天数等）
  List<PayInfo> infos;

  PayRecord({
    this.id,
    required this.periodYear,
    required this.periodMonth,
    required this.recordType,
    this.recordLabel,
    required this.grossCents,
    required this.deductionCents,
    required this.netCents,
    this.extra,
    required this.createdAt,
    required this.updatedAt,
    this.items = const [],
    this.images = const [],
    this.infos = const [],
  });

  bool get isMonthly => recordType == kTypeMonthly;

  /// 列表卡片标题
  String get displayTitle {
    if (isMonthly) return '$periodYear年$periodMonth月工资';
    final label = (recordLabel ?? '').trim();
    return label.isEmpty ? '$periodYear年$periodMonth月其他收入' : label;
  }

  /// 排序键：年月 + 创建时间（同月多条按录入顺序）
  int get sortKey =>
      periodYear * 10000 + periodMonth * 100 + (createdAt ~/ 1000 % 100);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'period_year': periodYear,
        'period_month': periodMonth,
        'record_type': recordType,
        'record_label': recordLabel,
        'gross_cents': grossCents,
        'deduction_cents': deductionCents,
        'net_cents': netCents,
        'extra': extra == null ? null : jsonEncode(extra),
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory PayRecord.fromMap(Map<String, Object?> m) {
    Map<String, dynamic>? extraMap;
    final rawExtra = m['extra'];
    if (rawExtra is String && rawExtra.isNotEmpty) {
      try {
        extraMap = jsonDecode(rawExtra) as Map<String, dynamic>;
      } catch (_) {
        extraMap = null;
      }
    }
    return PayRecord(
      id: m['id'] as int?,
      periodYear: (m['period_year'] as int?) ?? 0,
      periodMonth: (m['period_month'] as int?) ?? 1,
      recordType: (m['record_type'] as String?) ?? kTypeMonthly,
      recordLabel: m['record_label'] as String?,
      grossCents: (m['gross_cents'] as int?) ?? 0,
      deductionCents: (m['deduction_cents'] as int?) ?? 0,
      netCents: (m['net_cents'] as int?) ?? 0,
      extra: extraMap,
      createdAt: (m['created_at'] as int?) ?? 0,
      updatedAt: (m['updated_at'] as int?) ?? 0,
    );
  }

  PayRecord copyWith({
    int? id,
    int? periodYear,
    int? periodMonth,
    String? recordType,
    String? recordLabel,
    int? grossCents,
    int? deductionCents,
    int? netCents,
    Map<String, dynamic>? extra,
    int? updatedAt,
    List<PayItem>? items,
    List<PayImage>? images,
    List<PayInfo>? infos,
  }) {
    return PayRecord(
      id: id ?? this.id,
      periodYear: periodYear ?? this.periodYear,
      periodMonth: periodMonth ?? this.periodMonth,
      recordType: recordType ?? this.recordType,
      recordLabel: recordLabel ?? this.recordLabel,
      grossCents: grossCents ?? this.grossCents,
      deductionCents: deductionCents ?? this.deductionCents,
      netCents: netCents ?? this.netCents,
      extra: extra ?? this.extra,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      items: items ?? this.items,
      images: images ?? this.images,
      infos: infos ?? this.infos,
    );
  }
}

/// 信息项：**只记录、永远不计入任何合计**。
///
/// 工资条上有一批"看一眼有用、但不能参与算钱"的内容：
/// 业务单位、工号、姓名、薪级对应基薪、应出勤天数、考核评分……
/// 早期版本把它们塞进 extra(JSON)，用户改不了也看不见。
/// 现在单独一张表，可自由增删，且结构上不可能被算进合计。
class PayInfo {
  final int? id;
  final int? recordId;
  final String name;
  final String value;
  final int sortOrder;

  PayInfo({
    this.id,
    this.recordId,
    required this.name,
    this.value = '',
    this.sortOrder = 0,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'record_id': recordId,
        'name': name,
        'value': value,
        'sort_order': sortOrder,
      };

  factory PayInfo.fromMap(Map<String, Object?> m) => PayInfo(
        id: m['id'] as int?,
        recordId: m['record_id'] as int?,
        name: (m['name'] as String?) ?? '',
        value: (m['value'] as String?) ?? '',
        sortOrder: (m['sort_order'] as int?) ?? 0,
      );

  PayInfo copyWith({int? id, int? recordId, String? name, String? value, int? sortOrder}) =>
      PayInfo(
        id: id ?? this.id,
        recordId: recordId ?? this.recordId,
        name: name ?? this.name,
        value: value ?? this.value,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

/// 一条明细项（收入或扣款）。
///
/// 项目名不写死在代码里，全部走这张表 —— 换公司、加工资条项目都不用改代码。
class PayItem {
  final int? id;
  final int? recordId;
  final String name;
  final String category;
  final String valueType;

  /// 金额（分）。系数型明细这里存"算出来的金额"，[coefficient] 存原始系数。
  final int amountCents;

  /// 系数（如绩效系数 1.2），仅 valueType == coefficient 时有值
  final double? coefficient;

  final int sortOrder;

  /// 该行来自哪张图，便于溯源与撤回
  final int? sourceImageId;

  PayItem({
    this.id,
    this.recordId,
    required this.name,
    required this.category,
    this.valueType = kValueAmount,
    this.amountCents = 0,
    this.coefficient,
    this.sortOrder = 0,
    this.sourceImageId,
  });

  bool get isIncome => category == kCategoryIncome;
  bool get isDeduction => category == kCategoryDeduction;
  bool get isCoefficient => valueType == kValueCoefficient;

  /// 推算值：由公式反推得到，不参与任何合计（如基本绩效）
  bool get isDerived => valueType == kValueDerived;

  /// 这一项是否应该被加进合计。
  /// 唯一判据就这一处，别的地方都调它 —— 免得哪天又出现
  /// "详情页没算、首页算了"这种两边对不上的 bug。
  bool get countsInTotal => valueType == kValueAmount;

  /// 行右侧显示什么
  String get displayValue {
    if (isCoefficient && coefficient != null) {
      return '× ${coefficient!.toStringAsFixed(2)}';
    }
    return formatCents(amountCents);
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'record_id': recordId,
        'name': name,
        'category': category,
        'value_type': valueType,
        'amount_cents': amountCents,
        'coefficient': coefficient,
        'sort_order': sortOrder,
        'source_image_id': sourceImageId,
      };

  factory PayItem.fromMap(Map<String, Object?> m) => PayItem(
        id: m['id'] as int?,
        recordId: m['record_id'] as int?,
        name: (m['name'] as String?) ?? '',
        category: (m['category'] as String?) ?? kCategoryIncome,
        valueType: (m['value_type'] as String?) ?? kValueAmount,
        amountCents: (m['amount_cents'] as int?) ?? 0,
        coefficient: (m['coefficient'] as num?)?.toDouble(),
        sortOrder: (m['sort_order'] as int?) ?? 0,
        sourceImageId: m['source_image_id'] as int?,
      );

  PayItem copyWith({
    int? id,
    int? recordId,
    String? name,
    String? category,
    String? valueType,
    int? amountCents,
    double? coefficient,
    int? sortOrder,
    int? sourceImageId,
  }) =>
      PayItem(
        id: id ?? this.id,
        recordId: recordId ?? this.recordId,
        name: name ?? this.name,
        category: category ?? this.category,
        valueType: valueType ?? this.valueType,
        amountCents: amountCents ?? this.amountCents,
        coefficient: coefficient ?? this.coefficient,
        sortOrder: sortOrder ?? this.sortOrder,
        sourceImageId: sourceImageId ?? this.sourceImageId,
      );
}

/// 原始工资条截图。一条记录可挂多张（明细太长一张截不完）。
class PayImage {
  final int? id;
  final int? recordId;
  final String filePath;
  final int sortOrder;

  /// 这张图的 OCR 原文，留档备查
  final String? ocrText;
  final int createdAt;

  PayImage({
    this.id,
    this.recordId,
    required this.filePath,
    this.sortOrder = 0,
    this.ocrText,
    this.createdAt = 0,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'record_id': recordId,
        'file_path': filePath,
        'sort_order': sortOrder,
        'ocr_text': ocrText,
        'created_at': createdAt,
      };

  factory PayImage.fromMap(Map<String, Object?> m) => PayImage(
        id: m['id'] as int?,
        recordId: m['record_id'] as int?,
        filePath: (m['file_path'] as String?) ?? '',
        sortOrder: (m['sort_order'] as int?) ?? 0,
        ocrText: m['ocr_text'] as String?,
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}

/// 项目模板：既是 OCR 匹配词典，也是跨月对比的对齐依据。
///
/// aliases 解决"公司改项目名"导致对比断裂的问题：
/// 「岗位津贴」与「岗位工资」映射到同一项。
class ItemTemplate {
  final int? id;
  final String name;
  final String category;
  final List<String> aliases;
  final String valueType;
  final int sortOrder;
  final bool enabled;

  ItemTemplate({
    this.id,
    required this.name,
    required this.category,
    this.aliases = const [],
    this.valueType = kValueAmount,
    this.sortOrder = 0,
    this.enabled = true,
  });

  /// 判断一个识别出来的项目名是否属于本模板项
  bool matches(String rawName) {
    final n = normalizeName(rawName);
    if (n.isEmpty) return false;
    if (n == normalizeName(name)) return true;
    for (final a in aliases) {
      if (n == normalizeName(a)) return true;
    }
    return false;
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'category': category,
        'aliases': aliases.join(','),
        'value_type': valueType,
        'sort_order': sortOrder,
        'enabled': enabled ? 1 : 0,
      };

  factory ItemTemplate.fromMap(Map<String, Object?> m) => ItemTemplate(
        id: m['id'] as int?,
        name: (m['name'] as String?) ?? '',
        category: (m['category'] as String?) ?? kCategoryIncome,
        aliases: ((m['aliases'] as String?) ?? '')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        valueType: (m['value_type'] as String?) ?? kValueAmount,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        enabled: ((m['enabled'] as int?) ?? 1) == 1,
      );
}
