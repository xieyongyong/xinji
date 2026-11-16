import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../data/employer.dart';
import '../data/employer_dao.dart';
import '../data/models.dart';
import '../data/record_dao.dart';
import '../data/salary_template.dart';
import '../data/salary_template_dao.dart';
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
  late SalaryTemplateDao salaryTemplateDao;
  late EmployerDao employerDao;
  final OcrService ocr = OcrService();

  List<PayRecord> records = [];
  List<ItemTemplate> templates = [];

  /// 雇主档案（跳槽后新旧工资条并存）
  List<Employer> employers = [];

  /// 当前在看哪家公司的数据。持久化，下次打开还是它。
  int? currentEmployerId;

  static const String _kCurrentEmployer = 'current_employer_id';

  /// 发薪模板（可多套，仅一套生效）
  List<SalaryTemplate> salaryTemplates = [];
  SalaryTemplate? activeSalaryTemplate;

  bool loading = true;

  /// 上次备份时间（毫秒），用于首页提醒
  int? lastBackupAt;

  Future<void> init() async {
    final db = await AppDb.instance;
    recordDao = RecordDao(db);
    templateDao = TemplateDao(db);
    salaryTemplateDao = SalaryTemplateDao(db);
    employerDao = EmployerDao(db);

    employers = await employerDao.loadAll();
    if (employers.isEmpty) {
      // 理论上建库时已经预置了一家；万一被删光，补一家回来，
      // 否则录入页没有任何雇主可选
      final id = await employerDao.insert(Employer(name: '我的公司'));
      employers = await employerDao.loadAll();
      if (employers.isEmpty) {
        throw StateError('雇主初始化失败');
      }
      await employerDao.assignOrphans(employers.first.id ?? id);
    } else {
      // 兜底：没挂雇主的记录归到第一家，绝不让数据在筛选视图里"消失"
      await employerDao.assignOrphans(employers.first.id!);
    }

    await _restoreCurrentEmployer();
    await reload();
    loading = false;
    notifyListeners();
  }

  Future<void> _restoreCurrentEmployer() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getInt(_kCurrentEmployer);
    final valid = employers.any((e) => e.id == saved);
    currentEmployerId = valid ? saved : employers.first.id;
  }

  Future<void> reload() async {
    records = await recordDao.loadAll();
    templates = await templateDao.loadAll();
    salaryTemplates = await salaryTemplateDao.loadAll();
    activeSalaryTemplate = await salaryTemplateDao.activeTemplate();
    employers = await employerDao.loadAll();
    // 当前雇主被删了要兜住，否则所有筛选视图都会变成空白
    if (employers.isNotEmpty && !employers.any((e) => e.id == currentEmployerId)) {
      currentEmployerId = employers.first.id;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ 雇主

  Employer? get currentEmployer {
    for (final e in employers) {
      if (e.id == currentEmployerId) return e;
    }
    return employers.isEmpty ? null : employers.first;
  }

  Employer? employerById(int? id) {
    if (id == null) return null;
    for (final e in employers) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 当前雇主名下的记录（首页/年度/对比都只看这份）
  List<PayRecord> get scopedRecords {
    final id = currentEmployer?.id;
    if (id == null) return records;
    return records.where((r) => r.employerId == id).toList();
  }

  Future<void> switchEmployer(int id) async {
    if (currentEmployerId == id) return;
    currentEmployerId = id;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kCurrentEmployer, id);
  }

  /// 录入某个月时，默认该选哪家：
  /// 优先"当前雇主且该月在职"，其次"该月在职的任一家"，最后当前雇主
  Employer? employerForPeriod(int year, int month) {
    final cur = currentEmployer;
    if (cur != null && cur.covers(year, month)) return cur;
    for (final e in employers) {
      if (e.covers(year, month)) return e;
    }
    return cur;
  }

  Future<void> addEmployer(Employer e) async {
    await employerDao.insert(e);
    await reload();
  }

  Future<void> updateEmployer(Employer e) async {
    await employerDao.update(e);
    await reload();
  }

  /// 删除雇主。它名下的记录必须先迁到 [moveTo]，否则一律拒绝删除。
  Future<void> deleteEmployer(int id, {required int moveTo}) async {
    if (id == moveTo) throw ArgumentError('不能迁移到自己');
    final wasCurrent = currentEmployerId == id;
    await employerDao.moveRecords(id, moveTo);
    await employerDao.delete(id);
    await reload();
    // reload 会把"已失效的当前雇主"重置成第一家，所以这里按删除前的状态补一刀
    if (wasCurrent) await switchEmployer(moveTo);
  }

  Future<int> countRecordsOf(int employerId) => employerDao.countRecords(employerId);

  // ------------------------------------------------------------ 查询

  /// 所有出现过的年份（倒序），用于年份切换。只统计当前雇主。
  List<int> get years {
    final set = scopedRecords.map((e) => e.periodYear).toSet().toList();
    set.sort((a, b) => b.compareTo(a));
    if (set.isEmpty) set.add(DateTime.now().year);
    // 保证当年一定在列表里，方便录入新一年的数据
    final now = DateTime.now().year;
    if (!set.contains(now)) set.insert(0, now);
    return set;
  }

  List<PayRecord> recordsOfYear(int year) =>
      scopedRecords.where((e) => e.periodYear == year).toList();

  /// 某年某月的所有记录（同月可能多笔：正常发放 + 补发）
  List<PayRecord> recordsOfMonth(int year, int month) => scopedRecords
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
      final OcrText recognized;
      try {
        recognized = await ocr.recognizeFile(path);
      } on OcrException catch (e) {
        // 带上"第几张"，用户才知道该重新截哪一张
        throw OcrException('第 ${i + 1} 张图识别失败：${e.message}');
      } catch (e) {
        throw OcrException('第 ${i + 1} 张图识别失败：$e');
      }
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
    List<PayImage> images, [
    List<PayInfo> infos = const [],
  ]) async {
    final items = <PayItem>[
      for (var i = 0; i < drafts.length; i++)
        drafts[i].toPayItem(sortOrder: i),
    ];
    final id = await recordDao.insert(record, items, images, infos);
    await reload();
    return id;
  }

  Future<void> updateRecord(
    PayRecord record,
    List<PayItemDraft> drafts,
    List<PayImage> images, [
    List<PayInfo> infos = const [],
  ]) async {
    final items = <PayItem>[
      for (var i = 0; i < drafts.length; i++) drafts[i].toPayItem(sortOrder: i),
    ];
    await recordDao.update(record, items, images, infos);
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

  // ------------------------------------------------------------ 发薪模板

  Future<void> saveSalaryTemplate(SalaryTemplate t) async {
    if (t.id == null) {
      await salaryTemplateDao.insert(t);
    } else {
      await salaryTemplateDao.update(t);
    }
    await reload();
  }

  Future<void> deleteSalaryTemplate(int id) async {
    await salaryTemplateDao.delete(id);
    await reload();
  }

  Future<void> activateSalaryTemplate(int id) async {
    await salaryTemplateDao.setActive(id);
    await reload();
  }

  @override
  void dispose() {
    ocr.dispose();
    super.dispose();
  }
}
