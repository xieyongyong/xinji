import 'dart:math' as math;

import 'ocr_models.dart';

/// 把 OCR 的散装文本片段聚成「视觉行」。
///
/// 为什么需要这一步：ML Kit 只给你一堆「文字 + 矩形框」，
/// 而工资条是表格 —— 「基本工资」和「8,000.00」往往被识别成两个独立片段。
/// 必须先按 y 坐标把它们合成一行，才能知道哪个数字属于哪个项目。
class LineBuilder {
  /// [lines] 同一张图的全部文本片段
  /// 返回按从上到下排序的视觉行，每行内片段按从左到右排序
  static List<VisualRow> build(List<RawLine> lines) {
    final valid = lines.where((l) => l.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) return const [];

    // 按垂直中心排序，再逐行聚合
    valid.sort((a, b) => a.centerY.compareTo(b.centerY));

    // 容差取「中位行高」的一半多一点：既能把同一行的左右两栏并进来，
    // 又不会把相邻两行（行距通常大于行高）误并成一行。
    final heights = valid.map((e) => e.height).toList()..sort();
    final medianHeight = heights[heights.length ~/ 2];
    final tolerance = math.max(medianHeight * 0.55, 5.0);

    final rows = <VisualRow>[];
    for (final line in valid) {
      if (rows.isNotEmpty) {
        final last = rows.last;
        final cy = line.centerY;
        // 落在上一行的纵向范围内（含容差）→ 认为是同一视觉行
        if (cy >= last.top - tolerance && cy <= last.bottom + tolerance) {
          last.add(line);
          continue;
        }
      }
      rows.add(VisualRow(line));
    }

    for (final row in rows) {
      row.sortCells();
    }
    rows.sort((a, b) => a.top.compareTo(b.top));
    return rows;
  }

  /// 判断一行是否是「左边项目名 + 右边金额」的分栏结构。
  /// 判据：相邻两个片段的间距 > 平均字宽的 1.5 倍（说明中间有大量空白）。
  static bool looksLikeTwoColumns(VisualRow row) {
    if (row.cells.length < 2) return false;
    for (var i = 1; i < row.cells.length; i++) {
      final gap = row.cells[i].left - row.cells[i - 1].right;
      final avgCharWidth = row.cells[i - 1].width / math.max(row.cells[i - 1].text.length, 1);
      if (gap > avgCharWidth * 1.5) return true;
    }
    return false;
  }
}
