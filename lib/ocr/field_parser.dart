import '../core/money.dart';
import '../data/models.dart';
import 'line_builder.dart';
import 'ocr_models.dart';

/// 把「视觉行」解析成「项目名 + 值」，并判定每行是明细、合计、信息项还是噪声。
///
/// 这里的所有规则都是为了应对真实工资条截图的脏数据：
/// 表头、姓名工号、说明文字、折行的项目名、只写"合计"不写是哪项合计、
/// 以及**看着像钱其实不是钱**的行（出勤天数、加班时数、薪级对应基薪）。
///
/// 真实样例（2025年06月，奔图电子）：
/// ```
/// 部门      产品开发技术支持部      ← 信息项
/// 工号      199438               ← 信息项（早年版本会当成 ¥1,994.38 收入）
/// 薪级对应基薪 8300               ← 信息项（会被当成 ¥83.00 收入）
/// 基本工资   2080                 ← 收入
/// 本月绩效系数 1.1                ← 系数，不是钱
/// 实发绩效工资 1826               ← 收入（但含"实发"，早年会被当成实发合计）
/// 平时加班时数 27.5               ← 信息项（会被当成 ¥27.50 收入）
/// 工龄工资   50                   ← 收入（只有两位数字，早年会被丢掉）
/// 应扣小计   2089                 ← 代扣合计（早年不认识"应扣"）
/// ```
class FieldParser {
  final List<ItemTemplate> templates;

  FieldParser(this.templates);

  // ---------------------------------------------------------------- 词表

  /// 实发合计（"实发绩效工资"这类项目必须先被模板拦住，见 _classify）
  static const List<String> netKeywords = [
    '实发工资', '实发合计', '实发金额', '实发数', '实发额',
    '到手工资', '到手', '税后工资',
  ];

  static const List<String> grossKeywords = [
    '应发工资', '应发合计', '应发金额', '应发数', '应发小计', '应发额',
    '税前合计', '工资总额', '总应发',
  ];

  static const List<String> deductionKeywords = [
    '代扣合计', '扣款合计', '扣除合计', '代扣小计', '扣款小计', '扣款总额',
    '应扣小计', '应扣合计', '应扣总额', '扣除总额',
    '个人承担合计', '个人缴纳合计', '扣除项合计', '代扣款项合计',
  ];

  /// 带这些字的行不可能是"合计"，只可能是项目（防止"实发绩效工资"被当成实发合计）
  static const List<String> itemGuardWords = ['绩效', '奖金', '津贴', '补贴', '加班', '提成'];

  static const List<String> ambiguousTotalKeywords = ['合计', '总计', '小计', '总额', '共计'];

  /// 命中即视为噪声（表头、身份信息、说明）。注意不要放"岗位""工资"这类宽泛词，
  /// 否则会把"岗位津贴""绩效工资"误杀。
  static const List<String> noiseKeywords = [
    '姓名', '工号', '员工编号', '员工号', '身份证', '部门', '车间', '班组', '科室',
    '职位', '职务', '入职', '制表', '制单', '审核', '批准', '复核', '签字', '签名',
    '确认', '核对', '备注', '说明', '声明', '序号', '编号', '发放日期', '发放时间',
    '工资条', '工资单', '温馨提示', '如有疑问', '本表', '以上', '单位名称', '公司名称',
    '本月应发', '本月实发', '提示', '薪资',
  ];

  /// 信息项关键字（**按长度从长到短匹配**，否则"薪级"会把"薪级对应基薪"切坏）
  static const List<String> infoKeywords = [
    '薪级对应基薪', '正常出勤天数', '实际出勤天数', '应出勤天数',
    '平时加班时数', '休息日加班时数', '节假日加班时数', '加班时长',
    '员工编号', '员工号', '员工类别', '成本中心', '岗位名称', '银行账号',
    '开户行', '发薪日期', '入职日期', '入职时间', '计税月份',
    '姓名', '工号', '部门', '业务单位', '事业部', '科室', '班组',
    '职位', '职务', '职级', '薪级', '学历', '身份证',
  ];

  /// 以这些词结尾的，一定是"量"不是"钱"
  static const List<String> infoSuffixes = [
    '天数', '时数', '小时数', '小时', '时长', '系数', '基薪',
    '评分', '分值', '次数', '个数', '比例',
  ];

  /// 识别出来的叫法 → 统一叫法（跟默认发薪模板对齐，避免同一个月出现两行）
  static const Map<String, String> infoAliases = {
    '正常出勤天数': '应出勤天数',
    '实际出勤天数': '实出勤天数',
  };

  /// 按长度倒序的关键字表，保证"薪级对应基薪"优先于"薪级"
  static final List<String> _infoKeywordsByLength = [...infoKeywords]
    ..sort((a, b) => b.length.compareTo(a.length));

  // ---------------------------------------------------------------- 解析一张图

  /// 解析一张图
  ParsedImage parseImage({
    required int index,
    required String filePath,
    required List<RawLine> lines,
    required String rawText,
  }) {
    final visualRows = LineBuilder.build(lines);
    final skip = _watermarkTexts(visualRows);
    final fragments = _watermarkFragments(skip);
    final ctx = _ColumnContext.of(visualRows, skip);
    final rows = <ParsedRow>[];
    for (final vr in visualRows) {
      final row = _parseRow(vr, index, ctx, skip, fragments);
      if (row != null) rows.add(row);
    }
    return ParsedImage(
      index: index,
      filePath: filePath,
      rows: _mergeWrappedNames(rows),
      rawText: rawText,
    );
  }

  /// 找出「水印文字」：同一段文字在一张图里重复出现多次。
  ///
  /// 真实场景：企业工资条截图上铺满了浅灰色的"安心工资条 1279"水印，
  /// OCR 会把它们当正文抓出来，夹在"部门"和"产品开发技术支持部"中间，
  /// 于是部门名变成"1279产品开发技术支持部"、金额列变成 1279。
  /// 正常工资条的项目名/金额一个月只会出现一次，重复多次的基本就是水印。
  ///
  /// 注：像素层的浅灰水印已经由原生 `TileCleaner` 在识别前刷白了，
  /// 这里兜的是「水印比纸面深、刷不掉」以及「水印和正文黏成一串」的情况。
  Set<String> _watermarkTexts(List<VisualRow> rows) {
    // 同一串文字重复这么多次 → 判定为水印
    const sameTextTimes = 3;
    // 5 个字以上的长串只要重复两次就够了：真实项目名不会一模一样出现两回
    const sameLongTextTimes = 2;

    final freq = <String, int>{};
    final raw = <String, List<String>>{};
    for (final row in rows) {
      for (final c in row.cells) {
        final t = c.text.trim();
        if (t.length < 3) continue;
        // 归一化再计数："安心工资条 1279" 和 "安心工资条1279" 要算同一串，
        // 否则 OCR 多认/少认一个空格就漏过去了。
        final key = _watermarkKey(t);
        if (!_couldBeWatermark(t, key)) continue;
        freq[key] = (freq[key] ?? 0) + 1;
        (raw[key] ??= <String>[]).add(t);
      }
    }

    final out = <String>{};
    for (final e in freq.entries) {
      final key = e.key;
      final hit = e.value >= sameTextTimes ||
          (key.length >= 5 && e.value >= sameLongTextTimes);
      if (hit) out.addAll(raw[key]!);
    }
    return out;
  }

  /// 计数的归一化键：去掉空白和标点，只留字与数字
  String _watermarkKey(String text) =>
      text.replaceAll(RegExp(r'[\s:：,，.。、\-—_｜|/\\()（）\[\]【】]'), '');

  /// 只有「不像钱」的文字才可能是水印。
  ///
  /// 带小数点的金额（0.00 / 1,826.50）重复出现是正常的（好几项都是 0.00），
  /// 不能当水印丢掉；而水印里的编号（1279）是不带小数点的整数，
  /// 用这一条既保住了零金额行，又留住了编号水印。
  ///
  /// 注意必须拿**原文**判断：归一化时已经把小数点去掉了。
  bool _couldBeWatermark(String rawText, String key) {
    if (key.isEmpty) return false;
    if (RegExp(r'\d[.,]\d').hasMatch(rawText)) return false;
    return true;
  }

  /// 水印碎片：整串水印里切出来的、够长够独特的片段。
  ///
  /// 用途是把「1279产品开发技术支持部」这种「水印 + 正文黏成一个文本框」
  /// 的名字还原成「产品开发技术支持部」—— 黏起来以后整串不会重复，
  /// 上面按整串去重的规则就完全失效了。
  Set<String> _watermarkFragments(Set<String> cells) {
    final out = <String>{};
    for (final cell in cells) {
      final compact = cell.replaceAll(RegExp(r'\s+'), '');
      if (compact.length >= 3) out.add(compact);
      for (final m in RegExp(r'[\u4e00-\u9fa5]{2,}').allMatches(compact)) {
        out.add(m.group(0)!);
      }
      for (final m in RegExp(r'\d{3,}').allMatches(compact)) {
        out.add(m.group(0)!);
      }
    }
    out.removeWhere((e) => e.isEmpty);
    return out;
  }

  /// 从名字的**两端**剥掉水印碎片（中间不动，那里可能是真实内容）
  String _trimWatermarkFragments(String name, Set<String> fragments) {
    if (fragments.isEmpty) return name;
    var s = name.trim();
    var changed = true;
    while (changed && s.isNotEmpty) {
      changed = false;
      for (final f in fragments) {
        if (f.isEmpty) continue;
        if (s.startsWith(f)) {
          s = s.substring(f.length).trim();
          changed = true;
          break;
        }
        if (s.endsWith(f)) {
          s = s.substring(0, s.length - f.length).trim();
          changed = true;
          break;
        }
      }
    }
    return s;
  }

  // ---------------------------------------------------------------- 单行解析

  ParsedRow? _parseRow(
    VisualRow row,
    int imageIndex,
    _ColumnContext ctx,
    Set<String> skip,
    Set<String> fragments,
  ) {
    final cells = row.cells.where((c) => !skip.contains(c.text.trim())).toList();
    if (cells.isEmpty) return null;

    final text = cells.map((e) => e.text.trim()).where((e) => e.isNotEmpty).join(' ');
    if (text.isEmpty) return null;

    final compact = text.replaceAll(RegExp(r'\s+'), '');

    // 年月标题行（如 "2026年10月薪资" / "2026-10"）：会被误认成金额，先拦掉
    if (RegExp(r'^\d{4}\s*[-/年.]\s*\d{1,2}\s*月?').hasMatch(compact)) {
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

    for (var i = cells.length - 1; i >= 0; i--) {
      final cellText = cells[i].text.trim();
      final strict = looksLikeAmount(cellText);
      // 两位数的金额（工龄工资 50、水电费 77）单独看不出来，
      // 只有"右边界跟其它金额列对齐、且在第一笔金额下方"时才认
      final weak = !strict && _weakAmountCell(cells[i], row, ctx);
      if (!strict && !weak) continue;
      final v = parseAmountToCents(cellText);
      if (v == null) continue;
      amountCents = v;
      amountText = cellText;
      amountCellIndex = i;
      break;
    }

    // 2) 名称：金额列左边的全部片段
    var name = '';
    if (amountCellIndex > 0) {
      name = cells
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

    // 水印和正文黏在一个文本框里（"1279产品开发技术支持部"）时，
    // 整串去重规则救不了，只能把两端的碎片剥掉。
    // 万一剥空了（碎片恰好是整行名字），退回原文，绝不因此丢行。
    var rawName = _trimWatermarkFragments(name, fragments);
    if (rawName.isEmpty) rawName = name.trim();
    if (rawName.isEmpty) rawName = text;
    final label = normalizeName(rawName);

    // 3) 系数行（绩效系数 1.20）：不能当钱算进合计。
    //    必须排在信息项判定之前 —— 系数后缀也在信息项后缀表里。
    final tpl = _templateOf(rawName);
    final isCoefficientRow =
        rawName.contains('系数') || tpl?.valueType == kValueCoefficient;

    if (isCoefficientRow && amountCents != null) {
      final coef = parseCoefficient(amountText);
      return ParsedRow(
        name: (tpl?.name ?? rawName).trim(),
        coefficient: coef,
        // 识别出的"金额"其实是系数本身，不参与金额合计
        amountCents: null,
        kind: ParsedRowKind.item,
        raw: text,
        imageIndex: imageIndex,
        top: row.top,
      );
    }

    // 4) 信息项：有值但不是钱（姓名/工号/部门/基薪/天数/时数…）
    final infoLabel = _matchInfoLabel(rawName);
    if (infoLabel != null) {
      return ParsedRow(
        name: infoLabel,
        infoValue: _infoValue(compact),
        kind: ParsedRowKind.info,
        raw: text,
        imageIndex: imageIndex,
        top: row.top,
      );
    }

    // 5) 定类型
    final kind = _classify(label, hasAmount: amountCents != null);

    // 6) 项目名归一到模板标准名，保证跨月对比能对齐
    var canonical = rawName;
    if (kind == ParsedRowKind.item) {
      final hit = tpl ?? _templateOf(_stripTotalSuffix(label) ?? '');
      canonical = hit?.name ?? label;
    }

    return ParsedRow(
      name: canonical.trim(),
      amountCents: amountCents,
      kind: kind,
      raw: text,
      imageIndex: imageIndex,
      top: row.top,
    );
  }

  // ---------------------------------------------------------------- 分类

  ParsedRowKind _classify(String label, {required bool hasAmount}) {
    if (!hasAmount) return ParsedRowKind.noise; // 没有金额的行不进明细

    // 0) 命中已知项目 → 一定是明细。
    //    模板是用户确认过的项目清单，优先于关键词：
    //    否则"实发绩效工资"会被"实发"误判成实发合计（金额差 6000+）。
    if (_templateOf(label) != null) return ParsedRowKind.item;

    // 1) "加班工资总额"这类：去掉末尾合计字样后仍能对上已知项目 → 明细
    final stripped = _stripTotalSuffix(label);
    if (stripped != null && _templateOf(stripped) != null) return ParsedRowKind.item;

    // 2) 先判具体的，再判模糊的（"应发小计"同时含"应发"和"小计"）
    if (_looksLikeNet(label)) return ParsedRowKind.totalNet;
    if (_looksLikeGross(label)) return ParsedRowKind.totalGross;
    if (_containsAny(label, deductionKeywords)) return ParsedRowKind.totalDeduction;
    if (_containsAny(label, noiseKeywords)) return ParsedRowKind.noise;
    if (_containsAny(label, ambiguousTotalKeywords)) {
      return ParsedRowKind.ambiguousTotal;
    }
    return ParsedRowKind.item;
  }

  /// "实发" 只有在**不是**某个具体项目（绩效/奖金/津贴）时才算实发合计
  bool _looksLikeNet(String label) {
    if (_containsAny(label, itemGuardWords)) return false;
    if (label == '实发') return true;
    return _containsAny(label, netKeywords);
  }

  bool _looksLikeGross(String label) {
    if (_containsAny(label, itemGuardWords)) return false;
    if (label == '应发') return true;
    return _containsAny(label, grossKeywords);
  }

  bool _containsAny(String text, List<String> keys) {
    for (final k in keys) {
      if (text.contains(k)) return true;
    }
    return false;
  }

  String? _stripTotalSuffix(String label) {
    for (final s in ambiguousTotalKeywords) {
      if (label.length > s.length + 1 && label.endsWith(s)) {
        return label.substring(0, label.length - s.length);
      }
    }
    return null;
  }

  ItemTemplate? _templateOf(String rawName) {
    final n = normalizeName(rawName);
    if (n.isEmpty) return null;
    for (final t in templates) {
      if (t.matches(n)) return t;
    }
    return null;
  }

  // ---------------------------------------------------------------- 信息项

  /// 返回统一后的信息项名称；不是信息项返回 null
  String? _matchInfoLabel(String rawName) {
    final label = normalizeName(rawName);
    if (label.isEmpty) return null;
    // 已知项目（如"绩效系数"）优先，别被后缀规则抢走
    if (_templateOf(label) != null) return null;

    for (final k in _infoKeywordsByLength) {
      if (label.contains(k)) {
        return infoAliases[k] ?? k;
      }
    }
    for (final s in infoSuffixes) {
      if (label.endsWith(s)) return label;
    }
    return null;
  }

  /// 信息项的值：把标签从整行文本里切掉，剩下的就是值
  String _infoValue(String compact) {
    // 用最长的、真的出现在行里的关键字来切，避免"薪级"把"薪级对应基薪"切坏
    for (final k in _infoKeywordsByLength) {
      final at = compact.indexOf(k);
      if (at < 0) continue;
      var v = compact.substring(at + k.length);
      v = v.replaceFirst(RegExp(r'^[：:\-—_]+'), '');
      // "加班时长(小时)" 这种小节标题，切掉标签只剩个单位，不算值
      v = v.replaceFirst(RegExp(r'^[\(（][^\)）]*[\)）]$'), '');
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  // ---------------------------------------------------------------- 弱金额

  /// 两位数金额（50 / 77 / 52）的判定。
  ///
  /// 单看"50"根本分不清是金额还是序号，但真工资条有两个强特征：
  /// 1. 金额列右对齐 → 右边界和其它金额几乎在同一条竖线上；
  /// 2. 金额在表格里 → 不会出现在第一笔明确金额之前（那里是标题、状态栏电量）。
  bool _weakAmountCell(RawLine cell, VisualRow row, _ColumnContext ctx) {
    final t = cell.text.trim();
    if (!RegExp(r'^\d{1,2}$').hasMatch(t)) return false;
    final right = ctx.amountRight;
    if (right == null) return false;
    if ((cell.right - right).abs() > 26) return false;
    final firstTop = ctx.firstStrictTop;
    if (firstTop != null && row.top < firstTop - 8) return false;
    return true;
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
        // 上一行必须"没有金额"（否则它是独立明细，不能借用），
        // 而且不能是"2025年06月薪资"这类标题 —— 否则顶部那个大号实发数字
        // 会被挂到标题上，凭空多出一笔收入。
        if (prev.kind == ParsedRowKind.noise &&
            !prev.hasAmount &&
            prev.name.trim().isNotEmpty &&
            prev.name.trim().length <= 10 &&
            !_looksLikeTitleText(prev.name)) {
          if (out.isNotEmpty && identical(out.last, prev)) out.removeLast();
          out.add(cur.copyWith(name: prev.name.trim()));
          continue;
        }
      }

      // 名字实在补不上的孤立数字，丢掉比留个"（未命名）"更安全
      if (cur.kind == ParsedRowKind.item && cur.hasAmount && nameLooksMissing) {
        continue;
      }
      out.add(cur);
    }
    return out;
  }

  bool _looksLikeTitleText(String s) {
    if (s.contains('薪资') || s.contains('工资条') || s.contains('月份')) return true;
    return RegExp(r'\d{4}\s*年').hasMatch(s) || RegExp(r'^\d{1,2}\s*月').hasMatch(s);
  }
}

/// 一张图的「金额列」上下文：右边界与第一笔明确金额的位置。
///
/// 有了它，两位数的金额才敢认；没有它就只能保守丢弃。
class _ColumnContext {
  final double? amountRight;
  final double? firstStrictTop;

  const _ColumnContext(this.amountRight, this.firstStrictTop);

  factory _ColumnContext.of(List<VisualRow> rows, Set<String> skip) {
    final rights = <double>[];
    double? firstTop;
    for (final row in rows) {
      for (final cell in row.cells) {
        final t = cell.text.trim();
        if (t.isEmpty || skip.contains(t)) continue;
        if (looksLikeAmount(t)) {
          rights.add(cell.right);
          firstTop ??= row.top;
        }
      }
    }
    if (rights.isEmpty) return const _ColumnContext(null, null);
    rights.sort();
    return _ColumnContext(rights[rights.length ~/ 2], firstTop);
  }
}
