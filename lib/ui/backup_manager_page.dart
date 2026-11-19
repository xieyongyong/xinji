import 'package:flutter/material.dart';

import '../backup/backup_service.dart';
import '../data/db.dart';
import 'theme.dart';

/// 本地备份管理页。
///
/// 列出 App 私有 backups/ 目录里残留的历史备份，让用户能手动删除——
/// 这些文件在文件管理器里根本够不着（Android 应用沙箱），
/// 只能由 App 自己删。新导出的备份走公共 Download，不在私有目录堆积。
class BackupManagerPage extends StatefulWidget {
  const BackupManagerPage({super.key});

  @override
  State<BackupManagerPage> createState() => _BackupManagerPageState();
}

class _BackupManagerPageState extends State<BackupManagerPage> {
  BackupService? _service;
  List<BackupFileMeta> _files = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = await AppDb.instance;
      _service ??= BackupService(db);
      final files = await _service!.listLocalBackups();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _delete(BackupFileMeta f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这份备份？'),
        content: Text('${f.name}\n删除后无法恢复。', style: const TextStyle(height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: kUp),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service?.deleteLocalBackup(f.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已删除'),
        action: SnackBarAction(
          label: '关闭',
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地备份管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('读取备份失败：$_error',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: kTextSecondary)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: kInfoBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '这里列出的是以前存在 App 私有目录、你在文件管理器里删不掉的旧备份。'
            '现在新导出的备份会直接存到「下载」目录，能自己找到并删除，不会再堆在这里。',
            style: TextStyle(fontSize: 12, height: 1.7, color: kTextSecondary),
          ),
        ),
        const SizedBox(height: 12),
        if (_files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.folder_off_outlined, size: 44, color: kTextHint),
                  const SizedBox(height: 12),
                  Text('没有需要清理的旧备份',
                      style: TextStyle(fontSize: 13, color: kTextSecondary)),
                ],
              ),
            ),
          )
        else
          ..._files.map((f) => Card(
                child: ListTile(
                  leading: Icon(
                    f.name.endsWith('.xbk')
                        ? Icons.enhanced_encryption_outlined
                        : Icons.folder_zip_outlined,
                    color: kSeed,
                  ),
                  title: Text(f.name,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${(f.size / 1024).toStringAsFixed(0)} KB · '
                    '${f.modified.year}-'
                    '${f.modified.month.toString().padLeft(2, '0')}-'
                    '${f.modified.day.toString().padLeft(2, '0')} '
                    '${f.modified.hour.toString().padLeft(2, '0')}:'
                    '${f.modified.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 11, color: kTextHint),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: kUp, size: 21),
                    tooltip: '删除',
                    onPressed: () => _delete(f),
                  ),
                ),
              )),
      ],
    );
  }
}
