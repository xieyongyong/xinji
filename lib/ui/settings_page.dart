import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_service.dart';
import '../core/app_settings.dart';
import '../core/app_update.dart';
import '../core/crash_log.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/salary_template.dart';
import '../security/lock_service.dart';
import '../state/app_state.dart';
import 'cloud_backup_page.dart';
import 'employer_page.dart';
import 'lock_page.dart';
import 'salary_template_page.dart';
import 'theme.dart';
import 'update_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;
  String _busyText = '';

  /// 当前安装包版本（从原生 PackageManager 读，和系统里显示的一致）
  String _version = '';

  @override
  void initState() {
    super.initState();
    UpdateChecker.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

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
              Text(
                '备份里有你全部工资数据，一旦忘记密码，这份备份就再也打不开了。',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: kWarnLink),
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
      // 偏好写回了 SharedPreferences，重新加载让主题/开关立即生效
      await context.read<AppSettings>().load();
      await context.read<AppState>().reload(rereadCurrentEmployer: true);
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

  // ------------------------------------------------------------ 检查更新

  /// 手动检查更新。和启动时的自动检查共用同一套逻辑，
  /// 区别只是：这里失败要明说原因（自动检查是静默的）。
  Future<void> _checkUpdate() async {
    final current =
        _version.isEmpty ? await UpdateChecker.currentVersion() : _version;
    if (!mounted) return;

    setState(() {
      _busy = true;
      _busyText = '正在检查更新…';
    });

    ReleaseInfo? latest;
    String? error;
    try {
      latest = await UpdateChecker.fetchLatest();
      await UpdateChecker.markChecked();
    } catch (e) {
      error = e is UpdateException ? e.message : '$e';
    }

    if (!mounted) return;
    setState(() => _busy = false);

    if (error != null) {
      await _showUpdateError(error);
      return;
    }
    final found = latest;
    if (found == null) {
      _fail('远端还没有发布过正式版本');
      return;
    }
    if (UpdateChecker.compareVersions(found.version, current) <= 0) {
      // 已经是最新：顺手把"以后再说"的记录清掉，下次真有新版才会弹
      await UpdateChecker.skipVersion('');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已是最新版本 $current')),
      );
      return;
    }

    await showUpdateDialog(context, found, currentVersion: current);
  }

  /// 检查更新失败时，给出原因 + 一条"手动去 Release 页看看"的退路
  Future<void> _showUpdateError(String message) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检查更新失败'),
        content: Text(
          '$message\n\n'
          '也可以直接用浏览器打开 Release 页面，手动下载最新安装包。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('知道了')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('打开页面'),
          ),
        ],
      ),
    );
    if (go == true) {
      try {
        await UpdateChecker.openUrl('https://github.com/${UpdateChecker.repo}/releases');
      } catch (_) {
        // 连浏览器都打不开就不用再提示了
      }
    }
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
              _sectionTitle('外观'),
              _card([
                _item(
                  icon: Icons.brightness_6_outlined,
                  title: '深浅模式',
                  subtitle: settings.themeMode == 1
                      ? '浅色'
                      : settings.themeMode == 2
                          ? '深色'
                          : '跟随系统',
                  trailing: const SizedBox.shrink(),
                  onTap: () => _pickThemeMode(context, settings),
                ),
                _swatches(settings),
                _item(
                  icon: Icons.palette_outlined,
                  title: '主题配色',
                  subtitle: '当前：${kSeedSchemes[settings.seedIndex < 0 || settings.seedIndex >= kSeedSchemes.length ? 0 : settings.seedIndex].name}',
                  trailing: const SizedBox.shrink(),
                  onTap: () => _pickSeed(context, settings),
                ),
              ]),
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
                    icon: Icons.timer_outlined,
                    title: '切后台重新锁定',
                    subtitle: settings.lockDelaySeconds == 0
                        ? '切走立刻锁'
                        : '离开超过 ${settings.lockDelayLabel} 后回来要重新验证',
                    onTap: () => _pickLockDelay(context, settings),
                  ),
                  const Divider(height: 1),
                  _item(
                    icon: Icons.lock_clock,
                    title: '立即锁定',
                    onTap: () {
                      lock.lockNow();
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                  ),
                ],
                const Divider(height: 1),
                SwitchListTile(
                  value: settings.privacyMask,
                  onChanged: (v) => settings.setPrivacyMask(v),
                  title: const Text('后台隐藏内容', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '切到后台时盖住整屏，最近任务里只看得到「内容已隐藏」，'
                    '看不到工资明细。回到应用自动恢复。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
                  ),
                  isThreeLine: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: Icon(Icons.visibility_off_outlined, size: 20, color: kTextBody),
                ),
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
                const Divider(height: 1),
                _item(
                  icon: Icons.cloud_outlined,
                  title: '云盘备份（WebDAV）',
                  subtitle: '传到自己的坚果云 / NAS，默认关闭',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CloudBackupPage()),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('雇主'),
              _card([
                _item(
                  icon: Icons.business_outlined,
                  title: '雇主档案',
                  subtitle: state.employers.length <= 1
                      ? '只有一家；换工作后在这里新增，旧工资条不受影响'
                      : '共 ${state.employers.length} 家，当前：'
                          '${state.currentEmployer?.name ?? '未设置'}',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const EmployerPage()),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('模板'),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  '这两个不是一回事：\n'
                  '· 项目模板 = 名字词典。决定某一项算收入还是扣款、还有哪些别名，'
                  '识别和跨月对齐都靠它，全局共用、不分雇主。\n'
                  '· 工资条模板 = 这家公司工资条长什么样。有哪些字段、按什么顺序排、'
                  '是月度还是奖金，只管录入时的预填与排序。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: kTextHint),
                ),
              ),
              _card([
                _item(
                  icon: Icons.tune,
                  title: '项目模板',
                  subtitle: '识别用的名字词典，共 ${state.templates.length} 项',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TemplatePage()),
                    );
                  },
                ),
                const Divider(height: 1),
                _item(
                  icon: Icons.assignment_outlined,
                  title: '工资条模板',
                  subtitle: _templateSummary(state),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SalaryTemplatePage(
                          employerId: state.currentEmployer?.id,
                        ),
                      ),
                    );
                    setState(() {});
                  },
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('图片与识别'),
              _card([
                SwitchListTile(
                  value: settings.compressImages,
                  onChanged: (v) => settings.setCompressImages(v),
                  title: const Text('保存时压缩图片', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '开启：宽度压到 1600、JPEG 质量 88，字仍然看得清，最省空间。\n'
                    '关闭：原图直接存进 App 私有目录，细节完全保留，但长截图能占好几 MB。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
                  ),
                  isThreeLine: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: Icon(Icons.compress, size: 20, color: kTextBody),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: settings.deWatermark,
                  onChanged: (v) => settings.setDeWatermark(v),
                  title: const Text('识别前去除浅灰水印', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '把比纸面浅一大截的灰色（水印、屏幕上下的渐变）刷成白，再交给识别。\n'
                    '如果发现某个浅色小字没被识别出来，可以关掉这里再试一次。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
                  ),
                  isThreeLine: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: Icon(Icons.auto_fix_high, size: 20, color: kTextBody),
                ),
              ]),
              const SizedBox(height: 18),
              _sectionTitle('录入与显示'),
              _card([
                SwitchListTile(
                  value: settings.perfAuto,
                  onChanged: (v) => settings.setPerfAuto(v),
                  title: const Text('绩效工资自动计算', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '开启后：绩效工资 = 基本绩效 × 绩效系数。\n'
                    '没填基本绩效时，一律按「绩效工资 ÷ 系数」反推（推算值不计入合计）',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
                  ),
                  isThreeLine: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: Icon(Icons.functions, size: 20, color: kTextBody),
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
                  title: '薪迹 · 本地存档',
                  subtitle: '${_version.isEmpty ? '' : '版本 $_version · '}'
                      '共记录 ${state.records.length} 条'
                      '（${state.employers.length} 家雇主）',
                ),
                const Divider(height: 1),
                _item(
                  icon: Icons.system_update_alt,
                  title: '检查更新',
                  subtitle: '从 GitHub Releases 看有没有新版本（只读版本号，不上传任何数据）',
                  onTap: _checkUpdate,
                ),
                const Divider(height: 1),
                _item(
                  icon: Icons.bug_report_outlined,
                  title: '诊断日志',
                  subtitle: '出错时看这里：最后一步做到哪、卡在什么地方',
                  onTap: _showDiagnostics,
                ),
                const Divider(height: 1),
                Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    '所有工资数据、工资条图片都只存在这台手机里，'
                    '不上传、不同步，识别也全部在本机完成。\n\n'
                    '唯一会联网的地方是「检查更新 / 应用内更新」：向 GitHub 读版本号、'
                    '下载安装包，不会上传任何数据。\n\n'
                    '卸载 App 会连同数据一起删除，请定期导出备份。',
                    style: TextStyle(fontSize: 12, height: 1.8, color: kTextSecondary),
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
          Icon(Icons.chevron_right, size: 18, color: kTextFaint),
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
                          ? kTextPrimary
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

  /// 诊断日志。
  ///
  /// 三类信息按「证据硬度」从高到低拼起来：
  /// 1. `last_exit.txt` —— 系统记录的上次各进程死亡原因。
  ///    这是 native 崩溃（Dart 完全抓不到）唯一的硬证据：
  ///    `CRASH_NATIVE 信号=11` 是段错误，`LOW_MEMORY` 是内存不够被杀，
  ///    看「进程=…:ocr」就知道崩的是识别进程还是主进程。
  /// 2. `ocr_trace.log` —— 识别进程写的一行行面包屑，最后一行就是崩在哪一步。
  /// 3. `crash.log` —— Dart 层能抓到的异常。
  Future<void> _showDiagnostics() async {
    final text = await _collectDiagnostics();
    if (!mounted) return;
    final lines = text.split('\n');
    final tail = lines.length > 240
        ? lines.sublist(lines.length - 240).join('\n')
        : text;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('诊断日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(
              tail.trim().isEmpty ? '暂无记录。说明还没发生过异常。' : tail,
              style: const TextStyle(fontSize: 10.5, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await CrashLog.clear();
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 拼装诊断信息。任何一步读不到都跳过，绝不因为诊断本身抛异常
  Future<String> _collectDiagnostics() async {
    final buf = StringBuffer();
    buf.writeln('系统：${Platform.operatingSystemVersion}');
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in ['last_exit.txt', 'ocr_trace.log']) {
        final f = File('${dir.path}/$name');
        if (!await f.exists()) continue;
        var content = await f.readAsString();
        if (content.length > 3000) {
          content = content.substring(content.length - 3000);
        }
        buf.writeln('\n===== $name =====');
        buf.writeln(content.trim());
      }
    } catch (_) {
      // 私有目录读不到就只给 crash.log
    }
    buf.writeln('\n===== crash.log =====');
    buf.write(await CrashLog.read());
    return buf.toString();
  }

  /// 「录入与显示」里的模板摘要：一句话说清当前公司在用什么
  String _templateSummary(AppState state) {
    final id = state.currentEmployer?.id;
    final count = state.salaryTemplatesOf(id).length;
    if (count == 0) return '未设置，录入时不会预填字段';
    final monthly = state.activeTemplateFor(id, appliesTo: kTplMonthly);
    final extra = state.activeTemplateFor(id, appliesTo: kTplExtra);
    return '共 $count 套 · 月度：${monthly?.name ?? '未设置'}'
        ' · 奖金：${extra?.name ?? '未设置'}';
  }

  /// 配色方案的小色块，点一下直接切换，省得进二级页
  Widget _swatches(AppSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          for (var i = 0; i < kSeedSchemes.length; i++)
            GestureDetector(
              onTap: () => settings.setSeedIndex(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 10),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: kSeedSchemes[i].seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: settings.seedIndex == i ? kTextPrimary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: settings.seedIndex == i
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  /// 选「切后台多久回来要重新验证」。0 秒 = 切走就锁。
  Future<void> _pickLockDelay(BuildContext context, AppSettings settings) async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('切后台重新锁定', style: TextStyle(fontSize: 15)),
        children: [
          for (final e in AppSettings.lockDelayOptions.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(e.key),
              child: Row(
                children: [
                  Text(e.value, style: const TextStyle(fontSize: 14)),
                  const Spacer(),
                  if (settings.lockDelaySeconds == e.key)
                    Icon(Icons.check, size: 18, color: kSeed),
                ],
              ),
            ),
        ],
      ),
    );
    if (v == null) return;
    await settings.setLockDelay(v);
    if (mounted) setState(() {});
  }

  Future<void> _pickThemeMode(BuildContext context, AppSettings settings) async {
    final v = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('深浅模式', style: TextStyle(fontSize: 15)),
        children: [
          for (var i = 0; i < 3; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Row(
                children: [
                  Icon(
                    [Icons.brightness_auto, Icons.light_mode, Icons.dark_mode][i],
                    size: 18,
                    color: kTextBody,
                  ),
                  const SizedBox(width: 12),
                  Text(['跟随系统', '浅色', '深色'][i], style: const TextStyle(fontSize: 14)),
                  if (settings.themeMode == i) ...[
                    const Spacer(),
                    Icon(Icons.check, size: 18, color: kSeed),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null) await settings.setThemeMode(v);
  }

  Future<void> _pickSeed(BuildContext context, AppSettings settings) async {
    final v = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('主题配色', style: TextStyle(fontSize: 15)),
        children: [
          for (var i = 0; i < kSeedSchemes.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: kSeedSchemes[i].seed,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(kSeedSchemes[i].name, style: const TextStyle(fontSize: 14)),
                  if (settings.seedIndex == i) ...[
                    const Spacer(),
                    Icon(Icons.check, size: 18, color: kSeed),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null) await settings.setSeedIndex(v);
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5,
                color: kTextSecondary,
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
      leading: Icon(icon, size: 20, color: kTextBody),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: TextStyle(fontSize: 11.5, color: kTextHint)),
      trailing: trailing ?? Icon(Icons.chevron_right, size: 18, color: kTextFaint),
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
            child: Text(
              '模板有两个作用：\n'
              '1. 识别时把 OCR 认出来的名字归一到标准名\n'
              '2. 对比时把「岗位津贴」和「岗位工资」这种同义不同名对齐\n\n'
              '公司改项目名了，在这里给它加个别名就行。',
              style: TextStyle(fontSize: 12, height: 1.75, color: kInfoText),
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
                style: TextStyle(fontSize: 11, color: kTextHint),
              ),
              trailing: Icon(Icons.edit_outlined, size: 16, color: kTextFaint),
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
