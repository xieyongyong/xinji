import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../core/crash_log.dart';
import '../data/models.dart';
import '../ocr/ocr_service.dart';
import '../state/app_state.dart';
import 'review_page.dart';
import 'theme.dart';
import 'widgets/period_picker.dart';

/// 导入入口：选图 / 拍照 / 手动
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  String _recordType = kTypeMonthly;
  bool _busy = false;
  String _busyText = '';
  final ImagePicker _picker = ImagePicker();

  /// 这笔工资属于哪个月：默认当前月，用户可先改好再选图
  late int _year;
  late int _month;

  /// 用户是否**手动**改过月份。
  ///
  /// 改过就以他为准；没动过则识别出工资条标题上的月份后自动采用 ——
  /// 没截到标题的月份截图也能正确归月，不用用户自己算。
  bool _periodPicked = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  Future<void> _pickPeriod() async {
    final r = await showDialog<({int year, int month})>(
      context: context,
      builder: (_) => PeriodPickerDialog(year: _year, month: _month),
    );
    if (r == null || !mounted) return;
    setState(() {
      _year = r.year;
      _month = r.month;
      _periodPicked = true;
    });
  }

  // ------------------------------------------------------------ 选图

  Future<void> _pickFromGallery() async {
    try {
      // 不传 imageQuality！传了的话 image_picker 会在原生侧把整张图
      // 解码 → 压缩 → 再编码，1080×12000 的长截图在这一步就被系统 kill 了，
      // 跟 OCR 一点关系都没有，所以之前怎么优化识别都还是闪退。
      final files = await _picker.pickMultiImage();
      if (files.isEmpty) return;
      await _process(files.map((e) => File(e.path)).toList());
    } catch (e) {
      _error('打开相册失败：$e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final file = await _picker.pickImage(source: ImageSource.camera);
      if (file == null) return;
      await _process([File(file.path)]);
    } catch (e) {
      _error('拍照失败：$e');
    }
  }

  void _error(String msg) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 收图 -> 压缩入库 -> 逐张 OCR -> 合并 -> 进校对页
  ///
  /// 容错原则：**识别失败不等于流程失败**。图片已经存进私有目录了，
  /// 就算 OCR 挂了也要让用户接着手动填，不能让他重新截图。
  Future<void> _process(List<File> files) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyText = '正在保存图片…';
    });

    final state = context.read<AppState>();
    final settings = context.read<AppSettings>();
    final originals = <String>[];
    final paths = <String>[];

    try {
      for (var i = 0; i < files.length; i++) {
        if (!mounted) return;
        setState(() => _busyText = '正在处理第 ${i + 1}/${files.length} 张…');
        originals.add(files[i].path);
        paths.add(await state.importImage(
          files[i],
          i,
          compress: settings.compressImages,
        ));
      }
    } catch (e) {
      _error('保存图片失败：$e');
      return;
    }

    if (!mounted) return;
    setState(() => _busyText = files.length > 1 ? '正在合并 ${files.length} 张截图…' : '正在识别文字…');

    RecognizeOutcome? outcome;
    String? failReason;
    try {
      // 识别读原图（字最清楚），记录里存归档副本（私有的、不会被系统清掉）
      outcome = await state.recognizeImages(
        originals,
        keepPaths: paths,
        deWatermark: settings.deWatermark,
      );
    } catch (e) {
      failReason = e is OcrException ? e.message : '$e';
      CrashLog.note('识别失败：$failReason');
    }

    if (!mounted) return;
    setState(() => _busy = false);

    if (outcome == null) {
      final manual = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('自动识别没成功'),
          content: Text(
            '${failReason ?? '识别过程出错了'}\n\n'
            '图片已经保存好了，可以直接手动填这一张（字段会按模板预填），不用重新截图。',
            style: const TextStyle(fontSize: 13.5, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('重来'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('手动填'),
            ),
          ],
        ),
      );
      if (manual != true || !mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ReviewPage.create(
            year: _year,
            month: _month,
            recordType: _recordType,
            imagePaths: paths,
          ),
        ),
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
      return;
    }

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewPage.fromOutcome(
          outcome: outcome!,
          recordType: _recordType,
          fallbackYear: _year,
          fallbackMonth: _month,
          honorDetectedPeriod: !_periodPicked,
        ),
      ),
    );
    if (saved == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导入')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text('记录类型', style: TextStyle(fontSize: 13, color: kTextSecondary)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: kTypeMonthly,
                    label: Text('月度工资'),
                    icon: Icon(Icons.calendar_month_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: kTypeExtra,
                    label: Text('奖金 / 其他'),
                    icon: Icon(Icons.card_giftcard, size: 18),
                  ),
                ],
                selected: {_recordType},
                onSelectionChanged: (s) => setState(() => _recordType = s.first),
              ),
              const SizedBox(height: 16),
              _periodCard(),
              const SizedBox(height: 18),
              _bigAction(
                icon: Icons.photo_library_outlined,
                title: '从相册选择',
                subtitle: '可一次选多张，重叠的重复行会自动合并',
                onTap: _busy ? null : _pickFromGallery,
              ),
              const SizedBox(height: 12),
              _bigAction(
                icon: Icons.photo_camera_outlined,
                title: '拍照',
                subtitle: '纸质工资条也可以拍，注意光线和角度',
                onTap: _busy ? null : _takePhoto,
              ),
              const SizedBox(height: 20),
              Center(
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final saved = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => ReviewPage.create(
                                year: _year,
                                month: _month,
                                recordType: _recordType,
                              ),
                            ),
                          );
                          if (saved == true && context.mounted) Navigator.of(context).pop(true);
                        },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('不用图片，手动录入'),
                ),
              ),
              const SizedBox(height: 12),
              _tipsCard(),
            ],
          ),
          if (_busy)
            Container(
              color: Colors.black.withOpacity(0.35),
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(height: 16),
                    Text(_busyText, style: const TextStyle(fontSize: 13.5)),
                    const SizedBox(height: 4),
                    Text('全程离线处理，图片不会上传',
                        style: TextStyle(fontSize: 11.5, color: kTextHint)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 归属月份。
  ///
  /// 为什么要在"选图之前"就让它可见：工资条是分几张截的，
  /// 月份只写在标题那一张上，用户选图前根本想不起来对不对；
  /// 把月份摆在最上面，他顺手就能改，也不至于存完才发现记到别的月了。
  Widget _periodCard() {
    return InkWell(
      onTap: _busy ? null : _pickPeriod,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: cardDecoration(),
        child: Row(
          children: [
            Icon(Icons.event_note_outlined, size: 20, color: kSeed),
            const SizedBox(width: 12),
            const Text('这笔工资属于', style: TextStyle(fontSize: 13.5)),
            const Spacer(),
            Text(
              '$_year 年 $_month 月',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: kTextPrimary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: kTextFaint),
          ],
        ),
      ),
    );
  }

  Widget _bigAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: cardDecoration(),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: kInfoBg,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: kSeed, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(fontSize: 12, color: kTextSecondary, height: 1.4)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: kTextFaint),
          ],
        ),
      ),
    );
  }

  Widget _tipsCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kInfoBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('截图小技巧',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kSeed)),
          SizedBox(height: 6),
          Text(
            '· 明细太长就分几张截，相邻两张留一两行重叠，合并最准\n'
            '· 尽量按区块切（收入一块、扣款一块），别从一行金额中间切开\n'
            '· 识别结果会预填到表单，请扫一眼再保存',
            style: TextStyle(fontSize: 12, height: 1.7, color: kInfoText),
          ),
        ],
      ),
    );
  }
}
