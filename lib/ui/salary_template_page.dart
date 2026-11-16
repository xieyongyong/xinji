import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/employer.dart';
import '../data/models.dart';
import '../data/salary_template.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// 发薪模板列表。
///
/// 归属关系是 **雇主 → 多套模板**：
/// 同一家公司换过几种工资条格式（涨薪、换系统、改绩效结构）就存几套，
/// 每家公司各自有一套「生效中」，互不干扰。
/// 入口在「雇主档案」里，点某家公司进来就是这家的模板。
class SalaryTemplatePage extends StatelessWidget {
  /// 看哪家公司的模板。为空表示"不属于任何雇主"的老模板。
  final int? employerId;

  const SalaryTemplatePage({super.key, this.employerId});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.salaryTemplatesOf(employerId);
    final employer = state.employerById(employerId);

    return Scaffold(
      appBar: AppBar(
        title: Text(employer == null ? '发薪模板' : '${employer.name} · 模板'),
        actions: [
          IconButton(
            tooltip: '新建模板',
            icon: const Icon(Icons.add),
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kInfoBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              employer == null
                  ? '生效中的模板会决定两件事：\n'
                      '· 手动录入时自动带出这些字段（金额留空由你填）\n'
                      '· 识别工资条时，没识别到的字段也会按模板补出来'
                  : '这是「${employer.name}」的模板，只影响这家公司的录入预填。\n'
                      '· 生效中的那套决定手动录入带出哪些字段\n'
                      '· 识别工资条时，没识别到的字段也会按它补出来\n\n'
                      '同一家公司换过工资条格式，就再建一套并设为生效；'
                      '旧的那套留着，随时能切回来。',
              style: const TextStyle(fontSize: 12, height: 1.7, color: Color(0xFF3D5A54)),
            ),
          ),
          const SizedBox(height: 14),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  const Icon(Icons.assignment_outlined, size: 40, color: Color(0xFFC4C9C4)),
                  const SizedBox(height: 12),
                  const Text('还没有模板',
                      style: TextStyle(fontSize: 13.5, color: Color(0xFF8A8F8A))),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => _openEditor(context, null),
                    child: const Text('新建一套'),
                  ),
                ],
              ),
            ),
          for (final t in list) _templateCard(context, state, t, employer),
        ],
      ),
    );
  }

  Widget _templateCard(BuildContext context, AppState state, SalaryTemplate t,
      Employer? employer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: cardDecoration(),
      child: Column(
        children: [
          ListTile(
            title: Row(
              children: [
                Flexible(
                  child: Text(t.name,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                if (t.isActive) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: kSeed,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('生效中',
                        style: TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              '${t.incomeFields.length} 收入 · ${t.deductionFields.length} 扣款 · '
              '${t.infoFields.length} 信息',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A)),
            ),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 20),
              onSelected: (v) async {
                if (v == 'active') {
                  await state.activateSalaryTemplate(t.id!, employerId: employerId);
                } else if (v == 'delete') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('删除这套模板？'),
                      content: Text('「${t.name}」的字段设置会被删除，已录入的工资记录不受影响。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('删除')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await state.deleteSalaryTemplate(t.id!, employerId: employerId);
                  }
                }
              },
              itemBuilder: (_) => [
                if (!t.isActive)
                  const PopupMenuItem(value: 'active', child: Text('设为生效')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
            onTap: () => _openEditor(context, t),
          ),
          if (!t.isActive)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      state.activateSalaryTemplate(t.id!, employerId: employerId),
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('设为生效', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, SalaryTemplate? template) async {
    final state = context.read<AppState>();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SalaryTemplateEditPage(
          template: template,
          employerId: employerId,
          // 新建时默认复制这家公司当前生效模板的字段，省得从零加一遍
          copyFrom: template == null ? state.activeTemplateFor(employerId) : null,
        ),
      ),
    );
  }
}

/// 模板编辑页：改名字、增删字段、调整类别
class SalaryTemplateEditPage extends StatefulWidget {
  final SalaryTemplate? template;
  final SalaryTemplate? copyFrom;

  /// 新建时归属到哪家雇主
  final int? employerId;

  const SalaryTemplateEditPage({
    super.key,
    this.template,
    this.copyFrom,
    this.employerId,
  });

  @override
  State<SalaryTemplateEditPage> createState() => _SalaryTemplateEditPageState();
}

class _SalaryTemplateEditPageState extends State<SalaryTemplateEditPage> {
  late final TextEditingController _nameCtrl;
  final List<TemplateField> _fields = [];
  bool _saving = false;

  bool get _isNew => widget.template == null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.template?.name ?? '');
    final source = widget.template?.fields ?? widget.copyFrom?.fields ?? const [];
    _fields.addAll(source.map((f) => TemplateField(
          id: null,
          name: f.name,
          category: f.category,
          valueType: f.valueType,
          sortOrder: f.sortOrder,
        )));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _addField({TemplateField? editing, int? index}) async {
    final result = await showDialog<TemplateField?>(
      context: context,
      builder: (ctx) => _FieldEditDialog(field: editing),
    );
    if (result == null) return;
    if (result.name.isEmpty) return;
    setState(() {
      if (index == null) {
        _fields.add(result);
      } else {
        _fields[index] = result;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('给模板起个名字')));
      return;
    }
    if (_fields.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少加一个字段')));
      return;
    }

    setState(() => _saving = true);
    final state = context.read<AppState>();
    final template = SalaryTemplate(
      id: widget.template?.id,
      employerId: widget.template?.employerId ?? widget.employerId,
      name: name,
      isActive: widget.template?.isActive ?? false,
      createdAt: widget.template?.createdAt ?? 0,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      fields: _fields,
    );
    try {
      await state.saveSalaryTemplate(template);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建发薪模板' : '编辑模板'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: cardDecoration(),
            child: TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '模板名称',
                hintText: '如：XX公司工资条 / 2026新格式',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _group('收入项', kCategoryIncome, Icons.add_circle_outline, kIncome),
          const SizedBox(height: 12),
          _group('扣款项', kCategoryDeduction, Icons.remove_circle_outline, kDeduction),
          const SizedBox(height: 12),
          _group('信息项（不计入合计）', kFieldInfo, Icons.badge_outlined,
              const Color(0xFF7A807A)),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => _addField(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加字段'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, String category, IconData icon, Color color) {
    final items = _fields.where((f) => f.category == category).toList();
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 13,
                  decoration:
                      BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${items.length} 项',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9AA09A))),
              ],
            ),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB0B5B0))),
              ),
            ),
          for (final f in items)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              title: Text(f.name, style: const TextStyle(fontSize: 13.5)),
              subtitle: switch (f.valueType) {
                kValueCoefficient => const Text('系数型',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9AA09A))),
                kValueDerived => const Text('推算型 · 不计入合计',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9AA09A))),
                _ => null,
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    onPressed: () =>
                        _addField(editing: f, index: _fields.indexOf(f)),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _fields.remove(f)),
                  ),
                ],
              ),
            ),
          InkWell(
            onTap: () => _addFieldThen(category),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 6),
                  Text('添加', style: TextStyle(fontSize: 12.5, color: color)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 先给个默认类别，弹窗里还能改
  Future<void> _addFieldThen(String category) async {
    final result = await showDialog<TemplateField?>(
      context: context,
      builder: (ctx) => _FieldEditDialog(
        field: TemplateField(name: '', category: category),
      ),
    );
    if (result == null || result.name.isEmpty) return;
    setState(() => _fields.add(result));
  }
}

/// 单个字段编辑
class _FieldEditDialog extends StatefulWidget {
  final TemplateField? field;
  const _FieldEditDialog({this.field});

  @override
  State<_FieldEditDialog> createState() => _FieldEditDialogState();
}

class _FieldEditDialogState extends State<_FieldEditDialog> {
  late final TextEditingController _nameCtrl;
  late String _category;
  late String _valueType;

  bool get _isNew => widget.field == null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.field?.name ?? '');
    _category = widget.field?.category ?? kCategoryIncome;
    _valueType = widget.field?.valueType ?? kValueAmount;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      TemplateField(
        name: name,
        category: _category,
        valueType: _category != kFieldInfo ? _valueType : kValueAmount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? '添加字段' : '编辑字段'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '字段名称',
              hintText: '如：基本工资 / 个人社保 / 应出勤天数',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
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
              ButtonSegment(
                  value: kFieldInfo, label: Text('信息', style: TextStyle(fontSize: 12))),
            ],
            selected: {_category},
            onSelectionChanged: (s) => setState(() => _category = s.first),
          ),
          if (_category != kFieldInfo) ...[
            const SizedBox(height: 10),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                    value: kValueAmount,
                    label: Text('金额', style: TextStyle(fontSize: 12))),
                ButtonSegment(
                    value: kValueCoefficient,
                    label: Text('系数', style: TextStyle(fontSize: 12))),
                ButtonSegment(
                    value: kValueDerived,
                    label: Text('推算', style: TextStyle(fontSize: 12))),
              ],
              selected: {_valueType},
              onSelectionChanged: (s) => setState(() => _valueType = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              switch (_valueType) {
                kValueCoefficient => '系数型：如绩效系数 1.20，不是钱，不计入合计',
                kValueDerived => '推算型：如基本绩效，由「绩效工资 ÷ 绩效系数」反推，不计入合计',
                _ => '金额型：正常参与应发 / 代扣合计',
              },
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A), height: 1.5),
            ),
          ],
          if (_category == kFieldInfo)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('信息项只做记录，永远不会计入合计',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A))),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}
