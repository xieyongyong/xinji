import 'package:flutter/material.dart';

import '../core/app_update.dart';
import 'theme.dart';

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
  // 线路选择放在弹窗内，默认读用户上次选的（首次是 gh-proxy.com）
  String lineId = await UpdateChecker.preferredLineId();
  if (!context.mounted) return false;

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_alt, size: 20, color: kIncomeFg),
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
                style: TextStyle(fontSize: 12.5, color: kTextSecondary),
              ),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kSurfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    release.notes,
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '点「立即更新」后会在后台下载，期间可以照常使用 App；'
                '下载完在首页点一下即可安装，数据原样保留。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: kTextHint),
              ),
              const SizedBox(height: 12),
              // 线路选择：StatefulBuilder 只重建这一小块，不动外面的 release 文案
              StatefulBuilder(
                builder: (dialogCtx, setDialogState) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: kSurfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.alt_route, size: 14, color: kTextSecondary),
                          const SizedBox(width: 6),
                          Text('下载线路（失败会自动换下一条）',
                              style: TextStyle(fontSize: 11.5, color: kTextSecondary)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final l in UpdateChecker.lines)
                            ChoiceChip(
                              label: Text(l.label,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: lineId == l.id
                                          ? Colors.white
                                          : kTextBody)),
                              selected: lineId == l.id,
                              selectedColor: kSeed,
                              backgroundColor: kSurface,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              onSelected: (_) async {
                                setDialogState(() => lineId = l.id);
                                await UpdateChecker.setPreferredLine(l.id);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '默认 gh-proxy.com 加速；选「官方直链」则直接从 GitHub 下载。'
                        '第三方代理能看到你的下载请求，介意的话请选官方直链。',
                        style: TextStyle(fontSize: 10.5, height: 1.5, color: kTextHint),
                      ),
                    ],
                  ),
                ),
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
    await UpdateDownloadController.instance.start(release, preferredLine: lineId);
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
