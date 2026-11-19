import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../core/money.dart';
import '../data/employer.dart';
import '../data/item_order.dart';
import '../data/models.dart';
import '../data/salary_template.dart';
import '../ocr/merge_engine.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/app_tip.dart';
import 'widgets/image_viewer.dart';
import 'widgets/info_hint.dart';
import 'widgets/period_picker.dart';

/// 校对 / 新建 / 编辑三合一页面。
///
/// 为什么合并成一个页面：三种场景的表单结构和校验逻辑完全一样，
/// 只是初始数据来源不同。分开写会重复三份校验代码，改一处要改三遍。
class ReviewPage extends StatefulWidget {
  final PayRecord? editing;
  final RecognizeOutcome? outcome;
  final int initialYear;
  final int initialMonth;
  final String initialRecordType;
  final String initialLabel;

  /// 识别失败时的兜底：图片先存下来，表单留空让用户自己填。
  /// 不这么做的话，用户要么丢掉已经截好的图，要么整个流程得重来。
  final List<String> initialImagePaths;

  const ReviewPage._({
    this.editing,
    this.outcome,
    required this.initialYear,
    required this.initialMonth,
    required this.initialRecordType,
    this.initialLabel = '',
    this.initialImagePaths = const [],
  });

  /// 空白新建
  factory ReviewPage.create({
    required int year,
    required int month,
    String recordType = kTypeMonthly,
    List<String> imagePaths = const [],
  }) =>
      ReviewPage._(
        initialYear: year,
        initialMonth: month,
        initialRecordType: recordType,
        initialImagePaths: imagePaths,
      );

  /// 从 OCR 结果进入。
  ///
  /// [fallbackYear]/[fallbackMonth] 是用户在导入页选的月份；
  /// [honorDetectedPeriod] 为 true（用户没手动改过月份）时，
  /// 优先采用工资条标题上识别出来的年月 —— 它比"当前月"准得多，
  /// 尤其是补录上个月工资条的时候。
  factory ReviewPage.fromOutcome({
    required RecognizeOutcome outcome,
    required String recordType,
    int? fallbackYear,
    int? fallbackMonth,
    bool honorDetectedPeriod = true,
  }) {
    final now = DateTime.now();
    final detected = outcome.periodYear != null && outcome.periodMonth != null;
    return ReviewPage._(
      outcome: outcome,
      initialYear: honorDetectedPeriod && detected ? outcome.periodYear! : (fallbackYear ?? now.year),
      initialMonth:
          honorDetectedPeriod && detected ? outcome.periodMonth! : (fallbackMonth ?? now.month),
      initialRecordType: recordType,
    );
  }

  /// 编辑已有记录
  factory ReviewPage.edit({required PayRecord record}) => ReviewPage._(
        editing: record,
        initialYear: record.periodYear,
        initialMonth: record.periodMonth,
        initialRecordType: record.recordType,
        initialLabel: record.recordLabel ?? '',
      );

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late int _year;
  late int _month;
  late String _recordType;

  /// 这笔记录属于哪家雇主（跳槽后新旧工资条并存的关键维度）
  int? _employerId;

  final _labelCtrl = TextEditingController();
  final _grossCtrl = TextEditingController();
  final _deductionCtrl = TextEditingController();
  final _netCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  final List<PayItemDraft> _items = [];

  /// 信息项：只记录、不计入任何合计
  final List<PayInfo> _infos = [];
  final List<PayImage> _images = [];
  MergeResult? _merge;
  bool _showDuplicates = false;

  /// 是否展开"被跳过但带金额的行"
  bool _showIgnored = false;

  bool _saving = false;

  /// 本次录入用的发薪模板。明细顺序一律按它的字段顺序排 ——
  /// 存下来是因为雇主/模板可能在页面停留期间被别处改掉，
  /// 同一个页面里必须始终用同一套顺序，否则改一项就整体重排。
  SalaryTemplate? _template;

  /// 由模板自动补出来的空字段（记下名字，切换类型时能干净地撤掉）
  final Set<String> _prefilledItems = {};
  final Set<String> _prefilledInfos = {};

  bool get _isEdit => widget.editing != null;

  /// 工资条标题上认出来的年月（识别不到为 false）
  bool get _hasDetectedPeriod =>
      widget.outcome?.periodYear != null && widget.outcome?.periodMonth != null;

  /// 认出来的年月和当前选的不一样 → 给用户一条一键改过来的提示
  bool get _detectedPeriodDiffers =>
      _hasDetectedPeriod &&
      (widget.outcome!.periodYear != _year || widget.outcome!.periodMonth != _month);

  void _adoptDetectedPeriod() {
    final o = widget.outcome;
    if (o?.periodYear == null || o?.periodMonth == null) return;
    setState(() {
      _year = o!.periodYear!;
      _month = o.periodMonth!;
      if (!_isEdit) {
        final state = context.read<AppState>();
        final cur = state.employerById(_employerId);
        if (cur == null || !cur.covers(_year, _month)) {
          _employerId = state.employerForPeriod(_year, _month)?.id;
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
    _month = widget.initialMonth;
    _recordType = widget.initialRecordType;
    _labelCtrl.text = widget.initialLabel;

    // 0) 雇主：编辑时用记录自带的，新建时按"该月份在哪家在职"自动选
    final appState = context.read<AppState>();
    _employerId = widget.editing?.employerId ??
        appState.employerForPeriod(_year, _month)?.id;

    // 1) 编辑模式：直接回填已有数据
    final editing = widget.editing;
    if (editing != null) {
      _items.addAll(editing.items.map((e) => PayItemDraft(
            name: e.name,
            category: e.category,
            valueType: e.valueType,
            amountCents: e.amountCents,
            coefficient: e.coefficient,
          )));
      _images.addAll(editing.images);
      _infos.addAll(editing.infos);
      _grossCtrl.text = _plain(editing.grossCents);
      _deductionCtrl.text = _plain(editing.deductionCents);
      _netCtrl.text = _plain(editing.netCents);
      final note = editing.extra?['note'];
      if (note is String) _noteCtrl.text = note;
    }

    // 2) OCR 模式：把合并结果灌进表单
    final outcome = widget.outcome;
    if (outcome != null) {
      _merge = outcome.result;
      _items.addAll(outcome.result.items);
      // 姓名/工号/部门/基薪/出勤天数/加班时数这些**不算钱**的，单独进信息项
      _infos.addAll(outcome.result.infos);
      for (final img in outcome.images) {
        _images.add(PayImage(
          filePath: img.filePath,
          sortOrder: img.index,
          ocrText: img.rawText,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      final gross = outcome.result.grossCents;
      final ded = outcome.result.deductionTotalCents;
      final net = outcome.result.netCents;
      if (gross != null) _grossCtrl.text = _plain(gross);
      if (ded != null) _deductionCtrl.text = _plain(ded);
      if (net != null) _netCtrl.text = _plain(net);
    }

    // 2.5) 识别失败的兜底：图片照样挂上，表单空着让用户自己填。
    //      这样至少截图不白截，也不用重新走一遍流程。
    if (outcome == null && editing == null && widget.initialImagePaths.isNotEmpty) {
      for (var i = 0; i < widget.initialImagePaths.length; i++) {
        _images.add(PayImage(
          filePath: widget.initialImagePaths[i],
          sortOrder: i,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    }

    // 3) 按「这家雇主 + 这种记录类型」的模板补齐字段。
    //    奖金记录绝不拿月度模板预填 —— 那些绩效/社保项会被塞成 0，
    //    看起来像"这个月绩效没发"。
    final tpl = appState.activeTemplateFor(_employerId, appliesTo: _recordType);
    _template = tpl;
    if (editing == null && tpl != null) {
      _prefillFromTemplate(tpl);
    }

    // 3.5) 顺序：不管数据来自 OCR、模板预填还是历史记录，
    //      统一按模板字段顺序重排一次。这样同一套模板导进来的工资条，
    //      行序永远一致，跨月对比才不会错位。
    _normalizeOrder();

    // 4) 绩效自动计算
    _applyPerfFormula();
  }

  /// 按模板顺序重排明细与信息项（原地改 [_items] / [_infos]）。
  ///
  /// 模板里没有的项排在同类末尾 —— 它们多半是这次新冒出来的项目，
  /// 保持 OCR 认出来的相对顺序即可。
  void _normalizeOrder() {
    final items = orderDraftsByTemplate(_items, _template);
    _items
      ..clear()
      ..addAll(items);

    final infos = orderInfosByTemplate(_infos, _template);
    _infos
      ..clear()
      ..addAll(infos);
  }

  /// 用模板预填字段：只补识别结果里没有的项（识别结果优先）。
  void _prefillFromTemplate(SalaryTemplate tpl) {
    // 比对要按「项目模板里的标准名」来：模板字段叫「本次应发奖金」、
    // 识别结果叫「应发奖金合计」，其实是同一笔钱（奖金条上就是同一个数）。
    // 只按字面比会让它在旁边补一行 0，看起来像"这月没发奖金"。
    final dict = context.read<AppState>().templates;
    String canon(String name) {
      final n = normalizeName(name);
      if (n.isEmpty) return n;
      for (final t in dict) {
        if (t.matches(n)) return normalizeName(t.name);
      }
      return n;
    }

    final existItems = _items.map((e) => canon(e.name)).toSet();
    for (final f in [...tpl.incomeFields, ...tpl.deductionFields]) {
      final key = canon(f.name);
      if (existItems.contains(key)) continue;
      existItems.add(key);
      _items.add(PayItemDraft(
        name: f.name,
        category: f.category,
        valueType: f.valueType,
        amountCents: 0,
        coefficient: null,
      ));
      _prefilledItems.add(normalizeName(f.name));
    }

    final existInfo = _infos.map((e) => normalizeName(e.name)).toSet();
    for (final f in tpl.infoFields) {
      final key = normalizeName(f.name);
      // "薪级" 与 "薪级对应基薪" 算同一个：识别到的那个更具体，模板那个就不要了
      final covered = key.isNotEmpty &&
          existInfo.any((e) => e.isNotEmpty && (e == key || e.contains(key) || key.contains(e)));
      if (covered) continue;
      _infos.add(PayInfo(name: f.name, value: ''));
      existInfo.add(key);
      _prefilledInfos.add(key);
    }
  }

  /// 页面内切换「工资 / 奖金」时换模板。
  ///
  /// 只撤掉"模板自动补出来的空项"，用户自己填的值一个都不动；
  /// 新类型有专属模板就补上它的字段。这是奖金条不被月度字段污染的关键。
  void _onRecordTypeChanged(String v) {
    if (v == _recordType) return;
    final appState = context.read<AppState>();
    setState(() {
      if (!_isEdit) {
        _items.removeWhere((e) =>
            _prefilledItems.contains(normalizeName(e.name)) &&
            e.amountCents == 0 &&
            e.coefficient == null);
        _infos.removeWhere((i) =>
            _prefilledInfos.contains(normalizeName(i.name)) &&
            i.value.trim().isEmpty);
      }
      _prefilledItems.clear();
      _prefilledInfos.clear();
      _recordType = v;
      final tpl = appState.activeTemplateFor(_employerId, appliesTo: v);
      _template = tpl;
      if (!_isEdit && tpl != null) {
        _prefillFromTemplate(tpl);
        _normalizeOrder();
        _applyPerfFormula();
      }
    });
  }

  // ------------------------------------------------------------ 绩效公式

  /// 基本绩效项的名称（用户可在模板里改名，这里做常见别名匹配）
  static const List<String> _perfBaseNames = [
    '基本绩效', '绩效基数', '绩效基薪', '绩效标准', '绩效基本工资', '绩效工资基数',
  ];

  /// 实发绩效那一行的名称
  static const List<String> _perfResultNames = [
    '绩效工资', '实发绩效工资', '实发绩效', '绩效奖金', '本月绩效工资',
  ];

  PayItemDraft? _findItem(List<String> names) {
    for (final item in _items) {
      if (normalizeName(item.name).isEmpty) continue;
      for (final n in names) {
        if (normalizeName(item.name) == normalizeName(n)) return item;
      }
    }
    return null;
  }

  PayItemDraft? _findCoefficientItem() {
    for (final item in _items) {
      if (item.valueType == kValueCoefficient && item.coefficient != null) return item;
    }
    return null;
  }

  /// 绩效公式，**正反两个方向都要能走**：
  ///
  /// - 正向（模板里有基本绩效且是手填的）：绩效工资 = 基本绩效 × 绩效系数
  /// - 反向（工资条上只有系数和实发绩效）：基本绩效 = 实发绩效 ÷ 绩效系数
  ///
  /// 为什么必须支持反向：用户的工资条常年只印「本月绩效系数 1.1」和
  /// 「实发绩效工资 1826」，基本绩效 1660 是要靠自己除出来的。
  ///
  /// 两条边界，是为了不跟工资条打架：
  /// 1. 反推出来的基本绩效存成 [kValueDerived]，**不计入应发合计**
  ///    —— 它的钱已经包含在实发绩效里，再加一遍会凭空多 1660；
  /// 2. 只要基本绩效是"推算"的，就以工资条上的实发绩效为准（继续反推），
  ///    绝不反过来改写实发绩效 —— 改了应发就对不上工资条上的应发小计。
  ///    只有用户手填过基本绩效、且打开了自动计算，才走正向覆盖。
  void _applyPerfFormula() {
    final settings = context.read<AppSettings>();
    final coefItem = _findCoefficientItem();
    final coef = coefItem?.coefficient;
    final result = _findItem(_perfResultNames);
    final base = _findItem(_perfBaseNames);

    // A. 正向：手填的基本绩效 × 系数 → 算绩效工资（需要用户明确开启）
    if (settings.perfAuto &&
        base != null &&
        !base.isDerived &&
        base.amountCents > 0 &&
        coef != null &&
        coef > 0 &&
        result != null) {
      final computed = (base.amountCents * coef).round();
      if (result.amountCents != computed) result.amountCents = computed;
      return;
    }

    // B. 反向：从实发绩效和系数反推基本绩效
    //    （不受开关限制：它只写推算值，一个真实金额都不动）
    final needDerive = base == null || base.isDerived || base.amountCents == 0;
    if (!needDerive) return;
    if (coef == null || coef <= 0) return;
    if (result == null || result.amountCents <= 0) return;

    final derived = (result.amountCents / coef).round();
    // 除出来明显不合理的（系数或金额识别错）就不写，交给人工
    if (derived <= 0 || derived > 100000000) return;

    if (base != null) {
      if (base.isDerived && base.amountCents == derived) return;
      base.amountCents = derived;
      // 反推值绝不能进合计，否则应发会比工资条多出一整个基本绩效
      base.valueType = kValueDerived;
      return;
    }

    // 插在绩效系数前面，视觉上就是「基数 ← 系数 → 结果」
    final at = coefItem == null ? _items.length : _items.indexOf(coefItem);
    _items.insert(
      at < 0 ? _items.length : at,
      PayItemDraft(
        name: '基本绩效',
        category: kCategoryIncome,
        valueType: kValueDerived,
        amountCents: derived,
      ),
    );
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _grossCtrl.dispose();
    _deductionCtrl.dispose();
    _netCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _plain(int cents) => (cents / 100).toStringAsFixed(2);

  // ------------------------------------------------------------ 计算

  int get _incomeSum => _items
      .where((e) => e.category == kCategoryIncome && e.countsInTotal)
      .fold(0, (s, e) => s + e.amountCents);

  int get _deductionSum => _items
      .where((e) => e.category == kCategoryDeduction && e.countsInTotal)
      .fold(0, (s, e) => s + e.amountCents);

  int? _parseCtrl(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return parseAmountToCents(t);
  }

  /// 表单里填的三个合计是否自洽
  bool get _totalsConsistent {
    final g = _parseCtrl(_grossCtrl);
    final d = _parseCtrl(_deductionCtrl);
    final n = _parseCtrl(_netCtrl);
    if (g == null || d == null || n == null) return true; // 没填就不判
    return (n - (g - d)).abs() <= 1;
  }

  bool get _detailMatchesGross {
    final g = _parseCtrl(_grossCtrl);
    if (g == null) return true;
    return (g - _incomeSum).abs() <= 1;
  }

  // ------------------------------------------------------------ 交互

  Future<void> _pickPeriod() async {
    final result = await showDialog<({int year, int month})>(
      context: context,
      builder: (ctx) => PeriodPickerDialog(year: _year, month: _month),
    );
    if (result != null) {
      setState(() {
        _year = result.year;
        _month = result.month;
        // 换了月份后原来的雇主可能不在职了（比如改到上一家公司期间），
        // 自动跟着走——只在新建时做，编辑已有记录不擅自改动
        if (!_isEdit) {
          final state = context.read<AppState>();
          final cur = state.employerById(_employerId);
          if (cur == null || !cur.covers(_year, _month)) {
            _employerId = state.employerForPeriod(_year, _month)?.id;
          }
        }
      });
    }
  }

  /// 侧滑删除明细项：先二次确认，避免误删。
  Future<void> _deleteItem(int index) async {
    final name = _items[index].name.isEmpty ? '这项' : _items[index].name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一项？'),
        content: Text('$name 将从明细里移除。', style: const TextStyle(height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: kUp),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _items.removeAt(index);
      _normalizeOrder();
      _applyPerfFormula();
    });
  }

  /// 侧滑删除信息项。
  Future<void> _deleteInfo(int index) async {
    final name = _infos[index].name.isEmpty ? '这项' : _infos[index].name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一项？'),
        content: Text('$name 将从信息项里移除。', style: const TextStyle(height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: kUp),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _infos.removeAt(index));
  }

  Future<void> _editItem(int index) async {
    final draft = _items[index];
    final result = await showDialog<_ItemEditResult>(
      context: context,
      builder: (ctx) => _ItemEditDialog(draft: draft),
    );
    if (result == null || !mounted) return;

    // 转成信息项：从明细里摘掉，挪到信息项列表（保留原来的数字，只是不参与计算）
    if (result.asInfo) {
      setState(() {
        _items.removeAt(index);
        _infos.add(PayInfo(
          name: draft.name,
          value: draft.valueType == kValueCoefficient
              ? (draft.coefficient == null ? '' : draft.coefficient!.toStringAsFixed(2))
              : (draft.amountCents / 100).toStringAsFixed(2),
          sortOrder: _infos.length,
        ));
        _normalizeOrder();
        _applyPerfFormula();
      });
      if (result.remember) await _rememberCategory(draft.name, kFieldInfo);
      return;
    }

    setState(() {
      if (result.draft != null) {
        _items[index] = result.draft!;
      }
      // 改了名字/类别之后位置可能变（比如收入改成扣款），
      // 立刻按模板重排，用户才能看到「这项就跑到了该在的位置」
      _normalizeOrder();
      _applyPerfFormula();
    });

    final saved = result.draft;
    if (result.remember && saved != null && saved.name.trim().isNotEmpty) {
      // 系数/推算这类"值类型"不写进模板归类，只记收入/扣款/信息项
      await _rememberCategory(saved.name, saved.category);
    }
  }

  /// 把「这个项目属于收入/扣款/信息项」写进项目模板。
  ///
  /// 这是本 App 提升准确率最有效的一条路：OCR 永远会认错，
  /// 但只要用户纠正过一次，下次导入同样的写法就能自动按正确规则归类，
  /// 不用每次改。
  Future<void> _rememberCategory(String name, String category) async {
    final state = context.read<AppState>();
    final key = normalizeName(name);
    if (key.isEmpty) return;

    ItemTemplate? exist;
    for (final t in state.templates) {
      if (t.matches(key)) {
        exist = t;
        break;
      }
    }
    if (exist != null && exist.category == category) return;

    await state.saveTemplate(ItemTemplate(
      id: exist?.id,
      name: exist?.name ?? name,
      category: category,
      aliases: exist?.aliases ?? const [],
      valueType: exist?.valueType ?? kValueAmount,
      sortOrder: exist?.sortOrder ?? 0,
      enabled: true,
    ));
    if (mounted) _toast('已记住：「${exist?.name ?? name}」以后按新规则归类');
  }

  Future<void> _addItem(String category) async {
    final result = await showDialog<_ItemEditResult>(
      context: context,
      builder: (ctx) => _ItemEditDialog(
        draft: PayItemDraft(
          name: '',
          category: category,
          amountCents: 0,
        ),
        isNew: true,
      ),
    );
    if (result?.draft == null || !mounted) return;
    setState(() {
      _items.add(result!.draft!);
      // 新增后立刻归位：模板里有这一项就插到它的位置，没有就落在同类末尾
      _normalizeOrder();
      _applyPerfFormula();
    });
  }

  // ------------------------------------------------------------ 信息项操作

  Future<void> _editInfo(int index) async {
    final result = await showDialog<_InfoEditResult>(
      context: context,
      builder: (ctx) => _InfoEditDialog(info: _infos[index]),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.info != null) {
        _infos[index] = result.info!;
      }
    });
  }

  Future<void> _addInfo() async {
    final result = await showDialog<_InfoEditResult>(
      context: context,
      builder: (ctx) => _InfoEditDialog(info: PayInfo(name: '', value: ''), isNew: true),
    );
    if (result?.info == null || !mounted) return;
    setState(() => _infos.add(result!.info!));
  }

  void _applyComputedTotals() {
    setState(() {
      _grossCtrl.text = _plain(_incomeSum);
      _deductionCtrl.text = _plain(_deductionSum);
      _netCtrl.text = _plain(_incomeSum - _deductionSum);
    });
  }

  Future<void> _save() async {
    if (_saving) return;

    // 奖金必须有个名字，不然列表里分不清是哪种奖
    if (_recordType == kTypeExtra && _labelCtrl.text.trim().isEmpty) {
      _toast('给这笔额外收入起个名字，例如「2026年终奖」');
      return;
    }
    if (_items.isEmpty && _parseCtrl(_netCtrl) == null) {
      _toast('至少填一项金额');
      return;
    }

    final gross = _parseCtrl(_grossCtrl) ?? _incomeSum;
    final deduction = _parseCtrl(_deductionCtrl) ?? _deductionSum;
    final net = _parseCtrl(_netCtrl) ?? (gross - deduction);

    // 合计不自洽时不拦，但要用户明确知道
    if ((net - (gross - deduction)).abs() > 1) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('合计对不上'),
          content: Text(
            '应发 ${formatCents(gross)} − 代扣 ${formatCents(deduction)} '
            '= ${formatCents(gross - deduction)}，'
            '但你填的实发是 ${formatCents(net)}。\n\n确定按你填的实发保存吗？',
            style: const TextStyle(height: 1.6, fontSize: 14),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回修改')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然保存')),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() => _saving = true);
    final state = context.read<AppState>();
    final now = DateTime.now().millisecondsSinceEpoch;

    final record = PayRecord(
      id: widget.editing?.id,
      employerId: _employerId,
      periodYear: _year,
      periodMonth: _month,
      recordType: _recordType,
      recordLabel: _recordType == kTypeExtra ? _labelCtrl.text.trim() : null,
      grossCents: gross,
      deductionCents: deduction,
      netCents: net,
      extra: _noteCtrl.text.trim().isEmpty ? null : {'note': _noteCtrl.text.trim()},
      createdAt: widget.editing?.createdAt ?? now,
      updatedAt: now,
    );

    // 明细落库顺序：按模板字段顺序（收入在前、扣款在后）。
    // 存下来的 sort_order 就是详情页的显示顺序，所以这里排好，
    // 以后打开这条记录看到的顺序和当时录入的一致。
    final ordered = orderDraftsByTemplate(_items, _template);

    // 空名字的信息项不落库（模板预填后用户没填值的，保留但值为空）
    final infos = _infos.where((e) => e.name.trim().isNotEmpty).toList();

    try {
      if (_isEdit) {
        await state.updateRecord(record, ordered, _images, infos);
      } else {
        await state.insertRecord(record, ordered, _images, infos);
      }
      // 保存后把视图切到这条记录所属的雇主，
      // 否则用户回到首页看不到刚录的这条，会以为"没存上"
      final empId = _employerId;
      if (empId != null) await state.switchEmployer(empId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showTip(context, msg);
  }

  void _viewImage(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ImageViewerPage(paths: _images.map((e) => e.filePath).toList(), initial: index),
    ));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? '编辑记录' : (widget.outcome != null ? '核对识别结果' : '新增记录');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          if (_images.isNotEmpty) _imageStrip(),
          if (_merge != null) _mergeSummary(),
          _periodCard(),
          const SizedBox(height: 14),
          if (_findCoefficientItem() != null &&
              (_findItem(_perfBaseNames) != null ||
                  _findItem(_perfResultNames) != null)) ...[
            _perfHint(),
            const SizedBox(height: 10),
          ],
          _section(
            title: '收入项',
            subtitle: '合计 ${formatCents(_incomeSum)}',
            color: kIncome,
            items: _items.where((e) => e.category == kCategoryIncome).toList(),
            onAdd: () => _addItem(kCategoryIncome),
          ),
          const SizedBox(height: 14),
          _section(
            title: '扣款项',
            subtitle: '合计 ${formatCents(_deductionSum)}',
            color: kDeduction,
            items: _items.where((e) => e.category == kCategoryDeduction).toList(),
            onAdd: () => _addItem(kCategoryDeduction),
          ),
          const SizedBox(height: 14),
          _infoCard(),
          const SizedBox(height: 14),
          _totalsCard(),
          const SizedBox(height: 14),
          _noteCard(),
        ],
      ),
    );
  }

  Widget _imageStrip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 74,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _images.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final path = _images[i].filePath;
            return GestureDetector(
              onTap: () => _viewImage(i),
              onLongPress: () => _removeImage(i),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(path),
                      width: 56,
                      height: 74,
                      // 只按缩略图需要解码，别为 56px 的小图解码一整张长截图
                      cacheWidth: 220,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 74,
                        color: kBorder,
                        child: Icon(Icons.broken_image_outlined,
                            size: 20, color: kTextHint),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(10),
                          bottomRight: Radius.circular(6),
                        ),
                      ),
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 9, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _removeImage(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('去掉这张图？'),
        content: const Text('只是不再关联到这条记录，不影响你已经填好的明细。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去掉')),
        ],
      ),
    );
    if (ok == true) setState(() => _images.removeAt(index));
  }

  /// 合并摘要：让用户信任自动合并的结果
  Widget _mergeSummary() {
    final m = _merge!;
    final errorIssues = m.issues
        .where((e) =>
            e.type == MergeIssueType.totalMismatch ||
            e.type == MergeIssueType.noOverlap ||
            e.type == MergeIssueType.sameNameConflict)
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: errorIssues.isEmpty ? kInfoBg : kWarnBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: errorIssues.isEmpty ? const Color(0x332E7D6B) : const Color(0x33E9B949),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                errorIssues.isEmpty ? Icons.auto_awesome : Icons.warning_amber_rounded,
                size: 16,
                color: errorIssues.isEmpty ? kSeed : kWarnIcon,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  m.summary,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: errorIssues.isEmpty ? kSeed : kWarnText,
                  ),
                ),
              ),
            ],
          ),
          for (final issue in errorIssues) ...[
            const SizedBox(height: 6),
            Text('· ${issue.message}',
                style: TextStyle(
                    fontSize: 11.8, height: 1.5, color: kWarnLink)),
          ],
          // 兜回来的行：不是错误，是"我帮你补了一项，你确认下"
          for (final issue in m.issues.where((e) => e.type == MergeIssueType.recovered)) ...[
            const SizedBox(height: 6),
            Text('· ${issue.message}',
                style: TextStyle(fontSize: 11.8, height: 1.5, color: kTextSecondary)),
          ],
          // 带金额但没进明细的行：以前是静默丢掉的，对不上账时根本查不到原因
          if (m.ignoredRows.isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _showIgnored = !_showIgnored),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(
                      _showIgnored
                          ? '收起被跳过的行'
                          : '有 ${m.ignoredRows.length} 行带金额但没进明细，点开看看',
                      style: TextStyle(
                          fontSize: 11.8, color: kSeed, fontWeight: FontWeight.w500),
                    ),
                    Icon(
                      _showIgnored ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: kSeed,
                    ),
                  ],
                ),
              ),
            ),
            if (_showIgnored)
              for (final r in m.ignoredRows)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${r.name}  ${r.amountCents == null ? '' : formatCents(r.amountCents!)}',
                          style: TextStyle(fontSize: 11.5, color: kTextMedium),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _items.add(PayItemDraft(
                              name: r.name.trim(),
                              category: kCategoryIncome,
                              amountCents: (r.amountCents ?? 0).abs(),
                            ));
                            _normalizeOrder();
                          });
                        },
                        child: Text('加进来',
                            style: TextStyle(fontSize: 11.5, color: kSeed)),
                      ),
                    ],
                  ),
                ),
          ],
          if (m.removedDuplicates.isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _showDuplicates = !_showDuplicates),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(
                      _showDuplicates ? '收起已去除项' : '查看已去除的 ${m.removedDuplicates.length} 项重复',
                      style: TextStyle(
                          fontSize: 11.8, color: kSeed, fontWeight: FontWeight.w500),
                    ),
                    Icon(
                      _showDuplicates ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: kSeed,
                    ),
                  ],
                ),
              ),
            ),
            if (_showDuplicates)
              for (final dup in m.removedDuplicates)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${dup.name}  ${formatCents(dup.amountCents)}',
                            style: TextStyle(fontSize: 11.5, color: kTextMedium)),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _items.add(dup);
                            m.removedDuplicates.remove(dup);
                            // 撤回的行也要回到模板里的位置，不能随手挂在末尾
                            _normalizeOrder();
                          });
                        },
                        child: Text('撤回',
                            style: TextStyle(fontSize: 11.5, color: kSeed)),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }

  /// 发薪雇主。只有一家时不做成下拉，避免点出个没选项的菜单。
  Widget _employerTile() {
    final state = context.watch<AppState>();
    final employers = state.employers;
    final current = state.employerById(_employerId);
    if (employers.length <= 1) {
      return ListTile(
        title: const Text('发薪雇主', style: TextStyle(fontSize: 14)),
        trailing: Text(
          current?.name ?? '未设置',
          style: TextStyle(fontSize: 14, color: kTextSecondary),
        ),
      );
    }
    return ListTile(
      title: const Text('发薪雇主', style: TextStyle(fontSize: 14)),
      trailing: DropdownButton<int>(
        value: employers.any((e) => e.id == _employerId) ? _employerId : null,
        underline: const SizedBox.shrink(),
        hint: const Text('选择', style: TextStyle(fontSize: 14)),
        style: TextStyle(fontSize: 14, color: kTextPrimary),
        items: employers
            .map((Employer e) => DropdownMenuItem<int>(
                  value: e.id,
                  child: Text(e.name, style: const TextStyle(fontSize: 14)),
                ))
            .toList(),
        onChanged: (v) => setState(() => _employerId = v),
      ),
    );
  }

  Widget _periodCard() {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          ListTile(
            title: const Text('归属月份', style: TextStyle(fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$_year 年 $_month 月',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                Icon(Icons.chevron_right, size: 18, color: kTextFaint),
              ],
            ),
            onTap: _pickPeriod,
          ),
          if (_detectedPeriodDiffers)
            InkWell(
              onTap: _adoptDetectedPeriod,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  '工资条上写的是 ${widget.outcome!.periodYear} 年 '
                  '${widget.outcome!.periodMonth} 月，点这里改过来',
                  style: TextStyle(fontSize: 11.5, color: kSeed, height: 1.4),
                ),
              ),
            ),
          const Divider(height: 1),
          _employerTile(),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                const Text('类型', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 16),
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const [
                      ButtonSegment(
                          value: kTypeMonthly,
                          label: Text('工资', style: TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: kTypeExtra,
                          label: Text('奖金', style: TextStyle(fontSize: 12))),
                    ],
                    selected: {_recordType},
                    onSelectionChanged: (s) => _onRecordTypeChanged(s.first),
                  ),
                ),
              ],
            ),
          ),
          if (_recordType == kTypeExtra) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _labelCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：2026年终奖 / Q3项目奖金',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String subtitle,
    required Color color,
    required List<PayItemDraft> items,
    required VoidCallback onAdd,
  }) {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 9),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration:
                      BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(subtitle,
                    style: TextStyle(fontSize: 12, color: kTextSecondary)),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无，点下面添加',
                    style: TextStyle(fontSize: 12.5, color: kTextHint)),
              ),
            ),
          for (final item in items) _itemRow(item),
          InkWell(
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text('添加$title', style: TextStyle(fontSize: 13, color: color)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(PayItemDraft item) {
    final index = _items.indexOf(item);
    return InkWell(
      onTap: () => _editItem(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.name.isEmpty ? '（未命名）' : item.name,
                style: TextStyle(
                  fontSize: 13.5,
                  color: item.name.isEmpty ? kTextHint : kTextPrimary,
                ),
              ),
            ),
            if (item.valueType == kValueCoefficient)
              Text(
                item.coefficient == null ? '待填' : '× ${item.coefficient!.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 13.5,
                  color: item.coefficient == null ? kWarnBorder : kSeed,
                  fontWeight: FontWeight.w500,
                ),
              )
            else ...[
              if (item.isDerived)
                Container(
                  margin: const EdgeInsets.only(right: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: kSurfaceAlt,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('推算',
                      style: TextStyle(fontSize: 9.5, color: kTextSecondary)),
                ),
              Text(
                formatCents(item.category == kCategoryDeduction
                    ? -item.amountCents
                    : item.amountCents),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: item.isDerived ? FontWeight.w400 : FontWeight.w500,
                  color: item.isDerived
                      ? kTextSecondary
                      : kTextPrimary,
                ),
              ),
            ],
            const SizedBox(width: 4),
            // 删除移到列表里操作，弹框只留取消/确定
            SizedBox(
              width: 26,
              height: 26,
              child: IconButton(
                icon: Icon(Icons.delete_outline, size: 15, color: kTextFaint),
                tooltip: '删除',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () => _deleteItem(index),
              ),
            ),
            Icon(Icons.edit_outlined, size: 14, color: kTextFaint),
          ],
        ),
      ),
    );
  }

  /// 绩效提示条：告诉用户"这行是算出来的，不是手填的"
  Widget _perfHint() {
    final auto = context.watch<AppSettings>().perfAuto;
    final base = _findItem(_perfBaseNames);
    final coefItem = _findCoefficientItem();
    final result = _findItem(_perfResultNames);
    final coef = coefItem?.coefficient;
    final baseText = base?.name ?? '基本绩效';

    String text;
    if (coef == null) {
      text = '填上绩效系数后，可用「$baseText × 系数」或「绩效工资 ÷ 系数」自动核对';
    } else if (base != null && base.amountCents > 0 && !base.isDerived) {
      text = '$baseText ${formatCents(base.amountCents)} × ${coef.toStringAsFixed(2)}'
          ' = ${formatCents((base.amountCents * coef).round())}'
          '${auto ? '（已自动写入绩效工资）' : '（自动计算未开启，不会覆盖你填的值）'}';
    } else if (base != null && base.amountCents > 0) {
      text = '绩效工资 ${formatCents(result?.amountCents ?? 0)} ÷ ${coef.toStringAsFixed(2)}'
          ' 反推 $baseText ${formatCents(base.amountCents)}（推算值，不计入合计）';
    } else {
      text = '填好绩效系数和绩效工资后，会自动反推$baseText';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: kInfoBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.functions, size: 15, color: kSeed),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.8, color: kInfoText, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// 信息项卡片：姓名、工号、业务单位、应出勤天数…这些**不参与任何计算**
  Widget _infoCard() {
    return Container(
      decoration: cardDecoration(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 9),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                      color: kTextHint,
                      borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                const Text('信息项',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('不计入合计',
                    style: TextStyle(fontSize: 11.5, color: kTextHint)),
              ],
            ),
          ),
          if (_infos.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无。可记录姓名、工号、业务单位、应出勤天数等',
                    style: TextStyle(fontSize: 12, color: kTextHint)),
              ),
            ),
          for (var i = 0; i < _infos.length; i++)
            InkWell(
              onTap: () => _editInfo(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        _infos[i].name.isEmpty ? '（未命名）' : _infos[i].name,
                        style: TextStyle(fontSize: 13, color: kTextBody),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        _infos[i].value.isEmpty ? '—' : _infos[i].value,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 13,
                          color: _infos[i].value.isEmpty
                              ? kTextFaint
                              : kTextPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: IconButton(
                        icon: Icon(Icons.delete_outline, size: 15, color: kTextFaint),
                        tooltip: '删除',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onPressed: () => _deleteInfo(i),
                      ),
                    ),
                    Icon(Icons.edit_outlined, size: 14, color: kTextFaint),
                  ],
                ),
              ),
            ),
          InkWell(
            onTap: _addInfo,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, size: 16, color: kTextMedium),
                  SizedBox(width: 6),
                  Text('添加信息项', style: TextStyle(fontSize: 13, color: kTextMedium)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsCard() {
    final gross = _parseCtrl(_grossCtrl);
    final deduction = _parseCtrl(_deductionCtrl);
    final net = _parseCtrl(_netCtrl);

    final grossOk = _detailMatchesGross;
    final consistent = _totalsConsistent;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('合计', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _moneyField('应发合计', _grossCtrl, hint: formatCents(_incomeSum)),
          const SizedBox(height: 10),
          _moneyField('代扣合计', _deductionCtrl, hint: formatCents(_deductionSum)),
          const SizedBox(height: 10),
          _moneyField(
            '实发工资',
            _netCtrl,
            hint: gross != null && deduction != null
                ? formatCents(gross - deduction)
                : formatCents(_incomeSum - _deductionSum),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _applyComputedTotals,
                  child: Row(
                    children: [
                      Icon(Icons.calculate_outlined, size: 14, color: kSeed),
                      const SizedBox(width: 5),
                      Text(
                        '按明细重算（$_items.length 项）',
                        style: TextStyle(fontSize: 12, color: kSeed),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!grossOk || !consistent) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kWarnBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0x33E9B949)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!grossOk)
                    Text(
                      '收入明细加总 ${formatCents(_incomeSum)}，'
                      '与应发合计 ${formatCents(gross ?? 0)} 相差 '
                      '${formatCents((_incomeSum - (gross ?? 0)).abs())}',
                      style: TextStyle(
                          fontSize: 11.8, height: 1.5, color: kWarnText),
                    ),
                  if (!consistent && gross != null && deduction != null && net != null)
                    Text(
                      '应发 − 代扣 = ${formatCents(gross - deduction)}，'
                      '但实发填的是 ${formatCents(net)}',
                      style: TextStyle(
                          fontSize: 11.8, height: 1.5, color: kWarnText),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _moneyField(String label, TextEditingController ctrl, {String? hint}) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(label, style: TextStyle(fontSize: 13.5, color: kTextBody)),
        ),
        Expanded(
          child: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 13, color: kTextFaint),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }

  Widget _noteCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(),
      child: TextField(
        controller: _noteCtrl,
        maxLines: 2,
        decoration: const InputDecoration(
          labelText: '备注（可选）',
          hintText: '例如：本月含调薪、补发上月差额',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 子弹窗

class _InfoEditResult {
  final PayInfo? info;
  _InfoEditResult({this.info});
}

/// 信息项编辑弹窗（名称 + 值，纯文本，不做任何金额校验）
class _InfoEditDialog extends StatefulWidget {
  final PayInfo info;
  final bool isNew;

  const _InfoEditDialog({required this.info, this.isNew = false});

  @override
  State<_InfoEditDialog> createState() => _InfoEditDialogState();
}

class _InfoEditDialogState extends State<_InfoEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _valueCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.info.name);
    _valueCtrl = TextEditingController(text: widget.info.value);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_InfoEditResult(
      info: widget.info.copyWith(name: name, value: _valueCtrl.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '添加信息项' : '编辑信息项'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: widget.isNew,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '如：姓名 / 工号 / 应出勤天数',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valueCtrl,
            decoration: const InputDecoration(
              labelText: '内容',
              hintText: '如：张三 / A1234 / 21',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('信息项只做记录，不会计入任何合计',
                style: TextStyle(fontSize: 11.5, color: kTextHint)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}

class _ItemEditResult {
  final PayItemDraft? draft;

  /// 这一行本来就不是钱（如「休息日加班时长」被认成了收入），要挪去信息项
  final bool asInfo;

  /// 把这次的归类写进项目模板，下次识别自动照办
  final bool remember;

  _ItemEditResult({
    this.draft,
    this.asInfo = false,
    this.remember = false,
  });
}

/// 明细项编辑弹窗
class _ItemEditDialog extends StatefulWidget {
  final PayItemDraft draft;
  final bool isNew;

  const _ItemEditDialog({required this.draft, this.isNew = false});

  @override
  State<_ItemEditDialog> createState() => _ItemEditDialogState();
}

class _ItemEditDialogState extends State<_ItemEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _valueCtrl;
  late String _category;
  late String _valueType;

  /// 「记住这个项目的归类」：默认勾上，但只对已有项目显示
  bool _remember = true;

  bool get _isCoefficient => _valueType == kValueCoefficient;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.draft.name);
    _category = widget.draft.category;
    _valueType = widget.draft.valueType;
    _valueCtrl = TextEditingController(
      text: _isCoefficient
          ? (widget.draft.coefficient == null
              ? ''
              : widget.draft.coefficient!.toStringAsFixed(2))
          : (widget.draft.amountCents == 0
              ? ''
              : (widget.draft.amountCents / 100).toStringAsFixed(2)),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    final raw = _valueCtrl.text.trim();
    int amountCents = 0;
    double? coefficient;

    if (_isCoefficient) {
      coefficient = parseCoefficient(raw);
    } else {
      amountCents = parseAmountToCents(raw)?.abs() ?? 0;
    }

    Navigator.of(context).pop(_ItemEditResult(
      draft: PayItemDraft(
        name: name,
        category: _category,
        valueType: _valueType,
        amountCents: amountCents,
        coefficient: coefficient,
      ),
      remember: _remember,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '添加项目' : '编辑项目'),
      // 固定高度 + 内部滚动：点「推算」时只在内部增减一行，
      // 弹窗本身不会突然撑高；小屏/键盘弹起也不会超出屏幕。
      content: SizedBox(
        height: (MediaQuery.of(context).size.height * 0.56)
            .clamp(320.0, 440.0)
            .toDouble(),
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
            controller: _nameCtrl,
            autofocus: widget.isNew,
            decoration: const InputDecoration(
              labelText: '项目名称',
              hintText: '如：基本工资 / 个人社保',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(
                        value: kCategoryIncome, label: Text('收入', style: TextStyle(fontSize: 12))),
                    ButtonSegment(
                        value: kCategoryDeduction,
                        label: Text('扣款', style: TextStyle(fontSize: 12))),
                  ],
                  selected: {_category},
                  onSelectionChanged: (s) => setState(() => _category = s.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(
                  value: kValueAmount, label: Text('金额', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: kValueCoefficient,
                  label: Text('系数', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: kValueDerived,
                  label: Text('推算', style: TextStyle(fontSize: 12))),
            ],
            selected: {_valueType},
            onSelectionChanged: (s) => setState(() => _valueType = s.first),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _valueCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            decoration: InputDecoration(
              labelText: _isCoefficient ? '系数' : '金额',
              hintText: _isCoefficient ? '1.20' : '0.00',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_valueType == kValueDerived) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const InfoHint(
                  title: '推算值',
                  text: '由公式反推得到，能看到但不计入合计。\n'
                      '例如「基本绩效 = 绩效工资 ÷ 绩效系数」。',
                ),
                Text('推算值说明', style: TextStyle(fontSize: 11, color: kTextHint)),
              ],
            ),
          ],
          if (!widget.isNew) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => Navigator.of(context).pop(
                  _ItemEditResult(asInfo: true, remember: _remember),
                ),
                icon: const Icon(Icons.swap_horiz, size: 15),
                label: const Text(
                  '这不是钱，转成信息项',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            CheckboxListTile(
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('记住这个项目的归类', style: TextStyle(fontSize: 12.5)),
              subtitle: Text(
                '下次识别到同名项目，自动按这次的规则处理（收入/扣款/信息项）',
                style: TextStyle(fontSize: 11, height: 1.4, color: kTextHint),
              ),
            ),
          ],
          ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}
