import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/employer.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// 雇主档案：跳槽后新旧工资条并存，各算各的。
///
/// 设计要点：
/// - 同一时刻只有一个「当前雇主」，首页/年度/对比都只看它；
///   要看旧公司的数据，切过去就行，数据不会被删也不会被改。
/// - 删除雇主**不是**删数据：名下的记录必须先迁到另一家。
///   如果允许直接删，那些记录就变成看不见的孤儿 —— 用户会以为丢了。
class EmployerPage extends StatelessWidget {
  const EmployerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.employers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('雇主档案'),
        actions: [
          IconButton(
            tooltip: '新增雇主',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(context, null),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: kInfoBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: kSeed),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '换工作后新增一家雇主即可，旧记录不会被改动。'
                    '首页只显示「当前雇主」的工资，看历史时切回去就看到了。',
                    style: TextStyle(fontSize: 11.8, color: Color(0xFF3D5A54), height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final e in list) _employerCard(context, state, e),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => _edit(context, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新增雇主'),
          ),
        ],
      ),
    );
  }

  Widget _employerCard(BuildContext context, AppState state, Employer e) {
    final isCurrent = e.id == state.currentEmployerId;
    final count = state.records.where((r) => r.employerId == e.id).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent ? kSeed.withOpacity(0.55) : const Color(0xFFE6E8E6),
            width: isCurrent ? 1.4 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isCurrent ? kSeed : const Color(0xFFEDEFED),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.business_outlined,
                  size: 18,
                  color: isCurrent ? Colors.white : const Color(0xFF8A8F8A),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            e.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: kInfoBg,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('当前',
                                style: TextStyle(fontSize: 10, color: kSeed)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (e.periodLabel.isNotEmpty) e.periodLabel,
                        '$count 条记录',
                      ].join(' · '),
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A)),
                    ),
                  ],
                ),
              ),
              if (!isCurrent)
                TextButton(
                  onPressed: () => state.switchEmployer(e.id!),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('切换', style: TextStyle(fontSize: 12.5)),
                ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (v) async {
                  if (v == 'edit') {
                    await _edit(context, e);
                  } else if (v == 'delete') {
                    await _delete(context, e);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: state.employers.length > 1,
                    child: Text(
                      state.employers.length > 1 ? '删除' : '删除（至少保留一家）',
                      style: TextStyle(
                        color: state.employers.length > 1
                            ? const Color(0xFFC62828)
                            : const Color(0xFFB0B5B0),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, Employer? existing) async {
    final result = await showDialog<Employer>(
      context: context,
      builder: (_) => _EmployerEditDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;

    final state = context.read<AppState>();
    if (existing == null) {
      await state.addEmployer(result);
      // 新增后自动切过去，符合"我换公司了"的直觉
      final added = state.employers.last;
      if (added.id != null) await state.switchEmployer(added.id!);
    } else {
      await state.updateEmployer(result);
    }
  }

  Future<void> _delete(BuildContext context, Employer e) async {
    final state = context.read<AppState>();
    final count = state.records.where((r) => r.employerId == e.id).length;
    final targets = state.employers.where((x) => x.id != e.id).toList();
    if (targets.isEmpty) return;

    final moveTo = await showDialog<int>(
      context: context,
      builder: (ctx) {
        var target = targets.first.id!;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text('删除「${e.name}」'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0
                      ? '这家雇主名下没有记录，可以放心删除。'
                      : '它名下还有 $count 条记录。删除后这些记录不会被丢掉，'
                          '而是转到你选的雇主下面（之后仍可单独编辑）。',
                  style: const TextStyle(fontSize: 13.5, height: 1.6),
                ),
                if (count > 0) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    value: target,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '记录转给',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: targets
                        .map((x) => DropdownMenuItem<int>(
                              value: x.id!,
                              child: Text(x.name, style: const TextStyle(fontSize: 14)),
                            ))
                        .toList(),
                    onChanged: (v) => setLocal(() => target = v ?? target),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
                onPressed: () => Navigator.pop(ctx, target),
                child: const Text('删除'),
              ),
            ],
          ),
        );
      },
    );

    if (moveTo == null) return;
    await state.deleteEmployer(e.id!, moveTo: moveTo);
  }
}

/// 新增 / 编辑雇主
class _EmployerEditDialog extends StatefulWidget {
  final Employer? existing;
  const _EmployerEditDialog({this.existing});

  @override
  State<_EmployerEditDialog> createState() => _EmployerEditDialogState();
}

class _EmployerEditDialogState extends State<_EmployerEditDialog> {
  late final TextEditingController _nameCtrl;
  int? _startYear;
  int? _startMonth;
  int? _endYear;
  int? _endMonth;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _startYear = e?.startYear;
    _startMonth = e?.startMonth;
    _endYear = e?.endYear;
    _endMonth = e?.endMonth;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool isStart}) async {
    final r = await showDialog<DateTime>(
      context: context,
      builder: (_) => _YearMonthDialog(
        initial: isStart
            ? (_startYear != null && _startMonth != null
                ? DateTime(_startYear!, _startMonth!)
                : null)
            : (_endYear != null && _endMonth != null
                ? DateTime(_endYear!, _endMonth!)
                : null),
      ),
    );
    if (r == null) return;
    setState(() {
      if (isStart) {
        _startYear = r.year;
        _startMonth = r.month;
      } else {
        _endYear = r.year;
        _endMonth = r.month;
      }
    });
  }

  String _label(int? y, int? m, String fallback) =>
      (y == null || m == null) ? fallback : '$y 年 $m 月';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新增雇主' : '编辑雇主'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '公司 / 单位名称',
                hintText: '例如：奔图电子',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            const Text('在职区间（可选，用来录入时自动选中）',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF8A8F8A))),
            const SizedBox(height: 6),
            _periodRow('开始', _label(_startYear, _startMonth, '不设置'),
                () => _pick(isStart: true),
                clear: _startYear != null,
                onClear: () => setState(() {
                      _startYear = null;
                      _startMonth = null;
                    })),
            _periodRow('结束', _label(_endYear, _endMonth, '至今'),
                () => _pick(isStart: false),
                clear: _endYear != null,
                onClear: () => setState(() {
                      _endYear = null;
                      _endMonth = null;
                    })),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              Employer(
                id: widget.existing?.id,
                name: name,
                startYear: _startYear,
                startMonth: _startMonth,
                endYear: _endYear,
                endMonth: _endMonth,
                sortOrder: widget.existing?.sortOrder ?? 0,
                createdAt: widget.existing?.createdAt ?? 0,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _periodRow(String label, String value, VoidCallback onTap,
      {required bool clear, required VoidCallback onClear}) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(value, style: const TextStyle(fontSize: 13.5)),
          ),
        ),
        if (clear)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
          ),
      ],
    );
  }
}

/// 只选「年 + 月」的小弹窗
class _YearMonthDialog extends StatefulWidget {
  final DateTime? initial;
  const _YearMonthDialog({this.initial});

  @override
  State<_YearMonthDialog> createState() => _YearMonthDialogState();
}

class _YearMonthDialogState extends State<_YearMonthDialog> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = widget.initial?.year ?? now.year;
    _month = widget.initial?.month ?? now.month;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final years = [for (var y = now.year + 1; y >= now.year - 40; y--) y];
    return AlertDialog(
      title: const Text('选择年月'),
      content: Row(
        children: [
          Expanded(
            child: DropdownButton<int>(
              value: _year,
              isExpanded: true,
              items: years
                  .map((y) => DropdownMenuItem(value: y, child: Text('$y 年')))
                  .toList(),
              onChanged: (v) => setState(() => _year = v ?? _year),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<int>(
              value: _month,
              isExpanded: true,
              items: [
                for (var m = 1; m <= 12; m++)
                  DropdownMenuItem(value: m, child: Text('$m 月'))
              ],
              onChanged: (v) => setState(() => _month = v ?? _month),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, DateTime(_year, _month)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
