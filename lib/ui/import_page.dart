import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'review_page.dart';
import 'theme.dart';

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

  // ------------------------------------------------------------ 选图

  Future<void> _pickFromGallery() async {
    try {
      final files = await _picker.pickMultiImage(imageQuality: 100);
      if (files.isEmpty) return;
      await _process(files.map((e) => File(e.path)).toList());
    } catch (e) {
      _error('打开相册失败：$e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final file = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
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
  Future<void> _process(List<File> files) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyText = '正在保存图片…';
    });

    try {
      final state = context.read<AppState>();
      final paths = <String>[];

      for (var i = 0; i < files.length; i++) {
        if (!mounted) return;
        setState(() => _busyText = '正在处理第 ${i + 1}/${files.length} 张…');
        paths.add(await state.importImage(files[i], i));
      }

      if (!mounted) return;
      setState(() => _busyText = files.length > 1 ? '正在合并 ${files.length} 张截图…' : '正在识别文字…');

      final outcome = await state.recognizeImages(paths);
      if (!mounted) return;

      setState(() => _busy = false);

      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ReviewPage.fromOutcome(
            outcome: outcome,
            recordType: _recordType,
          ),
        ),
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _error('识别出错：$e');
    }
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
              const Text('记录类型', style: TextStyle(fontSize: 13, color: Color(0xFF8A8F8A))),
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
              const SizedBox(height: 22),
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
                          final now = DateTime.now();
                          final saved = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => ReviewPage.create(
                                year: now.year,
                                month: now.month,
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
                  color: Colors.white,
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
                    const Text('全程离线处理，图片不会上传',
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF9AA09A))),
                  ],
                ),
              ),
            ),
        ],
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
                      style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F8A), height: 1.4)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFC4C9C4)),
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
        children: const [
          Text('截图小技巧',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kSeed)),
          SizedBox(height: 6),
          Text(
            '· 明细太长就分几张截，相邻两张留一两行重叠，合并最准\n'
            '· 尽量按区块切（收入一块、扣款一块），别从一行金额中间切开\n'
            '· 识别结果会预填到表单，请扫一眼再保存',
            style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xFF3D5A54)),
          ),
        ],
      ),
    );
  }
}
