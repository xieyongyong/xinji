import 'package:flutter/material.dart';

import '../theme.dart';

/// 一个可复用的 ⓘ 说明角标。
///
/// 点击弹一个轻量说明浮层，用来替代"直接铺在页面/弹框里的灰色长解释"——
/// 避免把列表项或弹框高度撑得参差不齐。文字多长处都能收进这一个图标里。
class InfoHint extends StatelessWidget {
  final String text;
  final String? title;
  final double size;
  final Color? color;

  const InfoHint({
    super.key,
    required this.text,
    this.title,
    this.size = 15,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _show(context),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          Icons.info_outline,
          size: size,
          color: color ?? kTextHint,
        ),
      ),
    );
  }

  void _show(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title ?? '说明', style: const TextStyle(fontSize: 15)),
        content: SingleChildScrollView(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.7)),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 和 [InfoHint] 一样，但返回的是一个 Widget 而不是图标——
/// 用在"标题后面跟一个 ⓘ"的场景（如设置项 title 行）。
Widget infoHintInline(String text, {String? title, Color? color}) =>
    InfoHint(text: text, title: title, size: 14, color: color);
