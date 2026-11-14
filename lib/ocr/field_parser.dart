import '../core/money.dart';
import '../data/models.dart';
import 'line_builder.dart';
import 'ocr_models.dart';

/// 把「视觉行」解析成「项目名 + 金额」，并判定每行是明细、合计还是噪声。
///
/// 这里的所有规则都是为了应对真实工资条截图的脏数据：
/// 表头、姓名工号、说明文字、折行的项目名、只写"合计"不写是哪项合计……
class FieldParser {
  final List<ItemTemplate> templates;

  FieldParser(this.templates);

  // ---- 关键词表（顺序敏感：先判具体合计，再判模糊合计）----

  static const List<String> netKeywords = [
    '实发工资', '实发合计', '实发金额', '实发数', '实发', '到手工资',
  ];

  static const List<String> grossKeywords = [
    '应发工资', '应发合计', '应发金额', '应发数', '应发', '税前合计', '工资总额',
  ];

  static const List<String> deductionKeywords = [
    '代扣合计', '扣款合计', '扣除合计', '代扣小计', '扣款小计', '扣款总额',
    '个人承担合计', '个人缴纳合计', '扣除项合计', '代扣款项合计',
  ];

  static const List<String> ambiguousTotalKeywords = ['合计', '总计', '小计', '总额', '共计'];

  /// 命中即视为噪声（表头、身份信息、说明）。注意不要放"岗位""工资"这类宽泛词，
  /// 否则会把"岗位津贴""绩效工资"误杀。
  static const List<String> noiseKeywords = [
    '姓名', '工号', '员工编号', '员工号', '身份证', '部门', '车间', '班组', '科室',
    '职位', '职务', '入职', '制表', '制单', '审核', '批准', '复核', '签字', '签名',
    '确认', '核对', '备注', '说明', '声明', '序号', '编号', '发放日期', '发放时间',
    '工资条', '工资单', '温馨提示', '如有疑问', '本表', '以上', '单位名称', '公司名称',
    '本月应发', '本月实发',
  ];

  /// 解析一张图
  ParsedImage parseImage({
    required int index,
    required String filePath,
    required List<RawLine> lines,
    required String rawText,
  }) {
    final visualRows = LineBuilder.build(lines);
    final rows = <ParsedRow>[];
    for (final vr in visualRows) {
      final row = _parseRow(vr, index);
      if (row != null) rows.add(row);
    }
    return ParsedImage(
      index: index,
      filePath: filePath,
      rows: _mergeWrappedNames(rows),
      rawText: rawText,
    );
  }

  // ---------------------------------------------------------------- 单行解析

  ParsedRow? _parseRow(VisualRow row, int imageIndex) {
    final text = row.fullText.trim();
    if (text.isEmpty) return null;

    final compact = text.replaceAll(RegExp(r'\s+'), '');

    // 年月标题行（如 "2026年10月" / "2026-10"）：会被误认成金额，先拦掉
    if (RegExp(r'^\d{4}\s*[-/年.]\s*\d{1,2}\s*月?$').hasMatch(compact)) {
      return ParsedRow(
        name: text,
        kind: ParsedRowKind.noise,
        raw: text,
        imageIndex: imageIndex,
        top: row.top,
      );
    }

    // 1) 找金额列：从右往左，第一个"像金额"的片段
    int? amountCents;
    String amountText = '';
    var amountCellIndex = -1;

    for (var i = row.cells.length - 1; i >= 0; i--) {
      final cellText = row.cells[i].text.trim();
      final v = parseAmountToCents(cellText);
      if (v != null && looksLikeAmount(cellText)) {
        amountCents = v;
        amountText = cellText;
        amountCellIndex = i;
        break;
      }
    }

    // 2) 名称：金额列左边的全部片段
    var name = '';
    if (amountCellIndex > 0) {
      name = row.cells
          .sublist(0, amountCellIndex)
          .map((e) => e.text.trim())
          .where((e) => e.isNotEmpty)
          .join('');
    } else if (amountCellIndex < 0) {
      // 整行没有独立金额列，可能是"基本工资 8000.00"挤在一个片段里
      final split = _splitTrailingAmount(text);
      if (split != null) {
        name = split.name;
        amountCents = split.cents;
        amountText = split.amountText;
      } else {
        name = text;
      }
    }
    // amountCellIndex == 0 表示金额在最左、左边没有名称 → 留给折行合并去补

    // 3) 定类型
    final kind = _classify(compact, hasAmount: amountCents != null);

    // 4) 系数型（绩效系数 1.20）：不能当钱算进合计
    double? coefficient;
    var effectiveAmount = amountCents;
    final isCoefficientRow = name.contains('系数') ||
        (kind == ParsedRowKind.item && _templateOf(name)?.valueType == kValueCoefficient);

    if (isCoefficientRow && kind == ParsedRowKind.item) {
      coefficient = parseCoefficient(amountText);
      // 识别出的"金额"其实是系数本身，不参与金额合计
      effectiveAmount = null;
      if (coefficient == null) {
        // 系数没解析出来（可能是 "1.2O" 或小数点丢失），保留原文交给人工
        coefficient = null;
      }
    }

    // 5) 项目名归一到模板标准名，保证跨月对比能对齐
    final canonical = kind == ParsedRowKind.item ? (_templateOf(name)?.name ?? name) : name;

    return ParsedRow(
      name: canonical.trim(),
      amountCents: effectiveAmount,
      coefficient: coefficient,
      kind: kind,
      raw: text,
      imageIndex: imageIndex,
      top: row.top,
    );
  }

  ParsedRowKind _classify(String compact, {required bool hasAmount}) {
    if (!hasAmount) return ParsedRowKind.noise; // 没有金额的行不进明细

    // 先判具体的，再判模糊的（"应发合计"同时含"应发"和"合计"）
    if (_containsAny(compact, netKeywords)) return ParsedRowKind.totalNet;
    if (_containsAny(compact, grossKeywords)) return ParsedRowKind.totalGross;
    if (_containsAny(compact, deductionKeywords)) return ParsedRowKind.totalDeduction;
    if (_containsAny(compact, noiseKeywords)) return ParsedRowKind.noise;
    if (_containsAny(compact, ambiguousTotalKeywords)) return ParsedRowKind.ambiguousTotal;
    return ParsedRowKind.item;
  }

  bool _containsAny(String text, List<String> keys) {
    for (final k in keys) {
      if (text.contains(k)) return true;
    }
    return false;
  }

  ItemTemplate? _templateOf(String rawName) {
    final n = normalizeName(rawName);
    if (n.isEmpty) return null;
    for (final t in templates) {
      if (t.matches(n)) return t;
    }
    return null;
  }

  /// 从一整行文本尾部切出金额。
  /// 返回 null 表示这行不像"名称 + 金额"。
  ({String name, int cents, String amountText})? _splitTrailingAmount(String text) {
    final m = RegExp(
      r'([\(\（\-]?\s*[¥￥]?\s*\d[\d,，]*(?:[.．]\d{1,2})?\s*[\)\）]?)\s*$',
    ).firstMatch(text);
    if (m == null) return null;

    final tail = m.group(1)!.trim();
    // 金额至少 3 个字符（如 800 / 8,00 / 80.5），避免把"10月""序号3"当金额
    if (tail.replaceAll(RegExp(r'[^\d]'), '').length < 3) return null;

    final cents = parseAmountToCents(tail);
    if (cents == null) return null;

    final namePart = text.substring(0, m.start).trim();
    if (namePart.isEmpty) return null;
    // 名称必须含中文，否则很可能是数字串被切
    if (!RegExp(r'[\u4e00-\u9fa5]').hasMatch(namePart)) return null;
    // 名称不能以日期剩余部分结尾
    if (RegExp(r'^\d{4}\s*[-/年.]?$').hasMatch(namePart)) return null;

    return (name: namePart, cents: cents, amountText: tail);
  }

  // ------------------------------------------------------- 折行项目名补救

  /// 有些工资条项目名太长会折行：「个人住房」+「公积金  800.00」。
  /// 这时带金额那行没有名称，把上一行的文字借过来。
  List<ParsedRow> _mergeWrappedNames(List<ParsedRow> rows) {
    final out = <ParsedRow>[];
    for (var i = 0; i < rows.length; i++) {
      final cur = rows[i];
      final nameLooksMissing = cur.name.trim().isEmpty ||
          RegExp(r'^[\d\.,\s\-—]+$').hasMatch(cur.name.trim());

      if (cur.kind == ParsedRowKind.item && cur.hasAmount && nameLooksMissing && i > 0) {
        final prev = rows[i - 1];
        // 上一行必须"没有金额"（否则它是独立明细，不能借用）
        if (prev.kind == ParsedRowKind.noise &&
            !prev.hasAmount &&
            prev.name.trim().isNotEmpty &&
            prev.name.trim().length <= 10) {
          if (out.isNotEmpty && identical(out.last, prev)) out.removeLast();
          out.add(cur.copyWith(name: prev.name.trim()));
          continue;
        }
      }
      out.add(cur);
    }
    return out;
  }
}
