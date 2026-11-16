import '../core/money.dart';
import '../ocr/merge_engine.dart';
import 'models.dart';
import 'salary_template.dart';

/// 明细顺序：**一律按发薪模板里的字段顺序**排。
///
/// ## 为什么需要这一层
/// 同一家公司每个月导入的是同一套工资条，明细顺序必须稳定：
/// 这个月「岗位津贴」在第 3 行、下个月跑到第 5 行，肉眼看对不上，
/// 跨月对比的表格也会跳来跳去。
///
/// 但 OCR 出来的行序本身就会抖 —— 分块边界、行聚类、同一行里左右两列
/// 谁先被检出，都会影响顺序。所以入库前统一按模板重排一次：
///
/// 1. 模板里有的项，位置由模板的字段顺序决定（和「工资条模板」页面里看到的一致）；
/// 2. 模板里没有的项，一律排到同类末尾，并保持它们原来的相对顺序
///    （稳定排序，不额外打乱 OCR 已经认对的行序）；
/// 3. 收入在前、扣款在后 —— 和详情页的两张卡片一致。
///
/// 排序键里带一个固定的「未知项名次」，所以同一份数据无论排几次结果都一样，
/// 不会因为反复编辑让顺序漂移。

/// 模板里没有这个字段时用的名次，取一个足够大的数
const int _kUnknownRank = 1 << 20;

/// 类别分组：收入 0、扣款 1（信息项走 [orderInfosByTemplate]，不在这里）
int _groupOf(String category) => category == kCategoryIncome ? 0 : 1;

/// 归一化字段名 -> 在模板里的名次。同名只认第一个。
Map<String, int> _ranksOf(List<TemplateField> fields) {
  final map = <String, int>{};
  for (var i = 0; i < fields.length; i++) {
    final key = normalizeName(fields[i].name);
    if (key.isEmpty) continue;
    map.putIfAbsent(key, () => i);
  }
  return map;
}

/// 稳定排序：`List.sort` 在 Dart 里**不保证稳定**，
/// 所以自己带上原始下标做第二关键字，避免同类项被随机打乱。
List<T> _stableSort<T>(List<T> src, int Function(T) rankOf) {
  final rows = <({int rank, int order, T item})>[];
  for (var i = 0; i < src.length; i++) {
    rows.add((rank: rankOf(src[i]), order: i, item: src[i]));
  }
  rows.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.order.compareTo(b.order);
  });
  return [for (final r in rows) r.item];
}

/// 明细草稿（校对页用）：收入在前、扣款在后，各自按模板顺序。
List<PayItemDraft> orderDraftsByTemplate(
  List<PayItemDraft> src,
  SalaryTemplate? tpl,
) {
  final ranks = tpl == null ? const <String, int>{} : _ranksOf(tpl.fields);
  return _stableSort(src, (d) {
    final rank = ranks[normalizeName(d.name)] ?? _kUnknownRank;
    return _groupOf(d.category) * (_kUnknownRank * 2) + rank;
  });
}

/// 已入库明细（详情页展示用）：调用方已经按收入/扣款分好组，
/// 这里只按模板顺序排组内。
List<PayItem> orderItemsByTemplate(List<PayItem> src, SalaryTemplate? tpl) {
  final ranks = tpl == null ? const <String, int>{} : _ranksOf(tpl.fields);
  return _stableSort(
    src,
    (e) => ranks[normalizeName(e.name)] ?? _kUnknownRank,
  );
}

/// 信息项按模板里「信息项」的字段顺序排（姓名、工号、部门…）。
List<PayInfo> orderInfosByTemplate(List<PayInfo> src, SalaryTemplate? tpl) {
  final ranks = tpl == null ? const <String, int>{} : _ranksOf(tpl.infoFields);
  return _stableSort(
    src,
    (e) => ranks[normalizeName(e.name)] ?? _kUnknownRank,
  );
}
