import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 项目模板读写。模板既供 OCR 匹配，也供跨月对比对齐项目名。
class TemplateDao {
  final Database db;
  TemplateDao(this.db);

  Future<List<ItemTemplate>> loadAll() async {
    final rows = await db.query(
      'item_template',
      where: 'enabled = 1',
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(ItemTemplate.fromMap).toList();
  }

  /// 包含已停用的（设置页管理用）
  Future<List<ItemTemplate>> loadAllIncludingDisabled() async {
    final rows = await db.query('item_template', orderBy: 'sort_order ASC, id ASC');
    return rows.map(ItemTemplate.fromMap).toList();
  }

  Future<int> insert(ItemTemplate t) => db.insert('item_template', t.toMap());

  Future<void> update(ItemTemplate t) async {
    if (t.id == null) return;
    final m = t.toMap();
    m.remove('id');
    await db.update('item_template', m, where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> delete(int id) => db.delete('item_template', where: 'id = ?', whereArgs: [id]);

  /// 按名称查找（含别名匹配），供 OCR 归类使用
  ItemTemplate? findByName(List<ItemTemplate> all, String rawName) {
    for (final t in all) {
      if (t.matches(rawName)) return t;
    }
    return null;
  }
}
