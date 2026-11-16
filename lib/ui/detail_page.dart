import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
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
        body: const Center(
          child: Text('这条记录已被删除', style: TextStyle(color: Color(0xFF8A8F8A))),
        ),
      );
    }

    final incomes = record.items.where((e) => e.isIncome).toList();
    final deductions = record.items.where((e) => e.isDeduction).toList();
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
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A)),
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
            _infosCard(record),
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
                  const Text('备注',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
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
        color: isExtra ? const Color(0xFF7A4B12) : kSeed,
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
            formatCents(r.netCents),
            style: moneyStyle(size: 32, color: Colors.white),
          ),
          const SizedBox(height: 2),
          Text('实发',
              style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.7))),
          const SizedBox(height: 14),
          Row(
            children: [
              _miniStat('应发', formatCents(r.grossCents)),
              const SizedBox(width: 22),
              _miniStat('代扣', formatCents(r.deductionCents)),
            ],
          ),
        ],
      ),
    );
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
                              style: const TextStyle(
                                  fontSize: 13.5, color: Color(0xFF3A3F3A))),
                        ),
                        if (item.isDerived)
                          Container(
                            margin: const EdgeInsets.only(left: 5),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF2F4F2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('推算',
                                style: TextStyle(
                                    fontSize: 9.5, color: Color(0xFF8A8F8A))),
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
                        color: item.coefficient == null ? const Color(0xFFB0B5B0) : kSeed,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  else
                    Text(
                      formatCents(negative ? -item.amountCents : item.amountCents),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: item.isDerived ? FontWeight.w400 : FontWeight.w500,
                        color: item.isDerived
                            ? const Color(0xFF8A8F8A)
                            : (negative ? kDeduction : const Color(0xFF1B1C1B)),
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
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
                const Spacer(),
                Text(
                  formatCents(negative ? -sum : sum),
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
  Widget _infosCard(PayRecord r) {
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
                    color: const Color(0xFF9AA09A), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              const Text('信息项',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              const Text('不计入合计',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA09A))),
            ],
          ),
          const SizedBox(height: 6),
          for (final info in r.infos)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(info.name,
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      info.value.isEmpty ? '—' : info.value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF1B1C1B)),
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
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A))),
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
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 60,
                      height: 80,
                      color: const Color(0xFFEDEFED),
                      child: const Icon(Icons.broken_image_outlined,
                          size: 18, color: Color(0xFFB0B5B0)),
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
