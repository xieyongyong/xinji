import 'package:flutter/material.dart';

import '../core/app_update.dart';
import 'theme.dart';
import 'widgets/app_tip.dart';

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
  // 更新日志滚动条控制器：函数级持有，弹窗关闭后统一 dispose。
  final scrollCtrl = ScrollController();

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
      // 上面：限高的滚动区（版本说明 + 更新日志），带常驻侧边滚动条，不占满全屏。
      // 下面：固定的线路选择区，不随内容滚动，一点就选，不用拉到最下。
      content: StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    // 线路区改成一行下拉框后整体更紧凑，日志区可再看一点内容；
                    // 但仍限高，避免小屏上把「立即更新」挤出屏幕。
                    maxHeight: MediaQuery.of(dialogCtx).size.height * 0.28,
                  ),
                  child: Scrollbar(
                    controller: scrollCtrl,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: scrollCtrl,
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
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 线路选择：收进下拉框，只显示当前选中项，不再平铺四条撑高弹窗。
                // StatefulBuilder 只重建这一小块；改线路即时落盘，下次记住。
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: kSurfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.alt_route, size: 15, color: kTextSecondary),
                      const SizedBox(width: 8),
                      Text('下载线路', style: TextStyle(fontSize: 12, color: kTextSecondary)),
                      const Spacer(),
                      DropdownButton<String>(
                        value: lineId,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final l in UpdateChecker.lines)
                            DropdownMenuItem<String>(
                              value: l.id,
                              child: Text(l.label, style: const TextStyle(fontSize: 12.5)),
                            ),
                        ],
                        onChanged: (v) async {
                          if (v == null || v == lineId) return;
                          setDialogState(() => lineId = v);
                          await UpdateChecker.setPreferredLine(v);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
      // 按钮分两行：主操作「立即更新」独占一行撑满，次操作「浏览器下载/关闭」
      // 并排放在下一行。默认 actions 横排三按钮，窄屏上会挤到重叠、主次不分。
      actions: [
        SizedBox(
          width: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'background'),
                child: const Text('立即更新'),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, 'browser'),
                      child: const Text('浏览器下载', style: TextStyle(fontSize: 12.5)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, 'later'),
                      child: Text(auto ? '以后再说' : '关闭',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  scrollCtrl.dispose();

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
        showTip(context, '没能打开浏览器：$e');
      }
      return false;
    }
  }

  try {
    await UpdateDownloadController.instance.start(release, preferredLine: lineId);
  } catch (e) {
    if (context.mounted) {
      showTip(context, '没能启动后台下载：$e');
    }
    return false;
  }

  if (context.mounted) {
    showTip(context, '已在后台下载，可以继续用 App；下载完在首页点「安装」',
        duration: const Duration(seconds: 4));
  }
  return true;
}
