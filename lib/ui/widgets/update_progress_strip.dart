import 'package:flutter/material.dart';

import '../../core/app_update.dart';
import '../theme.dart';

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
            return _downloading(c, s);

          case UpdateState.done:
            if (!c.showDoneBanner) return const SizedBox.shrink();
            return _banner(
              icon: Icons.system_update_alt,
              color: kInfoBg,
              textColor: kInfoText,
              text: '新版本 ${s.version} 已下载完成，点这里安装',
              onTap: () => c.install(),
              onClose: c.hideBanner,
            );

          case UpdateState.failed:
            if (!c.showFailedBanner) return const SizedBox.shrink();
            return _banner(
              icon: Icons.error_outline,
              color: kWarnBg,
              textColor: kUp,
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

  /// 下载中的浮层条：进度 + 百分比 + 速度 + 剩余时间，贴底不挡主内容。
  Widget _downloading(UpdateDownloadController c, UpdateState s) {
    final pct = s.progress > 0 ? s.progress / 100.0 : null;
    final speed = c.bytesPerSec;
    final remain = c.remainingSeconds;
    final detail = <String>[
      if (s.progress > 0) '${s.progress}%',
      if (speed > 0) _speedLabel(speed),
      if (remain != null) '剩余 ${_durationLabel(remain)}',
    ].join(' · ');

    return Material(
      color: kSurface,
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          border: Border(top: BorderSide(color: kBorder)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.system_update_alt, size: 16, color: kSeed),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        detail.isEmpty ? '正在下载新版本…' : detail,
                        style: TextStyle(fontSize: 12, color: kTextBody),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, size: 16, color: kTextHint),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                      tooltip: '取消下载',
                      onPressed: c.cancel,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: pct,
                  backgroundColor: kSurfaceAlt,
                  color: kSeed,
                  minHeight: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _speedLabel(int bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSec / 1024).round()} KB/s';
  }

  String _durationLabel(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    if (m < 60) return '$m 分钟';
    return '${m ~/ 60} 小时 ${m % 60} 分';
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
