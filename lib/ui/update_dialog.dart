import 'package:flutter/material.dart';

import '../core/app_update.dart';

/// 发现新版本时的弹窗。
///
/// [auto] = true 表示这是启动时自动查到的：用户选「以后再说」就记下这个版本，
/// 之后不再为同一个版本弹第二次（不然每次开 App 都被拦一下很烦）。
///
/// 返回值 true 表示用户点了「去下载」。
Future<bool> showUpdateDialog(
  BuildContext context,
  ReleaseInfo release, {
  required String currentVersion,
  bool auto = false,
}) async {
  final go = await showDialog<bool>(
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
                '覆盖安装即可，工资数据、模板和图片都会保留（版本号只增不减）。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: Color(0xFF9AA09A)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(auto ? '以后再说' : '关闭'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去下载'),
        ),
      ],
    ),
  );

  if (go != true) {
    if (auto) await UpdateChecker.skipVersion(release.version);
    return false;
  }

  try {
    // 直接开 APK 直链：浏览器会立刻开始下载，下完点一下就是安装
    await UpdateChecker.openUrl(release.apkUrl);
  } catch (e) {
    // 打不开浏览器基本只有一种情况：系统没有默认浏览器
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能打开浏览器：$e')),
      );
    }
    return false;
  }
  return true;
}
