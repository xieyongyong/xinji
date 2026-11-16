import 'package:sqflite/sqflite.dart';

import 'employer.dart';

/// 雇主读写。
///
/// 数据量极小（一辈子也就三五家），全部一次性加载进内存。
class EmployerDao {
  final Database db;
  EmployerDao(this.db);

  Future<List<Employer>> loadAll() async {
    final rows = await db.query('employer', orderBy: 'sort_order ASC, id ASC');
    return rows.map(Employer.fromMap).toList();
  }

  Future<int> insert(Employer e) async {
    final m = e.toMap();
    m.remove('id');
    if (m['created_at'] == 0 || m['created_at'] == null) {
      m['created_at'] = DateTime.now().millisecondsSinceEpoch;
    }
    return db.insert('employer', m);
  }

  Future<void> update(Employer e) async {
    final id = e.id;
    if (id == null) throw ArgumentError('update 需要 employer.id');
    final m = e.toMap();
    m.remove('id');
    await db.update('employer', m, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除雇主。**不在这里处理它名下的记录** ——
  /// 调用方必须先决定把记录迁到哪家，否则会留下看不见的孤儿数据。
  Future<void> delete(int id) async {
    await db.delete('employer', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> countRecords(int employerId) async {
    final rows = await db.query('pay_record',
        columns: ['id'], where: 'employer_id = ?', whereArgs: [employerId]);
    return rows.length;
  }

  Future<void> moveRecords(int fromId, int toId) async {
    await db.update('pay_record', {'employer_id': toId},
        where: 'employer_id = ?', whereArgs: [fromId]);
  }

  /// 兜底：把没挂雇主的记录（老库、异常导入）归到最后一家。
  /// 宁可归错也不让数据"消失" —— 归错了用户还能改，看不见就永远丢了。
  Future<int> assignOrphans(int employerId) async {
    return db.update('pay_record', {'employer_id': employerId},
        where: 'employer_id IS NULL');
  }
}
