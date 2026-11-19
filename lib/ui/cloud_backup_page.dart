import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backup/backup_service.dart';
import '../backup/cloud_auto_backup.dart';
import '../backup/cloud_backup.dart';
import '../core/app_settings.dart';
import '../data/db.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/app_tip.dart';

/// 云盘备份页（WebDAV）。默认关闭：只有用户主动填了服务器才会上传任何数据。
class CloudBackupPage extends StatefulWidget {
  const CloudBackupPage({super.key});

  @override
  State<CloudBackupPage> createState() => _CloudBackupPageState();
}

class _CloudBackupPageState extends State<CloudBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _cryptCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  DateTime? _remoteTime;

  /// 密码框是否显示明文。网盘应用密码和备份密码都是随机串，
  /// 看不见就很容易输错一位，重试半天还以为配置有问题。
  bool _showPass = false;
  bool _showCrypt = false;

  /// 配置读完之前不渲染表单。
  ///
  /// 不这么做的话首帧是空输入框（label 居中），异步回填后 label 才浮到顶部，
  /// 用户看到的就是"标签先错位、1 秒后才归位"。
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await WebDavConfig.load();
    final crypt = await CloudBackupSecrets.loadCryptPassword();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = cfg?.url ?? '';
      _userCtrl.text = cfg?.user ?? '';
      // 本机记住的密码直接回填：这是自己手机，每次重输既麻烦又容易错
      _passCtrl.text = cfg?.password ?? '';
      _cryptCtrl.text = crypt;
      _loaded = true;
    });
    if (cfg != null) _checkRemote();
  }

  WebDavConfig _formConfig() => WebDavConfig(
        url: _urlCtrl.text.trim(),
        user: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );

  Future<void> _save() async {
    final cfg = _formConfig();
    if (!cfg.isValid) {
      _toast('请填完整的服务器地址、账号和密码');
      return;
    }
    await cfg.save();
    await CloudBackupSecrets.saveCryptPassword(_cryptCtrl.text);
    _toast('配置已保存（密码只存在本机，下次自动带出）');
  }

  /// 忘掉密码：服务器地址和账号保留，只是不再自动填密码
  Future<void> _forgetPasswords() async {
    await WebDavConfig.forgetPassword();
    await CloudBackupSecrets.clearCryptPassword();
    if (!mounted) return;
    setState(() {
      _passCtrl.clear();
      _cryptCtrl.clear();
      _showPass = false;
      _showCrypt = false;
    });
    _toast('已忘记本机保存的密码，下次需要重新输入');
  }

  Future<void> _clear() async {
    await WebDavConfig.clear();
    await CloudBackupSecrets.clearCryptPassword();
    if (!mounted) return;
    setState(() {
      _remoteTime = null;
      _urlCtrl.clear();
      _userCtrl.clear();
      _passCtrl.clear();
      _cryptCtrl.clear();
    });
    _toast('已清除云盘配置');
  }

  Future<WebDavClient?> _client() async {
    // 改过表单但没保存：用表单里的值试，省得用户还要先点保存
    final cfg = _formConfig();
    if (!cfg.isValid) {
      _toast('请先填完整的 WebDAV 配置');
      return null;
    }
    return WebDavClient(cfg);
  }

  Future<void> _test() async {
    final client = await _client();
    if (client == null) return;
    setState(() => _busy = true);
    try {
      await client.exists(kCloudBackupName);
      _toast('连接成功');
    } on WebDavException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkRemote() async {
    final client = await _client();
    if (client == null || !mounted) return;
    try {
      final has = await client.exists(kCloudBackupName);
      if (!mounted) return;
      setState(() => _status = has ? '云端已有一份备份' : '云端暂无备份');
    } catch (_) {
      if (mounted) setState(() => _status = '连不上云盘');
    }
  }

  Future<void> _upload() async {
    final client = await _client();
    if (client == null) return;
    final pass = _cryptCtrl.text;
    if (pass.length < 4) {
      _toast('备份密码至少 4 位（恢复时要用同一个）');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在打包并上传…';
    });
    try {
      final db = await AppDb.instance;
      final service = BackupService(db);
      final bytes = await service.buildBytes(encrypted: true, password: pass);
      await client.upload(kCloudBackupName, bytes);
      // 密码是对的才会走到这里，顺手记住，下次不用再输
      await CloudBackupSecrets.saveCryptPassword(pass);
      if (!mounted) return;
      setState(() {
        _remoteTime = DateTime.now();
        _status = '已上传 ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB';
      });
      _toast('云盘备份完成');
    } on BackupException catch (e) {
      if (mounted) setState(() => _status = e.message);
      _toast(e.message);
    } on WebDavException catch (e) {
      if (mounted) setState(() => _status = e.message);
      _toast(e.message);
    } catch (e) {
      if (mounted) setState(() => _status = '上传失败：$e');
      _toast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final client = await _client();
    if (client == null) return;
    final pass = _cryptCtrl.text;
    if (pass.length < 4) {
      _toast('请输入备份密码');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('从云盘恢复？'),
        content: const Text(
          '会清空当前全部数据，用云端那份备份替换。此操作不可撤销，'
          '建议先在本地导出一份当前数据。',
          style: TextStyle(height: 1.6, fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认恢复')),
        ],
      ),
    );
    if (go != true) return;

    setState(() {
      _busy = true;
      _status = '正在下载并恢复…';
    });
    try {
      final bytes = await client.download(kCloudBackupName);
      final db = await AppDb.instance;
      final service = BackupService(db);
      await service.restoreBytes(bytes, password: pass);
      // 恢复成功说明密码没问题，记住它
      await CloudBackupSecrets.saveCryptPassword(pass);
      if (!mounted) return;
      // 偏好写回了 sp，重新加载让主题/开关/当前雇主立即生效
      await context.read<AppSettings>().load();
      await context.read<AppState>().reload(rereadCurrentEmployer: true);
      if (!mounted) return;
      setState(() => _status = '恢复完成');
      _toast('云盘备份已恢复');
    } on BackupException catch (e) {
      if (mounted) setState(() => _status = e.message);
      _toast(e.message);
    } on WebDavException catch (e) {
      if (mounted) setState(() => _status = e.message);
      _toast(e.message);
    } catch (e) {
      if (mounted) setState(() => _status = '恢复失败：$e');
      _toast('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showTip(context, msg);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _cryptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('云盘备份')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('云盘备份')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              _tip(),
              const SizedBox(height: 8),
              _field(_urlCtrl, '服务器地址', 'https://dav.jianguoyun.com/dav/'),
              const SizedBox(height: 10),
              _field(_userCtrl, '账号', '你的 WebDAV 用户名'),
              const SizedBox(height: 10),
              _field(
                _passCtrl,
                '密码 / 应用密码',
                '不是登录密码，是应用专用密码',
                obscure: true,
                visible: _showPass,
                onToggleVisibility: () => setState(() => _showPass = !_showPass),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  TextButton(onPressed: _busy ? null : _test, child: const Text('测试连接')),
                  TextButton(onPressed: _busy ? null : _save, child: const Text('保存配置')),
                  TextButton(
                      onPressed: _busy ? null : _forgetPasswords,
                      child: const Text('忘记密码')),
                  TextButton(onPressed: _busy ? null : _clear, child: const Text('清除配置')),
                ],
              ),
              const Divider(height: 24),
              _sectionTitle('备份密码'),
              _field(
                _cryptCtrl,
                '备份加密密码',
                '至少 4 位，上传/恢复都要用',
                obscure: true,
                visible: _showCrypt,
                onToggleVisibility: () => setState(() => _showCrypt = !_showCrypt),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '云端存的是 AES-256 加密后的备份，密码只有你知道。'
                  '换设备时用同一个密码恢复即可。\n'
                  '这台手机上输入的密码会记住（存在本机、点眼睛可看明文），'
                  '不用每次重输；点「忘记密码」可以清掉。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('上传到云盘（全量）'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _download,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('从云盘恢复'),
              ),
              const Divider(height: 28),
              _sectionTitle('定时自动备份'),
              _autoBackupCard(settings),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!, style: TextStyle(fontSize: 12.5, color: kTextSecondary)),
              ],
              if (_remoteTime != null) ...[
                const SizedBox(height: 6),
                Text(
                  '上次上传：${_remoteTime.toString().substring(0, 19)}',
                  style: TextStyle(fontSize: 12, color: kTextHint),
                ),
              ],
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  /// 定时自动备份：一个月做一次全量，够用且不会把网盘塞满。
  Widget _autoBackupCard(AppSettings settings) {
    final on = settings.cloudAutoBackup;
    final last = settings.cloudAutoBackupLastAt;
    final lastText = last <= 0
        ? '还没成功备份过'
        : '上次成功：${_fmtTime(DateTime.fromMillisecondsSinceEpoch(last))}';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            value: on,
            onChanged: (v) => settings.setCloudAutoBackup(v),
            title: const Text('每月自动备份到云盘', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '不是后台定时任务：到了日子后你打开应用，它会自动补做一次'
              '（后台常驻任务会耗电、还会被系统杀，一个月一次的备份不值当）。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
            ),
            isThreeLine: true,
            contentPadding: EdgeInsets.zero,
          ),
          if (on) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Text('备份日', style: TextStyle(fontSize: 13, color: kTextBody)),
                const SizedBox(width: 10),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: () => _pickBackupDay(settings),
                      child: Text(
                        '每月 ${settings.cloudAutoBackupDay} 号',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _runAutoBackupNow(settings),
                  child: const Text('立即备份一次'),
                ),
              ],
            ),
            Text(lastText,
                style: TextStyle(fontSize: 11.5, color: kTextHint)),
            if (settings.cloudAutoBackupError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '上次自动备份失败：${settings.cloudAutoBackupError}',
                  style: TextStyle(fontSize: 11.5, color: kWarnText),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '需要先在上面填好服务器、账号、密码和备份密码，'
                '自动备份不会弹窗打扰你，失败原因会显示在这里。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: kTextHint),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _pickBackupDay(AppSettings settings) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('每月几号备份'),
        content: SizedBox(
          width: 320,
          child: GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (var d = 1; d <= 28; d++)
                InkWell(
                  onTap: () => Navigator.pop(ctx, d),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: d == settings.cloudAutoBackupDay ? kSeed : kSurfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$d',
                      style: TextStyle(
                        fontSize: 13,
                        color: d == settings.cloudAutoBackupDay
                            ? Colors.white
                            : kTextBody,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    if (picked == null) return;
    await settings.setCloudAutoBackupDay(picked);
    if (mounted) _toast('已设为每月 $picked 号（当天或之后第一次打开应用时备份）');
  }

  /// 立即按自动备份的规则跑一次（也用来验证配置到底通不通）
  Future<void> _runAutoBackupNow(AppSettings settings) async {
    setState(() {
      _busy = true;
      _status = '正在自动备份…';
    });
    try {
      final msg = await CloudAutoBackup.runNow(settings);
      if (!mounted) return;
      if (msg != null) {
        setState(() {
          _remoteTime = DateTime.now();
          _status = msg;
        });
        _toast('自动备份成功，这个月不会再自动跑');
      } else {
        final err = settings.cloudAutoBackupError;
        setState(() => _status = err.isEmpty ? '没跑起来，先检查上面的配置' : err);
        _toast(err.isEmpty ? '先填好服务器、账号和两个密码' : err);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tip() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kInfoBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          '云盘备份是可选功能，默认关闭。只有你填了服务器并主动上传，'
          '加密备份才会传到自己的网盘；不开启则完全离线。',
          style: TextStyle(fontSize: 12.5, height: 1.6),
        ),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, color: kTextSecondary, fontWeight: FontWeight.w500)),
      );

  Widget _field(TextEditingController ctrl, String label, String hint,
      {bool obscure = false,
      bool visible = false,
      VoidCallback? onToggleVisibility}) {
    return TextField(
      controller: ctrl,
      obscureText: obscure && !visible,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        // 永远浮在框线上：label 只在"有值/聚焦"时才浮起的话，
        // 首帧是空框（label 居中）、回填后跳成浮动，看起来就是文字错位。
        floatingLabelBehavior: FloatingLabelBehavior.always,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: onToggleVisibility == null
            ? null
            : IconButton(
                tooltip: visible ? '隐藏密码' : '显示密码',
                icon: Icon(
                  visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 19,
                ),
                onPressed: onToggleVisibility,
              ),
      ),
    );
  }
}
