import 'package:flutter/material.dart';

import '../../core/app_update.dart';

/// 首页顶部的一条细进度指示：下载时不遮挡任何操作，完成后变成可点的安装条。
///
/// 刻意做成"贴边的一条"而不是弹窗/全屏页：
/// 用户点了更新之后还想继续查工资、录数据，强制停在更新页等于打断工作。
class UpdateProgressStrip extends StatefulWidget {
  const UpdateProgressStrip({super.key});

  @override
  State<UpdateProgressStrip> createState() => _UpdateProgressStripState();
}

class _UpdateProgressStripState extends State<UpdateProgressStrip> {
  @override
  void initState() {
    super.initState();
    UpdateDownloadController.instance.attach();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: UpdateDownloadController.instance,
      builder: (context, _) {
        final c = UpdateDownloadController.instance;
        final s = c.state;
        switch (s.status) {
          case UpdateState.downloading:
            return SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                value: s.progress > 0 ? s.progress / 100.0 : null,
                backgroundColor: const Color(0xFFE7EBE7),
                color: const Color(0xFF3F6B4C),
                minHeight: 3,
              ),
            );

          case UpdateState.done:
            if (!c.showDoneBanner) return const SizedBox.shrink();
            return _banner(
              icon: Icons.system_update_alt,
              color: const Color(0xFFE8F3EA),
              textColor: const Color(0xFF2E5C3C),
              text: '新版本 ${s.version} 已下载完成，点这里安装',
              onTap: () => c.install(),
              onClose: c.hideBanner,
            );

          case UpdateState.failed:
            if (!c.showFailedBanner) return const SizedBox.shrink();
            return _banner(
              icon: Icons.error_outline,
              color: const Color(0xFFFBECEC),
              textColor: const Color(0xFF9C3B3B),
              text: '更新下载失败：${s.error ?? "未知原因"}',
              onTap: null,
              onClose: c.hideBanner,
            );

          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  Widget _banner({
    required IconData icon,
    required Color color,
    required Color textColor,
    required String text,
    required VoidCallback? onTap,
    required VoidCallback onClose,
  }) {
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 16, color: textColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: textColor),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  color: textColor,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
