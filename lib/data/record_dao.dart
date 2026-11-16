import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 记录相关读写。数据量很小（一年几十条），
/// 直接全量加载到内存再算统计，比写复杂 SQL 更简单也不慢。
class RecordDao {
  final Database db;
  RecordDao(this.db);

  /// 全量加载，并把明细、图片挂回各自的记录
  Future<List<PayRecord>> loadAll() async {
    final recordRows = await db.query(
      'pay_record',
      orderBy: 'period_year DESC, period_month DESC, created_at DESC',
    );
    if (recordRows.isEmpty) return [];

    final itemRows = await db.query('pay_item', orderBy: 'sort_order ASC, id ASC');
    final imageRows = await db.query('pay_image', orderBy: 'sort_order ASC, id ASC');
    final infoRows = await db.query('record_info', orderBy: 'sort_order ASC, id ASC');

    final itemsByRecord = <int, List<PayItem>>{};
    for (final r in itemRows) {
      final item = PayItem.fromMap(r);
      if (item.recordId == null) continue;
      itemsByRecord.putIfAbsent(item.recordId!, () => []).add(item);
    }

    final imagesByRecord = <int, List<PayImage>>{};
    for (final r in imageRows) {
      final img = PayImage.fromMap(r);
      if (img.recordId == null) continue;
      imagesByRecord.putIfAbsent(img.recordId!, () => []).add(img);
    }

    final infosByRecord = <int, List<PayInfo>>{};
    for (final r in infoRows) {
      final info = PayInfo.fromMap(r);
      if (info.recordId == null) continue;
      infosByRecord.putIfAbsent(info.recordId!, () => []).add(info);
    }

    return recordRows.map((r) {
      final rec = PayRecord.fromMap(r);
      rec.items = itemsByRecord[rec.id] ?? const [];
      rec.images = imagesByRecord[rec.id] ?? const [];
      rec.infos = infosByRecord[rec.id] ?? const [];
      return rec;
    }).toList();
  }

  Future<PayRecord?> loadById(int id) async {
    final rows = await db.query('pay_record', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final rec = PayRecord.fromMap(rows.first);
    final itemRows =
        await db.query('pay_item', where: 'record_id = ?', whereArgs: [id], orderBy: 'sort_order ASC, id ASC');
    final imageRows =
        await db.query('pay_image', where: 'record_id = ?', whereArgs: [id], orderBy: 'sort_order ASC, id ASC');
    final infoRows =
        await db.query('record_info', where: 'record_id = ?', whereArgs: [id], orderBy: 'sort_order ASC, id ASC');
    rec.items = itemRows.map(PayItem.fromMap).toList();
    rec.images = imageRows.map(PayImage.fromMap).toList();
    rec.infos = infoRows.map(PayInfo.fromMap).toList();
    return rec;
  }

  /// 新增一条记录（含明细、图片、信息项），事务保证要么全成要么全不成
  Future<int> insert(PayRecord record, List<PayItem> items, List<PayImage> images,
      [List<PayInfo> infos = const []]) async {
    return db.transaction((txn) async {
      final recordId = await txn.insert('pay_record', record.toMap());

      for (var i = 0; i < items.length; i++) {
        final m = items[i].toMap();
        m['record_id'] = recordId;
        m.remove('id');
        m['sort_order'] = i;
        await txn.insert('pay_item', m);
      }

      for (var i = 0; i < images.length; i++) {
        final m = images[i].toMap();
        m['record_id'] = recordId;
        m.remove('id');
        m['sort_order'] = i;
        await txn.insert('pay_image', m);
      }

      for (var i = 0; i < infos.length; i++) {
        final m = infos[i].toMap();
        m['record_id'] = recordId;
        m.remove('id');
        m['sort_order'] = i;
        await txn.insert('record_info', m);
      }

      return recordId;
    });
  }

  /// 编辑：明细、图片、信息项整组替换（比逐条 diff 简单可靠）
  Future<void> update(PayRecord record, List<PayItem> items, List<PayImage> images,
      [List<PayInfo> infos = const []]) async {
    final id = record.id;
    if (id == null) throw ArgumentError('update 需要 record.id');

    await db.transaction((txn) async {
      final m = record.toMap();
      m.remove('id');
      m['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await txn.update('pay_record', m, where: 'id = ?', whereArgs: [id]);

      await txn.delete('pay_item', where: 'record_id = ?', whereArgs: [id]);
      await txn.delete('pay_image', where: 'record_id = ?', whereArgs: [id]);
      await txn.delete('record_info', where: 'record_id = ?', whereArgs: [id]);

      for (var i = 0; i < items.length; i++) {
        final im = items[i].toMap();
        im['record_id'] = id;
        im.remove('id');
        im['sort_order'] = i;
        await txn.insert('pay_item', im);
      }
      for (var i = 0; i < images.length; i++) {
        final gm = images[i].toMap();
        gm['record_id'] = id;
        gm.remove('id');
        gm['sort_order'] = i;
        await txn.insert('pay_image', gm);
      }
      for (var i = 0; i < infos.length; i++) {
        final fm = infos[i].toMap();
        fm['record_id'] = id;
        fm.remove('id');
        fm['sort_order'] = i;
        await txn.insert('record_info', fm);
      }
    });
  }

  /// 导出用：把信息项一并取出（备份需要原样带走）
  Future<List<Map<String, Object?>>> dumpInfos() =>
      db.query('record_info', orderBy: 'record_id ASC, sort_order ASC');

  /// 删除记录，同时把私有目录里的图片文件删掉，避免垃圾文件堆积
  Future<void> delete(int id) async {
    final imageRows = await db.query('pay_image', where: 'record_id = ?', whereArgs: [id]);
    for (final r in imageRows) {
      final path = r['file_path'] as String?;
      if (path == null || path.isEmpty) continue;
      final f = File(path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {
          // 文件删不掉不影响记录删除
        }
      }
    }
    await db.delete('pay_record', where: 'id = ?', whereArgs: [id]);
  }

  /// 同一个月是否已有月度工资记录（用于录入时提示）
  Future<int> monthlyCountOf(int year, int month) async {
    final rows = await db.query(
      'pay_record',
      where: "period_year = ? AND period_month = ? AND record_type = 'monthly'",
      whereArgs: [year, month],
      columns: ['id'],
    );
    return rows.length;
  }
}
