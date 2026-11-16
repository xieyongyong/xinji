/// OCR 阶段的中间数据结构。
///
/// 三层抽象，逐层收敛：
/// 1. [RawLine]   —— 识别引擎直接吐出来的一个文本片段（带位置）
/// 2. [VisualRow] —— 把同一水平线上的多个片段聚成"视觉上的一行"
/// 3. [ParsedRow] —— 从视觉行里解析出「项目名 + 金额」，并判定是明细还是合计行
library;

/// OCR 的一个文本片段
class RawLine {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  RawLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get centerY => (top + bottom) / 2;
  double get height => bottom - top;
  double get width => right - left;

  @override
  String toString() => 'RawLine("$text" @$left,$top)';
}

/// 视觉行：工资条是表格，一行会被 OCR 拆成「左边项目名」「右边金额」两个片段，
/// 靠 y 坐标把它们合成一行，才能在解析阶段正确配对。
class VisualRow {
  final List<RawLine> cells;

  VisualRow(RawLine first) : cells = [first];

  void add(RawLine line) => cells.add(line);

  /// 按 x 从左到右排序（配对时"最右的金额"才是金额列）
  void sortCells() => cells.sort((a, b) => a.left.compareTo(b.left));

  double get top => cells.map((e) => e.top).reduce((a, b) => a < b ? a : b);
  double get bottom => cells.map((e) => e.bottom).reduce((a, b) => a > b ? a : b);
  double get centerY => (top + bottom) / 2;

  /// 整行文本（调试与留档用）
  String get fullText => cells.map((e) => e.text.trim()).where((e) => e.isNotEmpty).join(' ');

  /// 最左侧片段（通常是项目名）
  String get leftText => cells.isEmpty ? '' : cells.first.text.trim();

  @override
  String toString() => 'VisualRow(${cells.map((e) => e.text).join(" | ")})';
}

/// 解析后的行类型
enum ParsedRowKind {
  /// 正常明细项（收入或扣款）
  item,

  /// 信息项：姓名、工号、部门、薪级对应基薪、出勤天数、加班时数……
  /// 有值但不是钱，**不进入明细、不参与任何合计**
  info,

  /// 应发合计
  totalGross,

  /// 代扣/扣款合计
  totalDeduction,

  /// 实发合计
  totalNet,

  /// 只写了"合计/总计"但没说清是哪一项合计。
  /// 不硬猜，留到合并阶段用「数值等于哪组明细之和」来判定归属。
  ambiguousTotal,

  /// 噪声：表头、姓名工号、说明文字等，不进入明细
  noise,
}

/// 解析后的一行
class ParsedRow {
  final String name;
  final int? amountCents;
  final double? coefficient;
  final ParsedRowKind kind;
  final String raw;

  /// 信息项的值（原文，不转金额）。如「工号」的 "199438"、「正常出勤天数」的 "20"
  final String? infoValue;

  /// 来自第几张图（0 起）
  final int imageIndex;

  /// y 坐标，用于判断顺序与重叠
  final double top;

  /// 是否由"折行"合并而来（项目名在上一行、金额在下一行）
  final bool mergedFromWrappedText;

  ParsedRow({
    required this.name,
    this.amountCents,
    this.coefficient,
    this.infoValue,
    required this.kind,
    required this.raw,
    required this.imageIndex,
    required this.top,
    this.mergedFromWrappedText = false,
  });

  bool get hasAmount => amountCents != null;

  ParsedRow copyWith({ParsedRowKind? kind, String? name}) => ParsedRow(
        name: name ?? this.name,
        amountCents: amountCents,
        coefficient: coefficient,
        infoValue: infoValue,
        kind: kind ?? this.kind,
        raw: raw,
        imageIndex: imageIndex,
        top: top,
        mergedFromWrappedText: mergedFromWrappedText,
      );

  @override
  String toString() => 'ParsedRow($name, $amountCents, $kind)';
}

/// 一张图片的解析结果
class ParsedImage {
  final int index;
  final String filePath;
  final List<ParsedRow> rows;
  final String rawText;

  /// 该图的识别置信提示（空字符串表示无异常）
  final String? note;

  /// 工资条标题上写的归属年月（如 "2025年06月薪资" → 2025/6）。
  ///
  /// 识别不到就是 null。为什么不让用户每次都手选：
  /// 导入时分页截了好几张，月份只有标题那一张有，靠人记容易选错；
  /// 但识别也可能出错（标题没截到、被水印糊了），所以只当**默认值**，
  /// 校对页永远可以改。
  final int? periodYear;
  final int? periodMonth;

  ParsedImage({
    required this.index,
    required this.filePath,
    required this.rows,
    required this.rawText,
    this.note,
    this.periodYear,
    this.periodMonth,
  });

  List<ParsedRow> get itemRows => rows.where((e) => e.kind == ParsedRowKind.item).toList();

  List<ParsedRow> get infoRows => rows.where((e) => e.kind == ParsedRowKind.info).toList();

  ParsedRow? get grossRow => rows.where((e) => e.kind == ParsedRowKind.totalGross).firstOrNull;
  ParsedRow? get deductionRow =>
      rows.where((e) => e.kind == ParsedRowKind.totalDeduction).firstOrNull;
  ParsedRow? get netRow => rows.where((e) => e.kind == ParsedRowKind.totalNet).firstOrNull;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
