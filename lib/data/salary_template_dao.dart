import 'package:sqflite/sqflite.dart';

import 'salary_template.dart';

/// 发薪模板读写。
///
/// 关键约束：**每家公司各自只能有一套生效**。
///
/// 以前是全局只有一套生效，跳槽后就会打架：
/// 把新公司的模板设成生效，旧公司的录入预填也被一起换掉了。
/// 现在按 employer_id 分组，切换生效时只清同一家公司名下的 is_active，
/// 别家的"生效中"原封不动。
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

  /// 某家雇主当前生效的模板。
  ///
  /// 没有明确标记生效时退到该雇主名下最近改过的那套 ——
  /// 宁可预填一套"可能不对"的，也不要让用户面对空表单。
  Future<SalaryTemplate?> activeTemplateFor(int? employerId) async {
    final rows = await db.query(
      'salary_template',
      where: '(employer_id = ? OR employer_id IS NULL) AND is_active = 1',
      whereArgs: [employerId],
      orderBy: 'employer_id IS NULL ASC, updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      final any = await db.query(
        'salary_template',
        where: employerId == null ? null : '(employer_id = ? OR employer_id IS NULL)',
        whereArgs: employerId == null ? null : [employerId],
        orderBy: 'updated_at DESC, id ASC',
        limit: 1,
      );
      if (any.isEmpty) return null;
      return _withFields(any.first);
    }
    return _withFields(rows.first);
  }

  Future<SalaryTemplate> _withFields(Map<String, Object?> row) async {
    final t = SalaryTemplate.fromMap(row);
    final fieldRows = await db.query('template_field',
        where: 'template_id = ?', whereArgs: [t.id], orderBy: 'sort_order ASC, id ASC');
    t.fields = fieldRows.map(TemplateField.fromMap).toList();
    return t;
  }

  /// 新增模板，返回新 id。**这家雇主**名下的第一套自动设为生效。
  Future<int> insert(SalaryTemplate template) async {
    final employerId = template.employerId;
    return db.transaction((txn) async {
      final count = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM salary_template WHERE employer_id IS ?',
            [employerId],
          )) ??
          0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = await txn.insert('salary_template', {
        'employer_id': employerId,
        'name': template.name,
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
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.delete('template_field', where: 'template_id = ?', whereArgs: [id]);
      await _writeFields(txn, id, template.fields);
    });
  }

  /// 删除模板。删掉的正好是生效那套时，把同雇主剩下的第一套顶上，
  /// 否则这家公司会变成"没有生效模板"，录入突然不预填了。
  Future<void> delete(int id, {int? employerId}) async {
    await db.transaction((txn) async {
      final wasActive = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT is_active FROM salary_template WHERE id = ?', [id],
          )) ==
          1;
      await txn.delete('salary_template', where: 'id = ?', whereArgs: [id]);
      if (!wasActive) return;

      final rest = await txn.query(
        'salary_template',
        columns: ['id'],
        where: '(employer_id = ? OR employer_id IS NULL)',
        whereArgs: [employerId],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (rest.isEmpty) return;
      await txn.update('salary_template', {'is_active': 1},
          where: 'id = ?', whereArgs: [rest.first['id']]);
    });
  }

  /// 切换生效模板。**只影响同一家雇主**，别家的生效状态不动。
  Future<void> setActive(int id, {int? employerId}) async {
    await db.transaction((txn) async {
      await txn.update(
        'salary_template',
        {'is_active': 0},
        where: '(employer_id = ? OR employer_id IS NULL)',
        whereArgs: [employerId],
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
