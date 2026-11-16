import 'package:sqflite/sqflite.dart';

import 'salary_template.dart';

/// 发薪模板读写。
///
/// 关键约束：**同一时间只能有一套生效**。切换生效模板时用事务先把所有
/// is_active 清零再置一，避免出现两套同时生效（会导致录入时字段重复）。
class SalaryTemplateDao {
  final Database db;
  SalaryTemplateDao(this.db);

  Future<List<SalaryTemplate>> loadAll() async {
    final templateRows =
        await db.query('salary_template', orderBy: 'is_active DESC, updated_at DESC, id ASC');
    if (templateRows.isEmpty) return [];

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

  /// 当前生效的模板；没有就返回 null（此时录入页不预填）
  Future<SalaryTemplate?> activeTemplate() async {
    final rows = await db.query('salary_template',
        where: 'is_active = 1', orderBy: 'updated_at DESC', limit: 1);
    if (rows.isEmpty) return null;
    final t = SalaryTemplate.fromMap(rows.first);
    final fieldRows = await db.query('template_field',
        where: 'template_id = ?', whereArgs: [t.id], orderBy: 'sort_order ASC, id ASC');
    t.fields = fieldRows.map(TemplateField.fromMap).toList();
    return t;
  }

  /// 新增模板，返回新 id。如果它是第一套，自动设为生效。
  Future<int> insert(SalaryTemplate template) async {
    return db.transaction((txn) async {
      final count = Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM salary_template')) ??
          0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = await txn.insert('salary_template', {
        'name': template.name,
        'is_active': count == 0 ? 1 : (template.isActive ? 1 : 0),
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
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.delete('template_field', where: 'template_id = ?', whereArgs: [id]);
      await _writeFields(txn, id, template.fields);
    });
  }

  Future<void> delete(int id) async {
    await db.delete('salary_template', where: 'id = ?', whereArgs: [id]);
  }

  /// 切换生效模板
  Future<void> setActive(int id) async {
    await db.transaction((txn) async {
      await txn.update('salary_template', {'is_active': 0});
      await txn.update('salary_template', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
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
