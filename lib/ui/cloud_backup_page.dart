import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backup/backup_service.dart';
import '../backup/cloud_backup.dart';
import '../core/app_settings.dart';
import '../data/db.dart';
import '../state/app_state.dart';
import 'theme.dart';

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
  WebDavConfig? _config;
  bool _busy = false;
  String? _status;
  DateTime? _remoteTime;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await WebDavConfig.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _urlCtrl.text = cfg?.url ?? '';
      _userCtrl.text = cfg?.user ?? '';
      // 密码不回填明文，让用户需要改时重新填
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
    setState(() => _config = cfg);
    _toast('配置已保存（密码只存在本机）');
  }

  Future<void> _clear() async {
    await WebDavConfig.clear();
    if (!mounted) return;
    setState(() {
      _config = null;
      _remoteTime = null;
      _urlCtrl.clear();
      _userCtrl.clear();
      _passCtrl.clear();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
              _field(_passCtrl, '密码 / 应用密码', '不是登录密码，是应用专用密码', obscure: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  TextButton(onPressed: _busy ? null : _test, child: const Text('测试连接')),
                  TextButton(onPressed: _busy ? null : _save, child: const Text('保存配置')),
                  TextButton(onPressed: _busy ? null : _clear, child: const Text('清除配置')),
                ],
              ),
              const Divider(height: 24),
              _sectionTitle('备份密码'),
              _field(_cryptCtrl, '备份加密密码', '至少 4 位，上传/恢复都要用', obscure: true),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '云端存的是 AES-256 加密后的备份，密码只有你知道。'
                  '换设备时用同一个密码恢复即可。',
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
      {bool obscure = false}) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
