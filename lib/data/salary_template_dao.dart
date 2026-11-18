import 'package:sqflite/sqflite.dart';

import 'salary_template.dart';

/// 发薪模板读写。
///
/// 关键约束：**每家公司、每种适用类型各自只能有一套生效**。
///
/// 以前是全局只有一套生效，跳槽后就会打架：
/// 把新公司的模板设成生效，旧公司的录入预填也被一起换掉了。
/// 现在按 employer_id 分组，切换生效时只清同一家公司名下的 is_active，
/// 别家的"生效中"原封不动。
///
/// v6 起再按 applies_to 分组：月度一套、奖金一套。这样导年终奖时
/// 不会拿月度模板去补一堆零值绩效项。
class SalaryTemplateDao {
  final Database db;
  SalaryTemplateDao(this.db);

  /// 全部模板（含字段）。字段一次查完再按 template_id 分组，
  /// 避免 N+1 查询 —— 模板不多，但一条条查也很浪费。
  Future<List<SalaryTemplate>> loadAll() async {
    final templateRows = await db.query('salary_template',
        orderBy: 'employer_id ASC, is_active DESC, updated_at DESC, id ASC');
    if (templateRows.isEmpty) return [];
    return _attachFields(templateRows);
  }

  /// 某家雇主名下的模板。
  ///
  /// `employer_id IS NULL` 也算：那是 v5 之前的全局模板，迁移失败或
  /// 用户新建了雇主时还能看到它，不会"凭空消失"。
  Future<List<SalaryTemplate>> loadByEmployer(int? employerId) async {
    final rows = await db.query(
      'salary_template',
      where: employerId == null ? null : '(employer_id = ? OR employer_id IS NULL)',
      whereArgs: employerId == null ? null : [employerId],
      orderBy: 'is_active DESC, updated_at DESC, id ASC',
    );
    if (rows.isEmpty) return [];
    return _attachFields(rows);
  }

  Future<List<SalaryTemplate>> _attachFields(
      List<Map<String, Object?>> templateRows) async {
    final fieldRows = await db.query('template_field', orderBy: 'sort_order ASC, id ASC');
    final byTemplate = <int, List<TemplateField>>{};
    for (final r in fieldRows) {
      final f = TemplateField.fromMap(r);
      if (f.templateId == null) continue;
      byTemplate.putIfAbsent(f.templateId!, () => []).add(f);
    }
    return templateRows.map((r) {
      final t = SalaryTemplate.fromMap(r);
      t.fields = byTemplate[t.id] ?? const [];
      return t;
    }).toList();
  }

  /// 某家雇主在某个适用类型下「生效中」的模板。
  ///
  /// 查找顺序（每一档都优先"明确设为生效"的）：
  /// 1) 同类型（月度/奖金）
  /// 2) 通用模板兜底
  /// 3) 同类型最近改过的那套
  /// 4) 通用模板最近改过的那套
  ///
  /// 都没有就返回 null —— 这时**不要预填**，让用户面对空表单，
  /// 比拿一套不相干的字段硬套要好。
  Future<SalaryTemplate?> activeTemplateFor(
    int? employerId, {
    String appliesTo = kTplMonthly,
  }) async {
    final rows = await db.query(
      'salary_template',
      // employerId 为空时只能取"还没归属过"的模板，不能把别家的一起捞出来
      where: employerId == null
          ? 'employer_id IS NULL'
          : '(employer_id = ? OR employer_id IS NULL)',
      whereArgs: employerId == null ? null : [employerId],
      orderBy: 'employer_id IS NULL ASC, is_active DESC, updated_at DESC, id ASC',
    );
    if (rows.isEmpty) return null;

    final list = await _attachFields(rows);
    SalaryTemplate? pick(bool Function(SalaryTemplate) test) {
      for (final t in list) {
        if (test(t)) return t;
      }
      return null;
    }

    final type = appliesTo == kTplAll ? kTplMonthly : appliesTo;
    return pick((t) => t.appliesTo == type && t.isActive) ??
        pick((t) => t.appliesTo == kTplAll && t.isActive) ??
        pick((t) => t.appliesTo == type) ??
        pick((t) => t.appliesTo == kTplAll);
  }

  /// 新增模板，返回新 id。**这家雇主、这个适用类型**下的第一套自动设为生效。
  Future<int> insert(SalaryTemplate template) async {
    final employerId = template.employerId;
    return db.transaction((txn) async {
      final count = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM salary_template WHERE employer_id IS ? AND applies_to = ?',
            [employerId, template.appliesTo],
          )) ??
          0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = await txn.insert('salary_template', {
        'employer_id': employerId,
        'name': template.name,
        'applies_to': template.appliesTo,
        'is_active': count == 0 || template.isActive ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      });
      await _writeFields(txn, id, template.fields);
      return id;
    });
  }

  /// 更新模板：字段整组替换（字段少，简单可靠）
  Future<void> update(SalaryTemplate template) async {
    final id = template.id;
    if (id == null) throw ArgumentError('update 需要 template.id');
    await db.transaction((txn) async {
      await txn.update(
        'salary_template',
        {
          'name': template.name,
          'employer_id': template.employerId,
          'applies_to': template.appliesTo,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      // 改成"生效中"时，把同雇主同类型下别的模板取消生效，
      // 保证"每种类型最多一套生效"这条约束不被编辑操作破坏。
      if (template.isActive) {
        await txn.update(
          'salary_template',
          {'is_active': 0},
          where: 'id <> ? AND (employer_id = ? OR employer_id IS NULL) AND applies_to = ?',
          whereArgs: [id, template.employerId, template.appliesTo],
        );
      }
      await txn.delete('template_field', where: 'template_id = ?', whereArgs: [id]);
      await _writeFields(txn, id, template.fields);
    });
  }

  /// 删除模板。删掉的正好是生效那套时，把**同雇主同类型**剩下的第一套顶上，
  /// 否则这家公司会变成"没有生效模板"，录入突然不预填了。
  Future<void> delete(int id, {int? employerId}) async {
    await db.transaction((txn) async {
      final rows = await txn.query('salary_template',
          columns: ['is_active', 'applies_to'], where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final wasActive = (rows.first['is_active'] as int?) == 1;
      final appliesTo = (rows.first['applies_to'] as String?) ?? kTplMonthly;

      await txn.delete('salary_template', where: 'id = ?', whereArgs: [id]);
      if (!wasActive) return;

      final rest = await txn.query(
        'salary_template',
        columns: ['id'],
        where: '(employer_id = ? OR employer_id IS NULL) AND applies_to = ?',
        whereArgs: [employerId, appliesTo],
        orderBy: 'employer_id IS NULL ASC, updated_at DESC',
        limit: 1,
      );
      if (rest.isEmpty) return;
      await txn.update('salary_template', {'is_active': 1},
          where: 'id = ?', whereArgs: [rest.first['id']]);
    });
  }

  /// 切换生效模板。**只影响同一家雇主、同一适用类型**，
  /// 别家/别的类型（月度 vs 奖金）的生效状态不动。
  Future<void> setActive(int id, {int? employerId}) async {
    await db.transaction((txn) async {
      final rows = await txn.query('salary_template',
          columns: ['applies_to'], where: 'id = ?', whereArgs: [id]);
      final appliesTo =
          rows.isEmpty ? kTplMonthly : ((rows.first['applies_to'] as String?) ?? kTplMonthly);
      await txn.update(
        'salary_template',
        {'is_active': 0},
        where: '(employer_id = ? OR employer_id IS NULL) AND applies_to = ?',
        whereArgs: [employerId, appliesTo],
      );
      await txn.update('salary_template', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 把某个雇主名下的模板整体迁到另一个雇主（删除雇主时用）
  Future<void> moveToEmployer(int fromEmployerId, int toEmployerId) async {
    await db.update('salary_template', {'employer_id': toEmployerId},
        where: 'employer_id = ?', whereArgs: [fromEmployerId]);
  }

  Future<int> countOf(int? employerId) async {
    return Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM salary_template WHERE employer_id IS ?',
          [employerId],
        )) ??
        0;
  }

  Future<void> _writeFields(
      DatabaseExecutor txn, int templateId, List<TemplateField> fields) async {
    for (var i = 0; i < fields.length; i++) {
      final m = fields[i].toMap();
      m['template_id'] = templateId;
      m.remove('id');
      m['sort_order'] = i;
      await txn.insert('template_field', m);
    }
  }
}
