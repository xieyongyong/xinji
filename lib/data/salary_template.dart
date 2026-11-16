import 'models.dart';

/// 一套「发薪模板」= 这家公司的工资条长什么样。
///
/// 为什么需要它：换公司、换岗、公司改工资条格式时，字段清单会变。
/// 用户可以给每家公司/每种格式建一套模板，**同一时间只有一套生效**，
/// 录入和 OCR 预填都按生效的那套走，不用每次手动加十几个项目。
class SalaryTemplate {
  final int? id;
  final String name;
  final bool isActive;
  final int createdAt;
  final int updatedAt;

  /// 字段清单（加载后填充，不落库）
  List<TemplateField> fields;

  SalaryTemplate({
    this.id,
    required this.name,
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
        'name': name,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory SalaryTemplate.fromMap(Map<String, Object?> m) => SalaryTemplate(
        id: m['id'] as int?,
        name: (m['name'] as String?) ?? '',
        isActive: ((m['is_active'] as int?) ?? 0) == 1,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
      );

  SalaryTemplate copyWith({int? id, String? name, bool? isActive, List<TemplateField>? fields}) =>
      SalaryTemplate(
        id: id ?? this.id,
        name: name ?? this.name,
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
