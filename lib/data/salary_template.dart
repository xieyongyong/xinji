import 'models.dart';

/// 模板适用类型。工资条和年终奖的字段结构差异很大：
/// 月度有绩效系数、社保公积金，奖金条通常只有「奖金金额 + 个税」。
/// 不区分的后果是：导入年终奖时被月度模板塞进一堆 0 值绩效项，
/// 看起来像"这个月绩效没发"。
const String kTplMonthly = 'monthly';
const String kTplExtra = 'extra';
const String kTplAll = 'all';

String templateTypeLabel(String appliesTo) => switch (appliesTo) {
      kTplExtra => '奖金与其他',
      kTplAll => '通用',
      _ => '月度工资',
    };

/// 一套「发薪模板」= 这家公司的工资条长什么样。
///
/// 为什么需要它：换公司、换岗、公司改工资条格式时，字段清单会变。
///
/// 归属关系是 **雇主 → 多套模板**：
/// - 同一家公司可能先后用过几种工资条格式（涨薪、换系统、改绩效结构），
///   每种存一套，随时切回来对比；
/// - 每家公司**每种适用类型各自有一套「生效中」**，互不干扰：月度一套、
///   奖金一套（可再有一套通用兜底）。
class SalaryTemplate {
  final int? id;

  /// 属于哪家雇主。为空表示历史遗留的"全局模板"，加载时会兜到第一家。
  final int? employerId;

  final String name;

  /// 适用类型：monthly（月度工资）/ extra（奖金与其他）/ all（两类通用）
  final String appliesTo;

  final bool isActive;
  final int createdAt;
  final int updatedAt;

  /// 字段清单（加载后填充，不落库）
  List<TemplateField> fields;

  SalaryTemplate({
    this.id,
    this.employerId,
    required this.name,
    this.appliesTo = kTplMonthly,
    this.isActive = false,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.fields = const [],
  });

  List<TemplateField> get incomeFields =>
      fields.where((f) => f.category == kCategoryIncome).toList();
  List<TemplateField> get deductionFields =>
      fields.where((f) => f.category == kCategoryDeduction).toList();
  List<TemplateField> get infoFields =>
      fields.where((f) => f.category == kFieldInfo).toList();

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'employer_id': employerId,
        'name': name,
        'applies_to': appliesTo,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory SalaryTemplate.fromMap(Map<String, Object?> m) => SalaryTemplate(
        id: m['id'] as int?,
        employerId: m['employer_id'] as int?,
        name: (m['name'] as String?) ?? '',
        // 老库/老备份没有这一列：一律当月度模板，行为与升级前一致
        appliesTo: (m['applies_to'] as String?) ?? kTplMonthly,
        isActive: ((m['is_active'] as int?) ?? 0) == 1,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
      );

  SalaryTemplate copyWith({
    int? id,
    int? employerId,
    String? name,
    String? appliesTo,
    bool? isActive,
    List<TemplateField>? fields,
  }) =>
      SalaryTemplate(
        id: id ?? this.id,
        employerId: employerId ?? this.employerId,
        name: name ?? this.name,
        appliesTo: appliesTo ?? this.appliesTo,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt,
        updatedAt: updatedAt,
        fields: fields ?? this.fields,
      );
}

/// 模板里的一个字段。
///
/// category 有三种：
/// - income    收入项，参与应发合计
/// - deduction 扣款项，参与代扣合计
/// - info      信息项，**不参与任何计算**（姓名、工号、应出勤天数…）
class TemplateField {
  final int? id;
  final int? templateId;
  final String name;
  final String category;
  final String valueType;
  final int sortOrder;

  TemplateField({
    this.id,
    this.templateId,
    required this.name,
    required this.category,
    this.valueType = kValueAmount,
    this.sortOrder = 0,
  });

  bool get isInfo => category == kFieldInfo;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'template_id': templateId,
        'name': name,
        'category': category,
        'value_type': valueType,
        'sort_order': sortOrder,
      };

  factory TemplateField.fromMap(Map<String, Object?> m) => TemplateField(
        id: m['id'] as int?,
        templateId: m['template_id'] as int?,
        name: (m['name'] as String?) ?? '',
        category: (m['category'] as String?) ?? kCategoryIncome,
        valueType: (m['value_type'] as String?) ?? kValueAmount,
        sortOrder: (m['sort_order'] as int?) ?? 0,
      );
}
