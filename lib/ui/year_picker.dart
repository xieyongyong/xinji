import 'package:flutter/material.dart';

import '../core/money.dart';
import 'theme.dart';

/// 年份选择的结果。
///
/// 用包装类而不是直接返回 `int?`：`null` 已经被"用户取消"占用了，
/// 而统计页的「全部年份」也需要一个值表示，两者不能混成一个 null。
class YearPick {
  const YearPick(this.year);

  /// null = 全部年份
  final int? year;
}

/// 底部弹窗选年份，和对比页选月份同一套手感：
/// 一屏铺开、每格带该年实发、当前项高亮，不用去滚下拉列表。
Future<YearPick?> showYearPicker(
  BuildContext context, {
  required List<int> years,
  int? initial,

  /// 是否提供「全部年份」（统计页的总计范围用）
  bool allowAll = false,

  /// 每年实发合计（分），做副标题。打码开关生效时自动显示星号。
  Map<int, int>? netByYear,
  String title = '选择年份',
}) {
  final sorted = [...years]..sort((a, b) => b.compareTo(a));

  return showModalBottomSheet<YearPick>(
    context: context,
    showDragHandle: true,
    backgroundColor: kSurface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (allowAll) ...[
              _allTile(ctx, initial == null),
              const SizedBox(height: 10),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
                children: [
                  for (final y in sorted)
                    _yearCell(ctx, y, y == initial, netByYear?[y]),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _yearCell(BuildContext sheetCtx, int year, bool selected, int? net) {
  return InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: () => Navigator.pop(sheetCtx, YearPick(year)),
    child: Container(
      decoration: BoxDecoration(
        color: selected ? kInfoBg : kSurfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? kSeed : Colors.transparent),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$year 年',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: selected ? kTextPrimary : kTextMedium,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            net == null ? '—' : displayCents(net),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: kTextHint),
          ),
        ],
      ),
    ),
  );
}

Widget _allTile(BuildContext sheetCtx, bool selected) {
  return InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: () => Navigator.pop(sheetCtx, const YearPick(null)),
    child: Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? kInfoBg : kSurfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? kSeed : Colors.transparent),
      ),
      child: Row(
        children: [
          Icon(Icons.all_inclusive,
              size: 18, color: selected ? kSeed : kTextMedium),
          const SizedBox(width: 8),
          Text(
            '全部年份',
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? kTextPrimary : kTextMedium,
            ),
          ),
          const Spacer(),
          if (selected) Icon(Icons.check, size: 16, color: kSeed),
        ],
      ),
    ),
  );
}
