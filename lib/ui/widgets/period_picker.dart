import 'package:flutter/material.dart';

import '../theme.dart';

/// 年月选择对话框。
///
/// 为什么抽成公共组件：导入页（选这笔工资属于哪个月）和校对页（改月份）
/// 都要用，而且必须长得一样 —— 用户在两处看到不同的选择器会怀疑"是不是改的不是同一个东西"。
class PeriodPickerDialog extends StatefulWidget {
  final int year;
  final int month;

  /// 允许选到未来月份吗？
  ///
  /// 导入工资条时不需要（工资还没发），但录入奖金也偶尔会提前记，
  /// 所以默认允许，只是把未来的月份标个「未到」提示。
  final bool allowFuture;

  const PeriodPickerDialog({
    super.key,
    required this.year,
    required this.month,
    this.allowFuture = true,
  });

  @override
  State<PeriodPickerDialog> createState() => _PeriodPickerDialogState();
}

class _PeriodPickerDialogState extends State<PeriodPickerDialog> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    _year = widget.year;
    _month = widget.month;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return AlertDialog(
      title: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _year--),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text('$_year 年', textAlign: TextAlign.center),
          ),
          IconButton(
            onPressed: () => setState(() => _year++),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          childAspectRatio: 1.5,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: List.generate(12, (i) {
            final m = i + 1;
            final selected = m == _month;
            final future = !widget.allowFuture &&
                (_year > now.year || (_year == now.year && m > now.month));
            return InkWell(
              onTap: future ? null : () => setState(() => _month = m),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? kSeed : const Color(0xFFF2F4F2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$m月',
                  style: TextStyle(
                    fontSize: 13,
                    color: future
                        ? const Color(0xFFC4C9C4)
                        : (selected ? Colors.white : const Color(0xFF4A4F4A)),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (year: _year, month: _month)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
