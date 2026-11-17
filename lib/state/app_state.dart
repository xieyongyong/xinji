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

  /// 工资条标题上写的归属年月（多图取多数），识别不到为 null。
  /// 只当默认值用——校对页永远可以改。
  final int? periodYear;
  final int? periodMonth;

  RecognizeOutcome(this.result, this.images, {this.periodYear, this.periodMonth});
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

  /// 发薪模板。归属关系：雇主 → 多套模板，各自一套生效。
  List<SalaryTemplate> salaryTemplates = [];

  bool loading = true;

  /// 当前雇主名下的记录与年份：在 reload()/switchEmployer()/init() 时算好缓存，
  /// 避免 getter 在首页 build 里被连调 4 次时每次都 where().toList()。
  List<PayRecord> _scopedRecords = const [];
  List<int> _years = const [];

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

  Future<void> reload({bool rereadCurrentEmployer = false}) async {
    records = await recordDao.loadAll();
    templates = await templateDao.loadAll();
    salaryTemplates = await salaryTemplateDao.loadAll();
    employers = await employerDao.loadAll();
    // 恢复备份后按 sp 里的最新值重选当前雇主（_restoreCurrentEmployer 自带有效性校验）
    if (rereadCurrentEmployer) await _restoreCurrentEmployer();
    // 当前雇主被删了要兜住，否则所有筛选视图都会变成空白
    if (employers.isNotEmpty && !employers.any((e) => e.id == currentEmployerId)) {
      currentEmployerId = employers.first.id;
    }
    _recomputeScoped();
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

  /// 当前雇主名下的记录（首页/年度/对比都只看这份）。返回 reload 时算好的缓存。
  List<PayRecord> get scopedRecords => _scopedRecords;

  /// records/employers/currentEmployerId 变化后重算缓存。所有写路径结尾都要调。
  void _recomputeScoped() {
    final id = currentEmployer?.id;
    _scopedRecords = id == null
        ? List.unmodifiable(records)
        : records.where((r) => r.employerId == id).toList(growable: false);
    final set = _scopedRecords.map((e) => e.periodYear).toSet().toList();
    set.sort((a, b) => b.compareTo(a));
    if (set.isEmpty) set.add(DateTime.now().year);
    final now = DateTime.now().year;
    if (!set.contains(now)) set.insert(0, now);
    _years = List.unmodifiable(set);
  }

  Future<void> switchEmployer(int id) async {
    if (currentEmployerId == id) return;
    currentEmployerId = id;
    _recomputeScoped();
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
    // 新雇主一开始没有任何模板 → 录入页会是空表单。
    // 把当前生效模板复制一份过去，用户再按新公司的工资条改，
    // 比从零加十几个字段省事得多。
    final source = activeSalaryTemplate;
    final id = await employerDao.insert(e);
    if (source != null && source.fields.isNotEmpty) {
      await salaryTemplateDao.insert(SalaryTemplate(
        employerId: id,
        name: source.name,
        fields: source.fields
            .map((f) => TemplateField(
                  name: f.name,
                  category: f.category,
                  valueType: f.valueType,
                ))
            .toList(),
      ));
    }
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
    // 模板跟着一起迁：留在已删除的雇主名下就成了永远的孤儿，
    // 既看不到也用不上
    await salaryTemplateDao.moveToEmployer(id, moveTo);
    await employerDao.delete(id);
    await reload();
    // reload 会把"已失效的当前雇主"重置成第一家，所以这里按删除前的状态补一刀
    if (wasCurrent) await switchEmployer(moveTo);
  }

  Future<int> countRecordsOf(int employerId) => employerDao.countRecords(employerId);

  // ------------------------------------------------------------ 查询

  /// 所有出现过的年份（倒序），用于年份切换。只统计当前雇主。缓存字段。
  List<int> get years => _years;

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
  ///
  /// [filePaths] 是**拿来做识别**的图（建议用相册原图，字最清楚）；
  /// [keepPaths] 是**要留在记录里**的图（归档压缩后的）。
  /// 两者分开是因为：归档为了省空间可能降过采样，识别精度不该被它拖累，
  /// 而记录里必须存私有目录的副本 —— 相册/缓存里的原图随时会被系统清掉。
  Future<RecognizeOutcome> recognizeImages(
    List<String> filePaths, {
    List<String>? keepPaths,
    bool deWatermark = true,
  }) async {
    final parser = FieldParser(templates);
    final parsed = <ParsedImage>[];

    // 一次把整批交给原生（独立进程）。万一那边崩了，这里收到的是普通异常，
    // 不是"整个 App 消失"；图片早就在上一步存好了，用户可以直接手动填。
    final recognized = await _recognizeAll(
      filePaths,
      deWatermark: deWatermark,
    );

    for (var i = 0; i < filePaths.length; i++) {
      final path = filePaths[i];
      final keep = (keepPaths != null && i < keepPaths.length && keepPaths[i].isNotEmpty)
          ? keepPaths[i]
          : path;
      parsed.add(parser.parseImage(
        index: i,
        filePath: keep,
        lines: recognized[i].lines,
        rawText: recognized[i].fullText,
      ));
    }

    final engine = MergeEngine(templates);
    final merged = engine.merge(parsed);

    // 归属年月：多张图里出现最多的那个组合（标题只会在其中一张上）
    final votes = <String, int>{};
    final byKey = <String, ({int year, int month})>{};
    for (final img in parsed) {
      final y = img.periodYear;
      final m = img.periodMonth;
      if (y == null || m == null) continue;
      final k = '$y-$m';
      votes[k] = (votes[k] ?? 0) + 1;
      byKey[k] = (year: y, month: m);
    }
    ({int year, int month})? period;
    var bestCount = 0;
    for (final e in votes.entries) {
      if (e.value > bestCount) {
        bestCount = e.value;
        period = byKey[e.key];
      }
    }

    return RecognizeOutcome(
      merged,
      parsed,
      periodYear: period?.year,
      periodMonth: period?.month,
    );
  }

  /// 把用户选的原图收进私有目录（是否压缩由设置决定），返回新路径
  Future<String> importImage(File source, int index, {bool compress = true}) =>
      ocr.importImage(source, fileNameHint: 'p$index', compress: compress);

  /// 识别一批图，把底层五花八门的异常统一成 [OcrException]
  Future<List<OcrText>> _recognizeAll(
    List<String> paths, {
    bool deWatermark = true,
  }) async {
    try {
      return await ocr.recognizeFiles(paths, deWatermark: deWatermark);
    } on OcrException {
      rethrow;
    } catch (e) {
      throw OcrException('识别过程出错：$e');
    }
  }

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

  /// 某家雇主名下的模板。
  ///
  /// 有精确归属就用精确的；没有则退回「还没归属过」的老模板（employer_id 为空），
  /// 这样升级上来的用户不会突然看不到模板。
  List<SalaryTemplate> salaryTemplatesOf(int? employerId) {
    final exact =
        salaryTemplates.where((t) => t.employerId == employerId).toList();
    if (exact.isNotEmpty) return exact;
    return salaryTemplates.where((t) => t.employerId == null).toList();
  }

  /// 某家雇主当前生效的模板（没有明确标记就退到最近改过的那套）
  SalaryTemplate? activeTemplateFor(int? employerId) {
    final list = salaryTemplatesOf(employerId);
    if (list.isEmpty) return null;
    for (final t in list) {
      if (t.isActive) return t;
    }
    return list.first;
  }

  /// 当前雇主生效的模板（兼容旧调用点）
  SalaryTemplate? get activeSalaryTemplate =>
      activeTemplateFor(currentEmployer?.id);

  Future<void> saveSalaryTemplate(SalaryTemplate t) async {
    if (t.id == null) {
      await salaryTemplateDao.insert(t);
    } else {
      await salaryTemplateDao.update(t);
    }
    await reload();
  }

  Future<void> deleteSalaryTemplate(int id, {int? employerId}) async {
    await salaryTemplateDao.delete(id, employerId: employerId);
    await reload();
  }

  Future<void> activateSalaryTemplate(int id, {int? employerId}) async {
    await salaryTemplateDao.setActive(id, employerId: employerId);
    await reload();
  }

  @override
  void dispose() {
    ocr.dispose();
    super.dispose();
  }
}
