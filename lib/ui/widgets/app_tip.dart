import 'package:flutter/material.dart';

/// 全 App 统一的轻提示：SnackBar + 关闭按钮。
///
/// 之前各处 SnackBar 只有 content，没有关闭入口，用户想手关都没按钮，
/// 只能干等自动消失。统一走这里，保证每个提示都能点「关闭」立即收起。
void showTip(
  BuildContext context,
  String msg, {
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: duration,
        action: SnackBarAction(
          label: '关闭',
          onPressed: () => messenger.hideCurrentSnackBar(),
        ),
      ),
    );
}
