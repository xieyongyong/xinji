import '../core/money.dart';
import '../data/models.dart';
import 'ocr_models.dart';

/// 合并过程中的提示项
enum MergeIssueType {
  /// 相邻两张图找不到重叠内容（可能漏截了中间那段）
  noOverlap,

  /// 自动去掉了完全重复的行
  autoDeduped,

  /// 同一项目出现两个不同金额（不合并，都保留）
  sameNameConflict,

  /// 明细加总与工资条上的合计不一致
  totalMismatch,

  /// 没识别出任何明细
  empty,
}

class MergeIssue {
  final MergeIssueType type;
  final String message;
  MergeIssue(this.type, this.message);
}

/// 待入库的明细草稿
class PayItemDraft {
  String name;
  String category;
  String valueType;
  int amountCents;
  double? coefficient;

  /// 来自第几张图（0 起）
  final int? sourceImageIndex;

  PayItemDraft({
    required this.name,
    required this.category,
    this.valueType = kValueAmount,
    this.amountCents = 0,
    this.coefficient,
    this.sourceImageIndex,
  });

  bool get isIncome => category == kCategoryIncome;

  PayItem toPayItem({int? recordId, int sortOrder = 0, int? sourceImageId}) => PayItem(
        recordId: recordId,
        name: name,
        category: category,
        valueType: valueType,
        amountCents: amountCents,
        coefficient: coefficient,
        sortOrder: sortOrder,
        sourceImageId: sourceImageId,
      );
}

/// 多图合并结果
class MergeResult {
  final List<PayItemDraft> items;

  /// 被自动判定为重复而去掉的行。可以给用户看、也可以撤回。
  final List<PayItemDraft> removedDuplicates;

  final List<MergeIssue> issues;

  final int? grossCents;
  final int? deductionTotalCents;
  final int? netCents;

  /// 因识别到重叠而去掉的重复行数
  final int overlapRemovedRows;

  /// 本次是否所有图都参与了合并
  final int imageCount;

  MergeResult({
    required this.items,
    required this.removedDuplicates,
    required this.issues,
    required this.grossCents,
    required this.deductionTotalCents,
    required this.netCents,
    required this.overlapRemovedRows,
    required this.imageCount,
  });

  int get incomeSum =>
      items.where((e) => e.isIncome).fold(0, (s, e) => s + e.amountCents);

  int get deductionSum =>
      items.where((e) => !e.isIncome).fold(0, (s, e) => s + e.amountCents);

  int get netComputed => incomeSum - deductionSum;

  /// 给界面顶部显示的一句话摘要
  String get summary {
    final parts = <String>[];
    parts.add('$imageCount张图');
    parts.add('识别${items.length}项');
    final dup = removedDuplicates.length + overlapRemovedRows;
    if (dup > 0) parts.add('去重$dup行');
    return parts.join(' · ');
  }
}

/// 多图合并引擎：本项目最核心的一段逻辑。
///
/// 用户的实际场景是：工资条明细太长，一张截图放不下，
/// 于是上下滚动分几张截，相邻两张**必然有重叠区域**。
///
/// 所以不能按项目名简单去重（两笔同名奖金会被误删），
/// 而要按「行序列」找重叠：图A 的尾部 k 行 == 图B 的头部 k 行，
/// 匹配上就把这 k 行去掉。这样既不丢数据，也不会重复。
class MergeEngine {
  final List<ItemTemplate> templates;
  MergeEngine(this.templates);

  MergeResult merge(List<ParsedImage> images) {
    if (images.isEmpty) {
      return MergeResult(
        items: const [],
        removedDuplicates: const [],
        issues: [MergeIssue(MergeIssueType.empty, '没有可识别的图片')],
        grossCents: null,
        deductionTotalCents: null,
        netCents: null,
        overlapRemovedRows: 0,
        imageCount: 0,
      );
    }

    final issues = <MergeIssue>[];

    // ---- 1. 每张图拆成「明细行」和「合计行」 ----
    // 合计行不参与重叠匹配：否则每张图底部都有的"合计"会干扰序列比对
    final perImageItems = <List<ParsedRow>>[];
    final perImageTotals = <_ImageTotals>[];
    final perImageAmbiguous = <List<ParsedRow>>[];

    for (final img in images) {
      perImageItems.add(
        img.rows.where((e) => e.kind == ParsedRowKind.item && e.hasAmount).toList(),
      );
      perImageTotals.add(_ImageTotals.from(img));
      perImageAmbiguous.add(
        img.rows.where((e) => e.kind == ParsedRowKind.ambiguousTotal && e.hasAmount).toList(),
      );
    }

    // ---- 2. 逐图拼接，检测重叠 ----
    final stitched = <ParsedRow>[];
    var overlapRemoved = 0;

    if (perImageItems.isNotEmpty) stitched.addAll(perImageItems.first);

    for (var i = 1; i < perImageItems.length; i++) {
      final prev = perImageItems[i - 1];
      final next = perImageItems[i];

      final k = _detectOverlap(prev, next);

      if (k > 0) {
        overlapRemoved += k;
        if (k >= next.length) {
          // 整张图的内容都在上一张里出现过了（重复截图），整张跳过
          continue;
        }
        stitched.addAll(next.sublist(k));
        continue;
      }

      // 匹配不上：先看看是不是"弱重叠"（下一张的首行在本张里出现过）
      final weakDup = next.isNotEmpty &&
          prev.any((e) => _sameRow(e, next.first));

      if (weakDup) {
        issues.add(MergeIssue(
          MergeIssueType.noOverlap,
          '第${i}张与第${i + 1}张的重叠部分不完整（可能从一行中间切开），'
              '已按顺序拼接，请重点核对交界处两行',
        ));
      } else if (perImageItems[i].isNotEmpty && prev.isNotEmpty) {
        issues.add(MergeIssue(
          MergeIssueType.noOverlap,
          '第${i}张与第${i + 1}张之间没有识别到重叠内容，'
              '可能中间漏截了一段，请对照原图确认没有漏项',
        ));
      }

      stitched.addAll(next);
    }

    // ---- 3. 相邻同名同额 → 自动去重（可撤回） ----
    final deduped = <ParsedRow>[];
    final removedRows = <ParsedRow>[];
    for (final row in stitched) {
      if (deduped.isNotEmpty && _sameRow(deduped.last, row)) {
        removedRows.add(row);
        continue;
      }
      deduped.add(row);
    }

    // ---- 4. 合计取值：多图都有合计时做多数表决 ----
    var gross = _vote(perImageTotals.map((e) => e.gross).toList());
    var deductionTotal = _vote(perImageTotals.map((e) => e.deduction).toList());
    var net = _vote(perImageTotals.map((e) => e.net).toList());

    // ---- 5. 转草稿并判定收入/扣款 ----
    final items = deduped.map(_toDraft).toList();

    if (items.isEmpty) {
      issues.add(MergeIssue(
        MergeIssueType.empty,
        '没有识别出任何明细。可能是图片不清晰，或这行格式比较特殊，建议手动录入',
      ));
    }

    final incomeSum = items.where((e) => e.isIncome).fold(0, (s, e) => s + e.amountCents);
    final deductionSum = items.where((e) => !e.isIncome).fold(0, (s, e) => s + e.amountCents);

    // ---- 6. 模糊"合计"行的归属：用它等于哪组明细之和来判断 ----
    for (final list in perImageAmbiguous) {
      for (final row in list) {
        final v = row.amountCents!.abs();
        if (gross == null && v == incomeSum) {
          gross = v;
        } else if (deductionTotal == null && v == deductionSum) {
          deductionTotal = v;
        } else if (net == null && v == (incomeSum - deductionSum)) {
          net = v;
        }
        // 都对不上就忽略（可能是"小计"等其他含义）
      }
    }

    // ---- 7. 缺失的合计用明细算出来补上 ----
    gross ??= incomeSum;
    deductionTotal ??= deductionSum;
    net ??= gross - deductionTotal;

    // ---- 8. 冲突检测：同名不同额 ----
    final byName = <String, List<PayItemDraft>>{};
    for (final it in items) {
      byName.putIfAbsent(normalizeName(it.name), () => []).add(it);
    }
    byName.forEach((key, list) {
      if (list.length < 2) return;
      final distinct = list.map((e) => e.amountCents).toSet();
      if (distinct.length > 1) {
        final amounts = list.map((e) => formatCents(e.amountCents)).join(' / ');
        issues.add(MergeIssue(
          MergeIssueType.sameNameConflict,
          '「${list.first.name}」出现多个金额（$amounts），已全部保留，请确认是否有多笔或识别错误',
        ));
      }
    });

    // ---- 9. 合计校验（发现漏行/多行的最强信号）----
    if (gross != null && (incomeSum - gross).abs() > 1) {
      issues.add(MergeIssue(
        MergeIssueType.totalMismatch,
        '收入明细合计 ${formatCents(incomeSum)}，与工资条应发合计 ${formatCents(gross)} '
            '相差 ${formatCents((incomeSum - gross).abs())}，可能有漏识别或重复项',
      ));
    }
    if (net != null && (incomeSum - deductionSum - net).abs() > 1) {
      issues.add(MergeIssue(
        MergeIssueType.totalMismatch,
        '应发减代扣 = ${formatCents(incomeSum - deductionSum)}，'
            '与工资条实发 ${formatCents(net)} 不一致，请核对代扣项',
      ));
    }

    if (removedRows.isNotEmpty) {
      issues.add(MergeIssue(
        MergeIssueType.autoDeduped,
        '已自动去除 ${removedRows.length} 行完全重复的记录（同名同金额相邻），可在下方撤回',
      ));
    }

    return MergeResult(
      items: items,
      removedDuplicates: removedRows.map(_toDraft).toList(),
      issues: issues,
      grossCents: gross,
      deductionTotalCents: deductionTotal,
      netCents: net,
      overlapRemovedRows: overlapRemoved,
      imageCount: images.length,
    );
  }

  /// 一行解析结果 -> 待入库草稿（统一的转换逻辑，去重与正式明细共用）
  PayItemDraft _toDraft(ParsedRow row) {
    final tpl = _templateOf(row.name);
    final isCoefficient = row.coefficient != null || tpl?.valueType == kValueCoefficient;
    return PayItemDraft(
      name: (tpl?.name ?? row.name).trim(),
      category: tpl?.category ?? _guessCategory(row.name),
      valueType: isCoefficient ? kValueCoefficient : kValueAmount,
      // 扣款项统一存正数（金额大小），显示时前面加负号：
      // 这样"应发 - 代扣 = 实发"的校验逻辑最简单，不会被正负号绕晕
      amountCents: isCoefficient ? 0 : (row.amountCents ?? 0).abs(),
      coefficient: row.coefficient,
      sourceImageIndex: row.imageIndex,
    );
  }

  // ------------------------------------------------------------ 重叠检测

  /// 返回「上一张图的末尾」与「下一张图的开头」重合的行数。
  /// 返回 0 表示没找到重叠。
  int _detectOverlap(List<ParsedRow> prev, List<ParsedRow> next) {
    if (prev.isEmpty || next.isEmpty) return 0;

    // 最多比 30 行：工资条一屏通常不超过这个数，比太多没意义还慢
    final maxK = prev.length < next.length ? prev.length : next.length;
    final limit = maxK > 30 ? 30 : maxK;

    // 从最多的重叠开始试，第一个匹配上的就是最长重叠
    for (var k = limit; k >= 1; k--) {
      final tail = prev.sublist(prev.length - k);
      final head = next.sublist(0, k);
      var allSame = true;
      for (var i = 0; i < k; i++) {
        if (!_sameRow(tail[i], head[i])) {
          allSame = false;
          break;
        }
      }
      if (allSame) return k;
    }
    return 0;
  }

  /// 两行是否「同一条记录」：项目名归一后相同，且金额相差不超过 1 分
  bool _sameRow(ParsedRow a, ParsedRow b) {
    if (normalizeName(a.name) != normalizeName(b.name)) return false;
    final x = a.amountCents;
    final y = b.amountCents;
    if (x == null || y == null) return x == y;
    return (x - y).abs() <= 1;
  }

  /// 多数表决：多张图都识别出合计时，取出现次数最多的值；
  /// 并列时取最后出现的（通常是最下面那张图，更完整）
  int? _vote(List<int?> values) {
    final nonNull = values.whereType<int>().toList();
    if (nonNull.isEmpty) return null;
    final freq = <int, int>{};
    for (final v in nonNull) {
      freq[v] = (freq[v] ?? 0) + 1;
    }
    var best = nonNull.last;
    var bestCount = 0;
    freq.forEach((value, count) {
      if (count > bestCount || (count == bestCount && value == nonNull.last)) {
        best = value;
        bestCount = count;
      }
    });
    return best;
  }

  ItemTemplate? _templateOf(String name) {
    final n = normalizeName(name);
    if (n.isEmpty) return null;
    for (final t in templates) {
      if (t.matches(n)) return t;
    }
    return null;
  }

  /// 模板没匹配上时，用关键词猜是收入还是扣款
  String _guessCategory(String name) {
    const deductionWords = [
      '社保', '社会保险', '公积金', '所得税', '个税', '个人所得税', '扣款', '扣除',
      '代扣', '水电', '管理费', '罚款', '借款', '养老', '医疗', '失业', '工伤',
      '补充养老', '企业年金', '食宿', '住宿费', '押金',
    ];
    for (final w in deductionWords) {
      if (name.contains(w)) return kCategoryDeduction;
    }
    return kCategoryIncome;
  }
}

/// 从一张图里抽出的合计值
class _ImageTotals {
  final int? gross;
  final int? deduction;
  final int? net;

  _ImageTotals({this.gross, this.deduction, this.net});

  factory _ImageTotals.from(ParsedImage img) {
    int? pick(ParsedRowKind kind) {
      for (final r in img.rows) {
        if (r.kind == kind && r.amountCents != null) return r.amountCents!.abs();
      }
      return null;
    }

    return _ImageTotals(
      gross: pick(ParsedRowKind.totalGross),
      deduction: pick(ParsedRowKind.totalDeduction),
      net: pick(ParsedRowKind.totalNet),
    );
  }
}
