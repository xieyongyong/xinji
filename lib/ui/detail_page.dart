import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../data/item_order.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'compare_page.dart';
import 'review_page.dart';
import 'theme.dart';
import 'widgets/image_viewer.dart';

/// 单条记录详情
class DetailPage extends StatelessWidget {
  final int recordId;

  const DetailPage({super.key, required this.recordId});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final record = state.recordById(recordId);

    if (record == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('记录详情')),
        body: Center(
          child: Text('这条记录已被删除', style: TextStyle(color: kTextSecondary)),
        ),
      );
    }

    // 顺序统一按这家雇主**当前生效模板**的字段顺序排，而不是只信库里的 sort_order。
    // 为什么两者都要：sort_order 保证"录入时怎么排就怎么存"，
    // 这里再按模板排一次，是为了让升级前录入的老记录、以及后来调整过模板的记录
    // 也和最近几个月的顺序对齐 —— 用户看到的永远是同一套顺序。
    // 按记录自己的类型取模板：奖金记录用奖金模板的顺序，不被月度模板重排
    final tpl = state.activeTemplateFor(record.employerId, appliesTo: record.recordType);
    final incomes =
        orderItemsByTemplate(record.items.where((e) => e.isIncome).toList(), tpl);
    final deductions =
        orderItemsByTemplate(record.items.where((e) => e.isDeduction).toList(), tpl);
    final infos = orderInfosByTemplate(record.infos, tpl);
    final incomeSum = incomes
        .where((e) => e.countsInTotal)
        .fold(0, (s, e) => s + e.amountCents);
    final deductionSum =
        deductions.where((e) => e.countsInTotal).fold(0, (s, e) => s + e.amountCents);
    final note = record.extra?['note'];
    return Scaffold(
      appBar: AppBar(
        title: Text('${record.periodYear}年${record.periodMonth}月'),
        bottom: state.employerById(record.employerId) == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    state.employerById(record.employerId)!.name,
                    style: TextStyle(fontSize: 11.5, color: kTextSecondary),
                  ),
                ),
              ),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReviewPage.edit(record: record)),
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'compare') {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ComparePage(
                    year: record.periodYear,
                    focusMonth: record.periodMonth,
                  ),
                ));
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除这条记录？'),
                    content: Text(
                      '${record.displayTitle} 的所有明细和原图都会被删除，无法恢复。',
                      style: const TextStyle(height: 1.6, fontSize: 14),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: TextButton.styleFrom(foregroundColor: kUp),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await state.deleteRecord(record.id!);
                  if (context.mounted) Navigator.of(context).pop();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'compare', child: Text('与其它月份对比')),
              PopupMenuItem(value: 'delete', child: Text('删除记录')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _headerCard(record),
          const SizedBox(height: 14),
          if (incomes.isNotEmpty)
            _itemsCard(
              title: '收入明细',
              color: kIncome,
              items: incomes,
              sum: incomeSum,
              sumLabel: '应发合计',
            ),
          if (incomes.isNotEmpty) const SizedBox(height: 14),
          if (deductions.isNotEmpty)
            _itemsCard(
              title: '扣款明细',
              color: kDeduction,
              items: deductions,
              sum: deductionSum,
              sumLabel: '代扣合计',
              negative: true,
            ),
          if (deductions.isNotEmpty) const SizedBox(height: 14),
          if (record.infos.isNotEmpty) ...[
            _infosCard(infos),
            const SizedBox(height: 14),
          ],
          if (record.images.isNotEmpty) _imagesCard(context, record),
          if (note is String && note.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: cardDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('备注',
                      style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
                  const SizedBox(height: 6),
                  Text(note, style: const TextStyle(fontSize: 13.5, height: 1.6)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ComparePage(
                  year: record.periodYear,
                  focusMonth: record.periodMonth,
                ),
              ));
            },
            icon: const Icon(Icons.compare_arrows, size: 18),
            label: const Text('与其它月份对比'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(PayRecord r) {
    final isExtra = r.recordType == kTypeExtra;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: isExtra ? kExtra : kSeed,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isExtra ? (r.recordLabel ?? '额外收入') : '${r.periodMonth}月工资',
                style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.85)),
              ),
              const Spacer(),
              if (r.images.isNotEmpty)
                Row(
                  children: [
                    Icon(Icons.image_outlined,
                        size: 13, color: Colors.white.withOpacity(0.7)),
                    const SizedBox(width: 3),
                    Text('${r.images.length}',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.white.withOpacity(0.7))),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            displayCents(r.netCents),
            style: moneyStyle(size: 32, color: Colors.white),
          ),
          const SizedBox(height: 2),
          Text('实发',
              style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.7))),
          const SizedBox(height: 14),
          Row(
            children: [
              _miniStat('应发', displayCents(r.grossCents)),
              const SizedBox(width: 22),
              _miniStat('代扣', displayCents(r.deductionCents)),
            ],
          ),
          // 记录这条是什么时候、以什么方式进来的（老数据 migration 用 created_at 回填）
          if (_timeLine(r).isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _timeLine(r),
              style: TextStyle(fontSize: 10.5, color: Colors.white.withOpacity(0.6)),
            ),
          ],
        ],
      ),
    );
  }

  /// 「导入/录入时间 + 来源」一行小字
  String _timeLine(PayRecord r) {
    final t = r.importedAt;
    if (t == null || t <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final d = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final verb = r.source == kSourceImport ? '图片识别导入' : '手动录入';
    // 编辑过就补一句"已编辑"，让人分清导入时间和最后修改
    final edited = r.updatedAt > t + 60 * 1000 ? ' · 之后有修改' : '';
    return '$d · $verb$edited';
  }

  Widget _miniStat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 10.5, color: Colors.white.withOpacity(0.65))),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                fontSize: 13.5,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              )),
        ],
      );

  Widget _itemsCard({
    required String title,
    required Color color,
    required List<PayItem> items,
    required int sum,
    required String sumLabel,
    bool negative = false,
  }) {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 9),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration:
                      BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8.5),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(item.name,
                              style: TextStyle(
                                  fontSize: 13.5, color: kTextBody)),
                        ),
                        if (item.isDerived)
                          Container(
                            margin: const EdgeInsets.only(left: 5),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: kSurfaceAlt,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('推算',
                                style: TextStyle(
                                    fontSize: 9.5, color: kTextSecondary)),
                          ),
                      ],
                    ),
                  ),
                  if (item.isCoefficient)
                    Text(
                      item.coefficient == null
                          ? '—'
                          : '× ${item.coefficient!.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: item.coefficient == null ? kTextHint : kSeed,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  else
                    Text(
                      displayCents(negative ? -item.amountCents : item.amountCents),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: item.isDerived ? FontWeight.w400 : FontWeight.w500,
                        color: item.isDerived
                            ? kTextSecondary
                            : (negative ? kDeduction : kTextPrimary),
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 13),
            child: Row(
              children: [
                Text(sumLabel,
                    style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
                const Spacer(),
                Text(
                  displayCents(negative ? -sum : sum),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 信息项：姓名、工号、业务单位、应出勤天数…不参与合计
  Widget _infosCard(List<PayInfo> infos) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 8),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 13,
                decoration: BoxDecoration(
                    color: kTextHint, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              const Text('信息项',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('不计入合计',
                  style: TextStyle(fontSize: 11, color: kTextHint)),
            ],
          ),
          const SizedBox(height: 6),
          for (final info in infos)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(info.name,
                        style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      info.value.isEmpty ? '—' : info.value,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: kTextPrimary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _imagesCard(BuildContext context, PayRecord r) {
    final paths = r.images.map((e) => e.filePath).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('原始工资条（${paths.length} 张）',
              style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
          const SizedBox(height: 10),
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: paths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ImageViewerPage(paths: paths, initial: i),
                )),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(paths[i]),
                    width: 60,
                    height: 80,
                    // 长截图原图可能上千万像素，缩略图必须限制解码尺寸，
                    // 否则一屏几个缩略图就把内存吃满了
                    cacheWidth: 240,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 60,
                      height: 80,
                      color: kBorder,
                      child: Icon(Icons.broken_image_outlined,
                          size: 18, color: kTextHint),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
