import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_service.dart';
import '../core/app_settings.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../security/lock_service.dart';
import '../state/app_state.dart';
import 'lock_page.dart';
import 'salary_template_page.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;
  String _busyText = '';

  Future<void> _verifyPin() async {
    final lock = context.read<LockService>();
    if (!lock.enabled) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入 PIN 确认'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, lock.verifyPin(ctrl.text.trim())),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (ok != true) throw BackupException('未通过验证');
  }

  // ------------------------------------------------------------ 备份

  Future<void> _exportBackup({required bool encrypted}) async {
    String? password;
    if (encrypted) {
      password = await _askPassword();
      if (password == null) return;
    }

    setState(() {
      _busy = true;
      _busyText = '正在打包…';
    });

    try {
      final db = await AppDb.instance;
      final service = BackupService(db);
      final path = await service.export(encrypted: encrypted, password: password);

      final sp = await SharedPreferences.getInstance();
      await sp.setInt('last_backup_at', DateTime.now().millisecondsSinceEpoch);

      if (!mounted) return;
      setState(() => _busy = false);

      final size = (await File(path).length() / 1024).toStringAsFixed(0);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('备份已生成'),
          content: Text(
            '${path.split(Platform.pathSeparator).last}\n'
            '大小约 $size KB\n\n'
            '${encrypted ? '已加密，恢复时需要这个密码，别忘。' : '未加密，任何拿到文件的人都能打开。'}',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                Share.shareXFiles([XFile(path)], text: '薪迹备份');
              },
              child: const Text('发送到别处'),
            ),
          ],
        ),
      );
    } catch (e) {
      _fail('导出失败：$e');
    }
  }

  Future<String?> _askPassword() async {
    final ctrl = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('设置备份密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '备份里有你全部工资数据，一旦忘记密码，这份备份就再也打不开了。',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: Color(0xFF8A6A1F)),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '密码（至少 4 位）',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '再输一次',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final p = ctrl.text;
                if (p.length < 4) {
                  setInner(() => error = '至少 4 位');
                  return;
                }
                if (p != confirm.text) {
                  setInner(() => error = '两次输入不一致');
                  return;
                }
                Navigator.pop(ctx, p);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: '选择薪迹备份文件（.zip 或 .xbk）',
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    final db = await AppDb.instance;
    final service = BackupService(db);
    final isEncrypted = await service.isEncryptedFile(path);

    String? password;
    if (isEncrypted) {
      password = await _askRestorePassword();
      if (password == null) return;
    }

    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复？'),
        content: const Text(
          '恢复会用备份里的数据**完全替换**当前所有记录，现有的记录和图片都会消失。\n\n'
          '如果当前数据还有用，请先导出一份备份。',
          style: TextStyle(fontSize: 13.5, height: 1.7),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kUp),
            child: const Text('确认替换'),
          ),
        ],
      ),
    );
    if (go != true) return;

    setState(() {
      _busy = true;
      _busyText = '正在恢复…';
    });

    try {
      final result = await service.importFromFile(path, password: password);
      if (!mounted) return;
      await context.read<AppState>().reload();
      if (!mounted) return;
      setState(() => _busy = false);

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '已恢复 ${result.recordCount} 条记录、${result.itemCount} 个明细、'
          '${result.imageCount} 张图片${result.wasEncrypted ? '（来自加密备份）' : ''}',
        ),
      ));
    } catch (e) {
      _fail('恢复失败：${e is BackupException ? e.message : e}');
    }
  }

  Future<String?> _askRestorePassword() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这份备份有密码'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '备份密码',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<LockService>();
    final state = context.watch<AppState>();
    final settings = context.watch<AppSettings>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              _sectionTitle('安全'),
              _card([
                _item(
                  icon: Icons.lock_outline,
                  title: '应用锁',
                  subtitle: lock.enabled
                      ? '已开启${lock.bioEnabled ? '（可用指纹/面容）' : ''}'
                      : '未开启，打开薪迹不需要验证',
                  trailing: Switch(
                    value: lock.enabled,
                    onChanged: (v) async {
                      if (v) {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SetupLockPage(allowSkip: false),
                          ),
                        );
                      } else {
                        try {
                          await _verifyPin();
                          await lock.disable();
                        } catch (_) {
                          return;
                        }
                      }
                      setState(() {});
                    },
                  ),
                ),
                if (lock.enabled) ...[
                  const Divider(height: 1),
                  _item(
                    icon: Icons.password,
                    title: '修改 PIN',
                    subtitle: '当前提示语：${lock.hint ?? '未设置'}',
                    onTap: () async {
                      try {
                        await _verifyPin();
                        if (mounted) {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const SetupLockPage(allowSkip: false),
                          ));
                        }
                      } catch (_) {
                        return;
                      }
                      setState(() {});
                    },
                  ),
                  const Divider(height: 1),
                  _item(
                    icon: Icons.lock_clock,
                    title: '立即锁定',
                    subtitle: '切后台超过 30 秒也会自动锁定',
                    onTap: () {
                      lock.lockNow();
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                  ),
                ],
              ]),
              const SizedBox(height: 18),
              _sectionTitle('备份与恢复'),
              _card([
                _item(
                  icon: Icons.enhanced_encryption_outlined,
                  title: '导出加密备份',
                  subtitle: '需要密码才能恢复，适合传到网盘或发给自己',
                  onTap: () => _exportBackup(encrypted: true),
                ),
                const Divider(height: 1),
                _item(
                  icon: Icons.folder_zip_outlined,
                  title: '导出明文备份',
                  subtitle: 'ZIP 里含 CSV，可以直接用 Excel 打开看',
                  onTap: () => _exportBackup(encrypted: false),
                ),
                const Divider(height: 1),
                _item(
                  icon: Icons.restore,
                  title: '从备份恢复',
                  subtitle: '⚠️ 会覆盖当前全部数据',
                  onTap: _restoreBackup,
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('项目'),
              _card([
                _item(
                  icon: Icons.tune,
                  title: '项目模板管理',
                  subtitle: '共 ${state.templates.length} 项，可加别名让不同叫法自动对齐',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TemplatePage()),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('录入与显示'),
              _card([
                _item(
                  icon: Icons.assignment_outlined,
                  title: '发薪模板',
                  subtitle: state.activeSalaryTemplate == null
                      ? '未设置，录入时不会预填字段'
                      : '当前生效：${state.activeSalaryTemplate!.name}'
                          '（${state.activeSalaryTemplate!.fields.length} 个字段）',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SalaryTemplatePage()),
                    );
                    setState(() {});
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: settings.perfAuto,
                  onChanged: (v) => settings.setPerfAuto(v),
                  title: const Text('绩效工资自动计算', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '开启后：绩效工资 = 基本绩效 × 绩效系数（三项都在才算）',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: const Icon(Icons.functions, size: 20, color: Color(0xFF4A4F4A)),
                ),
                const Divider(height: 1),
                _colorItem(
                  icon: Icons.trending_up,
                  title: '上涨颜色',
                  current: settings.upColor,
                  onPick: (argb) => settings.setUpColor(argb),
                ),
                const Divider(height: 1),
                _colorItem(
                  icon: Icons.trending_down,
                  title: '下跌颜色',
                  current: settings.downColor,
                  onPick: (argb) => settings.setDownColor(argb),
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('关于'),
              _card([
                _item(
                  icon: Icons.info_outline,
                  title: '薪迹 1.0.0',
                  subtitle: '记录 ${state.records.length} 条',
                ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    '所有数据只存在这台手机里，不上传、不联网、不同步。'
                    '识别也全部在本地完成。\n\n'
                    '卸载 App 会连同数据一起删除，请定期导出备份。',
                    style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF8A8F8A)),
                  ),
                ),
              ]),
            ],
          ),
          if (_busy)
            Container(
              color: Colors.black.withOpacity(0.3),
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 14),
                    Text(_busyText, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 颜色设置行：右侧显示当前色块，点开选色
  Widget _colorItem({
    required IconData icon,
    required String title,
    required Color current,
    required ValueChanged<int> onPick,
  }) {
    return _item(
      icon: icon,
      title: title,
      subtitle: '默认红涨绿跌，可换成你习惯的配色',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: current, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right, size: 18, color: Color(0xFFC4C9C4)),
        ],
      ),
      onTap: () async {
        final picked = await _pickColor(current);
        if (picked != null) onPick(picked);
      },
    );
  }

  Future<int?> _pickColor(Color current) async {
    const presets = <int>[
      0xFFC62828, // 红
      0xFFE65100, // 橙
      0xFFF9A825, // 黄
      0xFF2E7D32, // 绿
      0xFF00796B, // 青
      0xFF1565C0, // 蓝
      0xFF6A1B9A, // 紫
      0xFF424242, // 灰
    ];
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择颜色'),
        content: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final argb in presets)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, argb),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Color(argb),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: current == Color(argb)
                          ? const Color(0xFF1B1C1B)
                          : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF8A8F8A),
                fontWeight: FontWeight.w500)),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: cardDecoration(),
        child: Column(children: children),
      );

  Widget _item({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: const Color(0xFF4A4F4A)),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A))),
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 18, color: Color(0xFFC4C9C4)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    );
  }
}

// ---------------------------------------------------------------- 模板管理

class TemplatePage extends StatelessWidget {
  const TemplatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final incomes = state.templates.where((t) => t.category == kCategoryIncome).toList();
    final deductions =
        state.templates.where((t) => t.category == kCategoryDeduction).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('项目模板')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, null),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: kInfoBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '模板有两个作用：\n'
              '1. 识别时把 OCR 认出来的名字归一到标准名\n'
              '2. 对比时把「岗位津贴」和「岗位工资」这种同义不同名对齐\n\n'
              '公司改项目名了，在这里给它加个别名就行。',
              style: TextStyle(fontSize: 12, height: 1.75, color: Color(0xFF3D5A54)),
            ),
          ),
          const SizedBox(height: 16),
          _group(context, '收入项', incomes),
          const SizedBox(height: 16),
          _group(context, '扣款项', deductions),
        ],
      ),
    );
  }

  Widget _group(BuildContext context, String title, List<ItemTemplate> items) {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
            child: Text(title,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          for (final t in items)
            ListTile(
              dense: true,
              title: Text(t.name, style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                [
                  if (t.valueType == kValueCoefficient) '系数型',
                  if (t.aliases.isNotEmpty) '别名：${t.aliases.join('、')}',
                ].join('  '),
                style: const TextStyle(fontSize: 11, color: Color(0xFF9AA09A)),
              ),
              trailing: const Icon(Icons.edit_outlined, size: 16, color: Color(0xFFC4C9C4)),
              onTap: () => _edit(context, t),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, ItemTemplate? existing) async {
    final state = context.read<AppState>();
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final aliasCtrl = TextEditingController(text: existing?.aliases.join('，') ?? '');
    var category = existing?.category ?? kCategoryIncome;
    var isCoefficient = existing?.valueType == kValueCoefficient;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(existing == null ? '新增项目' : '编辑项目'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: existing == null,
                  decoration: const InputDecoration(
                    labelText: '标准名称',
                    hintText: '如：岗位津贴',
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
                              value: kCategoryIncome,
                              label: Text('收入', style: TextStyle(fontSize: 12))),
                          ButtonSegment(
                              value: kCategoryDeduction,
                              label: Text('扣款', style: TextStyle(fontSize: 12))),
                        ],
                        selected: {category},
                        onSelectionChanged: (s) => setInner(() => category = s.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: aliasCtrl,
                  decoration: const InputDecoration(
                    labelText: '别名（用逗号分隔）',
                    hintText: '岗位工资，职务津贴',
                    helperText: 'OCR 认到这些名字时，自动归到这个标准名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: isCoefficient,
                  onChanged: (v) => setInner(() => isCoefficient = v),
                  title: const Text('这是系数（不是金额）', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () async {
                  await state.deleteTemplate(existing.id!);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                style: TextButton.styleFrom(foregroundColor: kUp),
                child: const Text('删除'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final aliases = aliasCtrl.text
                    .split(RegExp(r'[,，、]'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                await state.saveTemplate(ItemTemplate(
                  id: existing?.id,
                  name: name,
                  category: category,
                  aliases: aliases,
                  valueType: isCoefficient ? kValueCoefficient : kValueAmount,
                  sortOrder: existing?.sortOrder ?? 99,
                ));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
