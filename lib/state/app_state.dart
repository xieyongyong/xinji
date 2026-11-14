import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/record_dao.dart';
import '../data/template_dao.dart';
import '../ocr/field_parser.dart';
import '../ocr/merge_engine.dart';
import '../ocr/ocr_models.dart';
import '../ocr/ocr_service.dart';

/// 一次识别流程的完整产出，交给校对页用
class RecognizeOutcome {
  final MergeResult result;

  /// 每张图的解析明细（校对页要显示缩略图、原文、从哪张图来的）
  final List<ParsedImage> images;

  RecognizeOutcome(this.result, this.images);
}

/// 全局状态。用 ChangeNotifier + provider 就够了：
/// 页面不多，没必要上 Riverpod 那套。
class AppState extends ChangeNotifier {
  late RecordDao recordDao;
  late TemplateDao templateDao;
  final OcrService ocr = OcrService();

  List<PayRecord> records = [];
  List<ItemTemplate> templates = [];
  bool loading = true;

  /// 上次备份时间（毫秒），用于首页提醒
  int? lastBackupAt;

  Future<void> init() async {
    final db = await AppDb.instance;
    recordDao = RecordDao(db);
    templateDao = TemplateDao(db);
    await reload();
    loading = false;
    notifyListeners();
  }

  Future<void> reload() async {
    records = await recordDao.loadAll();
    templates = await templateDao.loadAll();
    notifyListeners();
  }

  // ------------------------------------------------------------ 查询

  /// 所有出现过的年份（倒序），用于年份切换
  List<int> get years {
    final set = records.map((e) => e.periodYear).toSet().toList();
    set.sort((a, b) => b.compareTo(a));
    if (set.isEmpty) set.add(DateTime.now().year);
    // 保证当年一定在列表里，方便录入新一年的数据
    final now = DateTime.now().year;
    if (!set.contains(now)) set.insert(0, now);
    return set;
  }

  List<PayRecord> recordsOfYear(int year) =>
      records.where((e) => e.periodYear == year).toList();

  /// 某年某月的所有记录（同月可能多笔：正常发放 + 补发）
  List<PayRecord> recordsOfMonth(int year, int month) => records
      .where((e) => e.periodYear == year && e.periodMonth == month)
      .toList();

  PayRecord? recordById(int id) {
    for (final r in records) {
      if (r.id == id) return r;
    }
    return null;
  }

  // ------------------------------------------------------------ OCR

  /// 多图 -> 识别 -> 合并。整个过程离线完成。
  Future<RecognizeOutcome> recognizeImages(List<String> filePaths) async {
    final parser = FieldParser(templates);
    final parsed = <ParsedImage>[];

    for (var i = 0; i < filePaths.length; i++) {
      final path = filePaths[i];
      final recognized = await ocr.recognizeFile(path);
      parsed.add(parser.parseImage(
        index: i,
        filePath: path,
        lines: recognized.lines,
        rawText: recognized.fullText,
      ));
    }

    final engine = MergeEngine(templates);
    final merged = engine.merge(parsed);
    return RecognizeOutcome(merged, parsed);
  }

  /// 把用户选的原图收进私有目录（顺便压缩），返回新路径
  Future<String> importImage(File source, int index) =>
      ocr.importImage(source, fileNameHint: 'p$index');

  // ------------------------------------------------------------ 写操作

  Future<int> insertRecord(
    PayRecord record,
    List<PayItemDraft> drafts,
    List<PayImage> images,
  ) async {
    final items = <PayItem>[
      for (var i = 0; i < drafts.length; i++)
        drafts[i].toPayItem(sortOrder: i),
    ];
    final id = await recordDao.insert(record, items, images);
    await reload();
    return id;
  }

  Future<void> updateRecord(
    PayRecord record,
    List<PayItemDraft> drafts,
    List<PayImage> images,
  ) async {
    final items = <PayItem>[
      for (var i = 0; i < drafts.length; i++) drafts[i].toPayItem(sortOrder: i),
    ];
    await recordDao.update(record, items, images);
    await reload();
  }

  Future<void> deleteRecord(int id) async {
    await recordDao.delete(id);
    await reload();
  }

  // ------------------------------------------------------------ 模板

  Future<void> saveTemplate(ItemTemplate t) async {
    if (t.id == null) {
      await templateDao.insert(t);
    } else {
      await templateDao.update(t);
    }
    await reload();
  }

  Future<void> deleteTemplate(int id) async {
    await templateDao.delete(id);
    await reload();
  }

  @override
  void dispose() {
    ocr.dispose();
    super.dispose();
  }
}
