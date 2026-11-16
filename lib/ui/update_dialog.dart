import 'package:flutter/material.dart';

import '../core/app_update.dart';

/// 发现新版本时的弹窗。
///
/// [auto] = true 表示这是启动时自动查到的：用户选「以后再说」就记下这个版本，
/// 之后不再为同一个版本弹第二次（不然每次开 App 都被拦一下很烦）。
///
/// 返回值 true 表示用户选择了某种更新方式。
///
/// ## 默认不跳浏览器
/// 「立即更新」只是**启动原生后台下载**，立刻关掉弹窗；下载在独立的前台服务里跑，
/// 用户可以继续查工资。完成后首页顶部出现一条「点此安装」，
/// 点它才调系统安装器 —— 不会在用户正录数据的时候突然弹安装页。
Future<bool> showUpdateDialog(
  BuildContext context,
  ReleaseInfo release, {
  required String currentVersion,
  bool auto = false,
}) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update_alt, size: 20, color: Color(0xFF3F6B4C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('发现新版本 ${release.version}',
                style: const TextStyle(fontSize: 16)),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前 $currentVersion  →  最新 ${release.version}'
                '${release.dateLabel.isEmpty ? '' : '（${release.dateLabel}）'}',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A)),
              ),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F6F4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    release.notes,
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                '点「立即更新」后会在后台下载，期间可以照常使用 App；'
                '下载完在首页点一下即可安装，数据原样保留。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: Color(0xFF9AA09A)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'later'),
          child: Text(auto ? '以后再说' : '关闭'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'browser'),
          child: const Text('浏览器下载', style: TextStyle(fontSize: 12.5)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'background'),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );

  if (choice == null || choice == 'later') {
    if (auto) await UpdateChecker.skipVersion(release.version);
    return false;
  }

  if (choice == 'browser') {
    try {
      await UpdateChecker.openUrl(release.apkUrl);
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('没能打开浏览器：$e')),
        );
      }
      return false;
    }
  }

  try {
    await UpdateDownloadController.instance.start(release);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能启动后台下载：$e')),
      );
    }
    return false;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已在后台下载，可以继续用 App；下载完在首页点「安装」'),
        duration: Duration(seconds: 4),
      ),
    );
  }
  return true;
}
