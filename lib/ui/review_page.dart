import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../data/models.dart';
import '../ocr/merge_engine.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/image_viewer.dart';

/// 校对 / 新建 / 编辑三合一页面。
///
/// 为什么合并成一个页面：三种场景的表单结构和校验逻辑完全一样，
/// 只是初始数据来源不同。分开写会重复三份校验代码，改一处要改三遍。
class ReviewPage extends StatefulWidget {
  final PayRecord? editing;
  final RecognizeOutcome? outcome;
  final int initialYear;
  final int initialMonth;
  final String initialRecordType;
  final String initialLabel;

  const ReviewPage._({
    this.editing,
    this.outcome,
    required this.initialYear,
    required this.initialMonth,
    required this.initialRecordType,
    this.initialLabel = '',
  });

  /// 空白新建
  factory ReviewPage.create({
    required int year,
    required int month,
    String recordType = kTypeMonthly,
  }) =>
      ReviewPage._(
        initialYear: year,
        initialMonth: month,
        initialRecordType: recordType,
      );

  /// 从 OCR 结果进入
  factory ReviewPage.fromOutcome({
    required RecognizeOutcome outcome,
    required String recordType,
  }) {
    final now = DateTime.now();
    return ReviewPage._(
      outcome: outcome,
      initialYear: now.year,
      initialMonth: now.month,
      initialRecordType: recordType,
    );
  }

  /// 编辑已有记录
  factory ReviewPage.edit({required PayRecord record}) => ReviewPage._(
        editing: record,
        initialYear: record.periodYear,
        initialMonth: record.periodMonth,
        initialRecordType: record.recordType,
        initialLabel: record.recordLabel ?? '',
      );

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late int _year;
  late int _month;
  late String _recordType;

  final _labelCtrl = TextEditingController();
  final _grossCtrl = TextEditingController();
  final _deductionCtrl = TextEditingController();
  final _netCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  final List<PayItemDraft> _items = [];
  final List<PayImage> _images = [];
  MergeResult? _merge;
  bool _showDuplicates = false;
  bool _saving = false;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
    _month = widget.initialMonth;
    _recordType = widget.initialRecordType;
    _labelCtrl.text = widget.initialLabel;

    // 1) 编辑模式：直接回填已有数据
    final editing = widget.editing;
    if (editing != null) {
      _items.addAll(editing.items.map((e) => PayItemDraft(
            name: e.name,
            category: e.category,
            valueType: e.valueType,
            amountCents: e.amountCents,
            coefficient: e.coefficient,
          )));
      _images.addAll(editing.images);
      _grossCtrl.text = _plain(editing.grossCents);
      _deductionCtrl.text = _plain(editing.deductionCents);
      _netCtrl.text = _plain(editing.netCents);
      final note = editing.extra?['note'];
      if (note is String) _noteCtrl.text = note;
    }

    // 2) OCR 模式：把合并结果灌进表单
    final outcome = widget.outcome;
    if (outcome != null) {
      _merge = outcome.result;
      _items.addAll(outcome.result.items);
      for (final img in outcome.images) {
        _images.add(PayImage(
          filePath: img.filePath,
          sortOrder: img.index,
          ocrText: img.rawText,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      final gross = outcome.result.grossCents;
      final ded = outcome.result.deductionTotalCents;
      final net = outcome.result.netCents;
      if (gross != null) _grossCtrl.text = _plain(gross);
      if (ded != null) _deductionCtrl.text = _plain(ded);
      if (net != null) _netCtrl.text = _plain(net);
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _grossCtrl.dispose();
    _deductionCtrl.dispose();
    _netCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _plain(int cents) => (cents / 100).toStringAsFixed(2);

  // ------------------------------------------------------------ 计算

  int get _incomeSum => _items
      .where((e) => e.category == kCategoryIncome && e.valueType == kValueAmount)
      .fold(0, (s, e) => s + e.amountCents);

  int get _deductionSum => _items
      .where((e) => e.category == kCategoryDeduction && e.valueType == kValueAmount)
      .fold(0, (s, e) => s + e.amountCents);

  int? _parseCtrl(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return parseAmountToCents(t);
  }

  /// 表单里填的三个合计是否自洽
  bool get _totalsConsistent {
    final g = _parseCtrl(_grossCtrl);
    final d = _parseCtrl(_deductionCtrl);
    final n = _parseCtrl(_netCtrl);
    if (g == null || d == null || n == null) return true; // 没填就不判
    return (n - (g - d)).abs() <= 1;
  }

  bool get _detailMatchesGross {
    final g = _parseCtrl(_grossCtrl);
    if (g == null) return true;
    return (g - _incomeSum).abs() <= 1;
  }

  // ------------------------------------------------------------ 交互

  Future<void> _pickPeriod() async {
    final result = await showDialog<({int year, int month})>(
      context: context,
      builder: (ctx) => _PeriodPickerDialog(year: _year, month: _month),
    );
    if (result != null) {
      setState(() {
        _year = result.year;
        _month = result.month;
      });
    }
  }

  Future<void> _editItem(int index) async {
    final draft = _items[index];
    final result = await showDialog<_ItemEditResult>(
      context: context,
      builder: (ctx) => _ItemEditDialog(draft: draft),
    );
    if (result == null) return;
    setState(() {
      if (result.deleted) {
        _items.removeAt(index);
      } else if (result.draft != null) {
        _items[index] = result.draft!;
      }
    });
  }

  Future<void> _addItem(String category) async {
    final result = await showDialog<_ItemEditResult>(
      context: context,
      builder: (ctx) => _ItemEditDialog(
        draft: PayItemDraft(
          name: '',
          category: category,
          amountCents: 0,
        ),
        isNew: true,
      ),
    );
    if (result?.draft == null) return;
    setState(() => _items.add(result!.draft!));
  }

  void _applyComputedTotals() {
    setState(() {
      _grossCtrl.text = _plain(_incomeSum);
      _deductionCtrl.text = _plain(_deductionSum);
      _netCtrl.text = _plain(_incomeSum - _deductionSum);
    });
  }

  Future<void> _save() async {
    if (_saving) return;

    // 奖金必须有个名字，不然列表里分不清是哪种奖
    if (_recordType == kTypeExtra && _labelCtrl.text.trim().isEmpty) {
      _toast('给这笔额外收入起个名字，例如「2026年终奖」');
      return;
    }
    if (_items.isEmpty && _parseCtrl(_netCtrl) == null) {
      _toast('至少填一项金额');
      return;
    }

    final gross = _parseCtrl(_grossCtrl) ?? _incomeSum;
    final deduction = _parseCtrl(_deductionCtrl) ?? _deductionSum;
    final net = _parseCtrl(_netCtrl) ?? (gross - deduction);

    // 合计不自洽时不拦，但要用户明确知道
    if ((net - (gross - deduction)).abs() > 1) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('合计对不上'),
          content: Text(
            '应发 ${formatCents(gross)} − 代扣 ${formatCents(deduction)} '
            '= ${formatCents(gross - deduction)}，'
            '但你填的实发是 ${formatCents(net)}。\n\n确定按你填的实发保存吗？',
            style: const TextStyle(height: 1.6, fontSize: 14),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回修改')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然保存')),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() => _saving = true);
    final state = context.read<AppState>();
    final now = DateTime.now().millisecondsSinceEpoch;

    final record = PayRecord(
      id: widget.editing?.id,
      periodYear: _year,
      periodMonth: _month,
      recordType: _recordType,
      recordLabel: _recordType == kTypeExtra ? _labelCtrl.text.trim() : null,
      grossCents: gross,
      deductionCents: deduction,
      netCents: net,
      extra: _noteCtrl.text.trim().isEmpty ? null : {'note': _noteCtrl.text.trim()},
      createdAt: widget.editing?.createdAt ?? now,
      updatedAt: now,
    );

    // 明细排序：收入在前、扣款在后，保持录入顺序
    final ordered = <PayItemDraft>[
      ..._items.where((e) => e.category == kCategoryIncome),
      ..._items.where((e) => e.category == kCategoryDeduction),
    ];

    try {
      if (_isEdit) {
        await state.updateRecord(record, ordered, _images);
      } else {
        await state.insertRecord(record, ordered, _images);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _viewImage(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ImageViewerPage(paths: _images.map((e) => e.filePath).toList(), initial: index),
    ));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? '编辑记录' : (widget.outcome != null ? '核对识别结果' : '新增记录');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          if (_images.isNotEmpty) _imageStrip(),
          if (_merge != null) _mergeSummary(),
          _periodCard(),
          const SizedBox(height: 14),
          _section(
            title: '收入项',
            subtitle: '合计 ${formatCents(_incomeSum)}',
            color: kIncome,
            items: _items.where((e) => e.category == kCategoryIncome).toList(),
            onAdd: () => _addItem(kCategoryIncome),
          ),
          const SizedBox(height: 14),
          _section(
            title: '扣款项',
            subtitle: '合计 ${formatCents(_deductionSum)}',
            color: kDeduction,
            items: _items.where((e) => e.category == kCategoryDeduction).toList(),
            onAdd: () => _addItem(kCategoryDeduction),
          ),
          const SizedBox(height: 14),
          _totalsCard(),
          const SizedBox(height: 14),
          _noteCard(),
        ],
      ),
    );
  }

  Widget _imageStrip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 74,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _images.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final path = _images[i].filePath;
            return GestureDetector(
              onTap: () => _viewImage(i),
              onLongPress: () => _removeImage(i),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(path),
                      width: 56,
                      height: 74,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 74,
                        color: const Color(0xFFEDEFED),
                        child: const Icon(Icons.broken_image_outlined,
                            size: 20, color: Color(0xFFB0B5B0)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(10),
                          bottomRight: Radius.circular(6),
                        ),
                      ),
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 9, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _removeImage(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('去掉这张图？'),
        content: const Text('只是不再关联到这条记录，不影响你已经填好的明细。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去掉')),
        ],
      ),
    );
    if (ok == true) setState(() => _images.removeAt(index));
  }

  /// 合并摘要：让用户信任自动合并的结果
  Widget _mergeSummary() {
    final m = _merge!;
    final errorIssues = m.issues
        .where((e) =>
            e.type == MergeIssueType.totalMismatch ||
            e.type == MergeIssueType.noOverlap ||
            e.type == MergeIssueType.sameNameConflict)
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: errorIssues.isEmpty ? kInfoBg : kWarnBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: errorIssues.isEmpty ? const Color(0x332E7D6B) : const Color(0x33E9B949),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                errorIssues.isEmpty ? Icons.auto_awesome : Icons.warning_amber_rounded,
                size: 16,
                color: errorIssues.isEmpty ? kSeed : const Color(0xFF9A6B00),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  m.summary,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: errorIssues.isEmpty ? kSeed : const Color(0xFF6B4E00),
                  ),
                ),
              ),
            ],
          ),
          for (final issue in errorIssues) ...[
            const SizedBox(height: 6),
            Text('· ${issue.message}',
                style: const TextStyle(
                    fontSize: 11.8, height: 1.5, color: Color(0xFF8A6A1F))),
          ],
          if (m.removedDuplicates.isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _showDuplicates = !_showDuplicates),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(
                      _showDuplicates ? '收起已去除项' : '查看已去除的 ${m.removedDuplicates.length} 项重复',
                      style: const TextStyle(
                          fontSize: 11.8, color: kSeed, fontWeight: FontWeight.w500),
                    ),
                    Icon(
                      _showDuplicates ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: kSeed,
                    ),
                  ],
                ),
              ),
            ),
            if (_showDuplicates)
              for (final dup in m.removedDuplicates)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${dup.name}  ${formatCents(dup.amountCents)}',
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B6F6B))),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _items.add(dup);
                            m.removedDuplicates.remove(dup);
                          });
                        },
                        child: const Text('撤回',
                            style: TextStyle(fontSize: 11.5, color: kSeed)),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }

  Widget _periodCard() {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          ListTile(
            title: const Text('归属月份', style: TextStyle(fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$_year 年 $_month 月',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const Icon(Icons.chevron_right, size: 18, color: Color(0xFFC4C9C4)),
              ],
            ),
            onTap: _pickPeriod,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                const Text('类型', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 16),
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const [
                      ButtonSegment(
                          value: kTypeMonthly,
                          label: Text('工资', style: TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: kTypeExtra,
                          label: Text('奖金', style: TextStyle(fontSize: 12))),
                    ],
                    selected: {_recordType},
                    onSelectionChanged: (s) => setState(() => _recordType = s.first),
                  ),
                ),
              ],
            ),
          ),
          if (_recordType == kTypeExtra) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _labelCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：2026年终奖 / Q3项目奖金',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String subtitle,
    required Color color,
    required List<PayItemDraft> items,
    required VoidCallback onAdd,
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
                const Spacer(),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F8A))),
              ],
            ),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无，点下面添加',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFFB0B5B0))),
              ),
            ),
          for (final item in items) _itemRow(item),
          InkWell(
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text('添加$title', style: TextStyle(fontSize: 13, color: color)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(PayItemDraft item) {
    final index = _items.indexOf(item);
    return InkWell(
      onTap: () => _editItem(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.name.isEmpty ? '（未命名）' : item.name,
                style: TextStyle(
                  fontSize: 13.5,
                  color: item.name.isEmpty ? const Color(0xFFB0B5B0) : const Color(0xFF1B1C1B),
                ),
              ),
            ),
            if (item.valueType == kValueCoefficient)
              Text(
                item.coefficient == null ? '待填' : '× ${item.coefficient!.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 13.5,
                  color: item.coefficient == null ? kWarnBorder : kSeed,
                  fontWeight: FontWeight.w500,
                ),
              )
            else
              Text(
                formatCents(item.category == kCategoryDeduction
                    ? -item.amountCents
                    : item.amountCents),
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1B1C1B),
                ),
              ),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 14, color: Color(0xFFC4C9C4)),
          ],
        ),
      ),
    );
  }

  Widget _totalsCard() {
    final gross = _parseCtrl(_grossCtrl);
    final deduction = _parseCtrl(_deductionCtrl);
    final net = _parseCtrl(_netCtrl);

    final grossOk = _detailMatchesGross;
    final consistent = _totalsConsistent;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('合计', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _moneyField('应发合计', _grossCtrl, hint: formatCents(_incomeSum)),
          const SizedBox(height: 10),
          _moneyField('代扣合计', _deductionCtrl, hint: formatCents(_deductionSum)),
          const SizedBox(height: 10),
          _moneyField(
            '实发工资',
            _netCtrl,
            hint: gross != null && deduction != null
                ? formatCents(gross - deduction)
                : formatCents(_incomeSum - _deductionSum),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _applyComputedTotals,
                  child: Row(
                    children: [
                      const Icon(Icons.calculate_outlined, size: 14, color: kSeed),
                      const SizedBox(width: 5),
                      Text(
                        '按明细重算（$_items.length 项）',
                        style: const TextStyle(fontSize: 12, color: kSeed),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!grossOk || !consistent) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kWarnBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0x33E9B949)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!grossOk)
                    Text(
                      '收入明细加总 ${formatCents(_incomeSum)}，'
                      '与应发合计 ${formatCents(gross ?? 0)} 相差 '
                      '${formatCents((_incomeSum - (gross ?? 0)).abs())}',
                      style: const TextStyle(
                          fontSize: 11.8, height: 1.5, color: Color(0xFF6B4E00)),
                    ),
                  if (!consistent && gross != null && deduction != null && net != null)
                    Text(
                      '应发 − 代扣 = ${formatCents(gross - deduction)}，'
                      '但实发填的是 ${formatCents(net)}',
                      style: const TextStyle(
                          fontSize: 11.8, height: 1.5, color: Color(0xFF6B4E00)),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _moneyField(String label, TextEditingController ctrl, {String? hint}) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(label, style: const TextStyle(fontSize: 13.5, color: Color(0xFF4A4F4A))),
        ),
        Expanded(
          child: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFC4C9C4)),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }

  Widget _noteCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(),
      child: TextField(
        controller: _noteCtrl,
        maxLines: 2,
        decoration: const InputDecoration(
          labelText: '备注（可选）',
          hintText: '例如：本月含调薪、补发上月差额',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 子弹窗

class _ItemEditResult {
  final PayItemDraft? draft;
  final bool deleted;
  _ItemEditResult({this.draft, this.deleted = false});
}

/// 明细项编辑弹窗
class _ItemEditDialog extends StatefulWidget {
  final PayItemDraft draft;
  final bool isNew;

  const _ItemEditDialog({required this.draft, this.isNew = false});

  @override
  State<_ItemEditDialog> createState() => _ItemEditDialogState();
}

class _ItemEditDialogState extends State<_ItemEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _valueCtrl;
  late String _category;
  late bool _isCoefficient;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.draft.name);
    _category = widget.draft.category;
    _isCoefficient = widget.draft.valueType == kValueCoefficient;
    _valueCtrl = TextEditingController(
      text: _isCoefficient
          ? (widget.draft.coefficient == null
              ? ''
              : widget.draft.coefficient!.toStringAsFixed(2))
          : (widget.draft.amountCents == 0
              ? ''
              : (widget.draft.amountCents / 100).toStringAsFixed(2)),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    final raw = _valueCtrl.text.trim();
    int amountCents = 0;
    double? coefficient;

    if (_isCoefficient) {
      coefficient = parseCoefficient(raw);
    } else {
      amountCents = parseAmountToCents(raw)?.abs() ?? 0;
    }

    Navigator.of(context).pop(_ItemEditResult(
      draft: PayItemDraft(
        name: name,
        category: _category,
        valueType: _isCoefficient ? kValueCoefficient : kValueAmount,
        amountCents: amountCents,
        coefficient: coefficient,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '添加项目' : '编辑项目'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: widget.isNew,
            decoration: const InputDecoration(
              labelText: '项目名称',
              hintText: '如：基本工资 / 个人社保',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(
                        value: kCategoryIncome, label: Text('收入', style: TextStyle(fontSize: 12))),
                    ButtonSegment(
                        value: kCategoryDeduction,
                        label: Text('扣款', style: TextStyle(fontSize: 12))),
                  ],
                  selected: {_category},
                  onSelectionChanged: (s) => setState(() => _category = s.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _isCoefficient,
            onChanged: (v) => setState(() => _isCoefficient = v),
            title: const Text('这是一项系数（如绩效系数 1.20）',
                style: TextStyle(fontSize: 12.5)),
          ),
          TextField(
            controller: _valueCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            decoration: InputDecoration(
              labelText: _isCoefficient ? '系数' : '金额',
              hintText: _isCoefficient ? '1.20' : '0.00',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        if (!widget.isNew)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_ItemEditResult(deleted: true)),
            style: TextButton.styleFrom(foregroundColor: kUp),
            child: const Text('删除'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}

/// 年月选择
class _PeriodPickerDialog extends StatefulWidget {
  final int year;
  final int month;

  const _PeriodPickerDialog({required this.year, required this.month});

  @override
  State<_PeriodPickerDialog> createState() => _PeriodPickerDialogState();
}

class _PeriodPickerDialogState extends State<_PeriodPickerDialog> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    _year = widget.year;
    _month = widget.month;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _year--),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text('$_year 年', textAlign: TextAlign.center),
          ),
          IconButton(
            onPressed: () => setState(() => _year++),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          childAspectRatio: 1.5,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: List.generate(12, (i) {
            final m = i + 1;
            final selected = m == _month;
            return InkWell(
              onTap: () => setState(() => _month = m),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? kSeed : const Color(0xFFF2F4F2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$m月',
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? Colors.white : const Color(0xFF4A4F4A),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (year: _year, month: _month)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
