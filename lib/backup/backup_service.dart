import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// 备份/恢复过程中的可读错误
class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

class BackupImportResult {
  final int recordCount;
  final int itemCount;
  final int imageCount;
  final bool wasEncrypted;
  BackupImportResult({
    required this.recordCount,
    required this.itemCount,
    required this.imageCount,
    required this.wasEncrypted,
  });
}

/// 备份与恢复。
///
/// 明文备份：一个 ZIP，里面是 data.json + images/ + 两个 CSV。
/// 加密备份：把 ZIP 整包用 AES-256-CBC 加密，存成 `.xbk`。
///
/// 为什么不用「ZIP 自带密码」：Flutter 的 archive 包不支持 AES ZIP 加密，
/// 硬做只能上老式 ZipCrypto（很弱且兼容性差）。整包加密更简单也更安全。
class BackupService {
  final Database db;
  BackupService(this.db);

  static const _magic = 'XBK1';
  static const int _saltLen = 16;
  static const int _ivLen = 16;

  /// 随备份带走的用户偏好（bool/int）。刻意不含应用锁 PIN、生物识别、
  /// 上次检查更新/跳过版本/上次备份时间——这些是安全凭证或临时状态。
  static const _prefBoolKeys = [
    'perf_auto',
    'compress_images',
    'de_watermark',
    'privacy_mask',
    'hide_amounts',
    'floating_lock',
    'floating_lock_size',
    'cloud_auto_backup',
  ];
  static const _prefIntKeys = [
    'color_up',
    'color_down',
    'theme_seed_index',
    'theme_mode',
    'lock_delay_seconds',
    'current_employer_id',
    'cloud_auto_backup_day',
    'cloud_auto_backup_last_at',
    'cloud_auto_backup_last_try',
  ];

  // ------------------------------------------------------------ 导出

  /// 生成备份文件，返回文件绝对路径
  Future<String> export({
    required bool encrypted,
    String? password,
  }) async {
    if (encrypted && (password == null || password.length < 4)) {
      throw BackupException('加密备份的密码至少 4 位');
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(docsDir.path, 'backups'));
    if (!await backupDir.exists()) await backupDir.create(recursive: true);

    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';

    final outBytes = await buildBytes(encrypted: encrypted, password: password);
    final outPath = p.join(
      backupDir.path,
      encrypted ? 'xinji_$stamp.xbk' : 'xinji_$stamp.zip',
    );
    await File(outPath).writeAsBytes(outBytes);
    return outPath;
  }

  static const MethodChannel _channel = MethodChannel('xinji/app');

  /// 备份文件信息（供「本地备份管理」列表用）
  static const _tmpPrefix = '.tmp_';

  /// 导出到公共 Download 目录（用户能在文件管理器里直接看到、删掉）。
  ///
  /// 流程：生成字节 → 写 cache 临时文件 → 原生用 MediaStore 复制到公共 Download。
  /// cache 副本留着供「发送到别处」分享用（cache 会被系统自动清理，不算私有备份堆积）；
  /// 私有 backups/ 目录不再新增文件。
  Future<DownloadExportResult> exportToDownloads({
    required bool encrypted,
    String? password,
  }) async {
    final bytes = await buildBytes(encrypted: encrypted, password: password);
    final stamp = _stamp(DateTime.now());
    final name = encrypted ? 'xinji_$stamp.xbk' : 'xinji_$stamp.zip';

    final tmpDir = await getTemporaryDirectory();
    final cacheFile = File(p.join(tmpDir.path, name));
    await cacheFile.writeAsBytes(bytes);

    try {
      final shown = await _channel.invokeMethod<String>('saveToDownloads', {
        'srcPath': cacheFile.path,
        'displayName': name,
      });
      return DownloadExportResult(
        shownPath: shown ?? 'Download/$name',
        sharePath: cacheFile.path,
        size: bytes.length,
      );
    } on PlatformException catch (e) {
      if (await cacheFile.exists()) {
        try {
          await cacheFile.delete();
        } catch (_) {}
      }
      throw BackupException('保存到下载目录失败：${e.message ?? e.code}');
    }
  }

  /// 列出私有 backups/ 目录里残留的历史备份（含大小、修改时间）。
  /// 新导出已走公共 Download，这里主要是让用户能清理以前累积的旧备份。
  Future<List<BackupFileMeta>> listLocalBackups() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(docsDir.path, 'backups'));
    if (!await backupDir.exists()) return [];
    final out = <BackupFileMeta>[];
    await for (final ent in backupDir.list(followLinks: false)) {
      if (ent is! File) continue;
      final name = p.basename(ent.path);
      // 跳过临时文件和非备份文件
      if (name.startsWith(_tmpPrefix)) continue;
      if (!name.endsWith('.zip') && !name.endsWith('.xbk')) continue;
      final st = await ent.stat();
      out.add(BackupFileMeta(
        path: ent.path,
        name: name,
        size: st.size,
        modified: st.modified,
      ));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 删除单个本地备份文件。返回是否真的删掉了。
  Future<bool> deleteLocalBackup(String path) async {
    final f = File(path);
    if (!await f.exists()) return false;
    await f.delete();
    return true;
  }

  String _stamp(DateTime now) =>
      '${now.year}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}_'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}';

  /// 生成备份字节（不落地），供本地导出和云盘上传共用。
  Future<List<int>> buildBytes({
    required bool encrypted,
    String? password,
  }) async {
    if (encrypted && (password == null || password.length < 4)) {
      throw BackupException('加密备份的密码至少 4 位');
    }

    final archive = Archive();

    // 1) 数据 JSON
    final data = await _collectData();
    final dataBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
    archive.addFile(ArchiveFile('data.json', dataBytes.length, dataBytes));

    // 2) 图片
    for (final row in (data['images'] as List).cast<Map<String, dynamic>>()) {
      final rel = row['file_path'] as String; // 备份内相对路径
      final abs = row['_abs_path'] as String;
      final f = File(abs);
      if (!await f.exists()) continue;
      final bytes = await f.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }

    // 3) CSV（方便直接用 Excel 看）
    final csvItems = _buildItemsCsv(data);
    final csvSummary = _buildSummaryCsv(data);
    final csvItemsBytes = utf8.encode(csvItems);
    final csvSummaryBytes = utf8.encode(csvSummary);
    archive.addFile(ArchiveFile('明细.csv', csvItemsBytes.length, csvItemsBytes));
    archive.addFile(
        ArchiveFile('月度汇总.csv', csvSummaryBytes.length, csvSummaryBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) throw BackupException('打包失败，请重试');

    if (encrypted) return _encrypt(Uint8List.fromList(zipBytes), password!);
    return zipBytes;
  }

  // ------------------------------------------------------------ 导入

  /// 文件是否是加密备份（读前 4 个字节的魔数）
  Future<bool> isEncryptedFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return false;
    final raf = await f.open();
    try {
      final head = await raf.read(4);
      return utf8.decode(head, allowMalformed: true) == _magic;
    } finally {
      await raf.close();
    }
  }

  /// 从文件恢复备份。会**清空现有数据**，调用方必须先跟用户确认。
  Future<BackupImportResult> importFromFile(String path, {String? password}) async {
    final f = File(path);
    if (!await f.exists()) throw BackupException('找不到备份文件');
    return restoreBytes(await f.readAsBytes(), password: password);
  }

  /// 从字节恢复（云盘下载后用）。会**清空现有数据**。
  Future<BackupImportResult> restoreBytes(List<int> rawBytes, {String? password}) async {
    Uint8List bytes = Uint8List.fromList(rawBytes);
    bool wasEncrypted = false;

    if (bytes.length > 4 && utf8.decode(bytes.sublist(0, 4), allowMalformed: true) == _magic) {
      wasEncrypted = true;
      if (password == null || password.isEmpty) {
        throw BackupException('这是加密备份，需要输入密码');
      }
      try {
        bytes = _decrypt(bytes, password);
      } catch (_) {
        throw BackupException('密码不对，或文件已损坏');
      }
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw BackupException('备份文件格式不正确');
    }

    final dataFile = archive.findFile('data.json');
    if (dataFile == null) throw BackupException('备份里缺少 data.json，可能不是薪迹的备份');

    final List<int> jsonBytes = _archiveBytes(dataFile.content);
    final Map<String, dynamic> data = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

    // 图片先解压到私有目录，再回填绝对路径
    final docsDir = await getApplicationDocumentsDirectory();
    final slipDir = Directory(p.join(docsDir.path, 'slips'));
    if (!await slipDir.exists()) await slipDir.create(recursive: true);

    final restamp = DateTime.now().millisecondsSinceEpoch;
    final pathMap = <String, String>{};

    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!file.name.startsWith('images/')) continue;
      final imgBytes = _archiveBytes(file.content);
      final baseName = p.basename(file.name);
      final newAbs = p.join(slipDir.path, 'r${restamp}_$baseName');
      await File(newAbs).writeAsBytes(imgBytes);
      pathMap[file.name] = newAbs;
    }

    final records = (data['records'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final items = (data['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final images = (data['images'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final templates = (data['templates'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // v2 备份才有这两块，老备份读出来是 null，走空列表即可
    final infos = (data['infos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final salaryTemplates =
        (data['salary_templates'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final templateFields =
        (data['template_fields'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // v3 备份才有雇主；老备份读出来是 null
    final employers = (data['employers'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    await db.transaction((txn) async {
      // 全量替换：先清空，再按原 id 插回，保证外键关系不变
      await txn.delete('record_info');
      await txn.delete('pay_item');
      await txn.delete('pay_image');
      await txn.delete('pay_record');
      await txn.delete('item_template');
      await txn.delete('employer');

      for (final e in employers) {
        await txn.insert('employer', _sanitize(e, const {
          'id', 'name', 'start_year', 'start_month', 'end_year', 'end_month',
          'sort_order', 'created_at',
        }));
      }

      // 老备份没有雇主信息：补一家并把记录全挂上去，
      // 否则恢复完所有记录都会因为没有 employer_id 而在首页"消失"
      int? fallbackEmployerId;
      if (employers.isEmpty) {
        fallbackEmployerId = await txn.insert('employer', {
          'name': '我的公司',
          'sort_order': 0,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
      final employerRows = await txn.query('employer',
          columns: ['id'], orderBy: 'id ASC', limit: 1);
      final int? anyEmployerId =
          employerRows.isEmpty ? null : employerRows.first['id'] as int;

      for (final r in records) {
        final m = _sanitize(r, const {
          'id', 'employer_id', 'period_year', 'period_month', 'record_type',
          'record_label', 'gross_cents', 'deduction_cents', 'net_cents', 'extra',
          'created_at', 'updated_at',
        });
        if (m['employer_id'] == null) {
          m['employer_id'] = fallbackEmployerId ?? anyEmployerId;
        }
        await txn.insert('pay_record', m);
      }

      for (final it in items) {
        await txn.insert('pay_item', _sanitize(it, const {
          'id', 'record_id', 'name', 'category', 'value_type',
          'amount_cents', 'coefficient', 'sort_order', 'source_image_id',
        }));
      }

      for (final im in images) {
        final rel = im['file_path'] as String? ?? '';
        final newPath = pathMap[rel] ?? '';
        final m = _sanitize(im, const {
          'id', 'record_id', 'file_path', 'sort_order', 'ocr_text', 'created_at',
        });
        m['file_path'] = newPath;
        await txn.insert('pay_image', m);
      }

      for (final t in templates) {
        await txn.insert('item_template', _sanitize(t, const {
          'id', 'name', 'category', 'aliases', 'value_type', 'sort_order', 'enabled',
        }));
      }

      for (final info in infos) {
        await txn.insert('record_info', _sanitize(info, const {
          'id', 'record_id', 'name', 'value', 'sort_order',
        }));
      }

      // 发薪模板：只有新备份才带，老备份不覆盖用户现有模板
      if (salaryTemplates.isNotEmpty) {
        await txn.delete('template_field');
        await txn.delete('salary_template');
        for (final st in salaryTemplates) {
          await txn.insert('salary_template', _sanitize(st, const {
            'id', 'employer_id', 'name', 'applies_to', 'is_active', 'created_at',
            'updated_at',
          }));
        }
        for (final tf in templateFields) {
          await txn.insert('template_field', _sanitize(tf, const {
            'id', 'template_id', 'name', 'category', 'value_type', 'sort_order',
          }));
        }

        // 老备份里的模板：employer_id 为 NULL，或指向已被重建的旧雇主 id
        // （恢复时 employer 表按备份重建/补了"我的公司"，旧 id 已不存在），
        // 都要挂到第一家，否则按雇主取模板全部落空，录入页突然不预填。
        final firstEmp = await txn.query('employer',
            columns: ['id'], orderBy: 'id ASC', limit: 1);
        if (firstEmp.isNotEmpty) {
          final firstId = firstEmp.first['id'];
          await txn.update(
            'salary_template',
            {'employer_id': firstId},
            where: 'employer_id IS NULL OR employer_id NOT IN (SELECT id FROM employer)',
          );
        }
      }
    });

    // 恢复用户偏好（老备份没有 prefs 节点，跳过即可）
    await _restorePrefs(data['prefs']);

    return BackupImportResult(
      recordCount: records.length,
      itemCount: items.length,
      imageCount: images.length,
      wasEncrypted: wasEncrypted,
    );
  }

  /// 把备份里的偏好写回 SharedPreferences。只认白名单 key 且类型匹配，
  /// 避免坏备份把设置写成乱七八糟的值。
  Future<void> _restorePrefs(dynamic raw) async {
    if (raw is! Map) return;
    final sp = await SharedPreferences.getInstance();
    for (final k in _prefBoolKeys) {
      final v = raw[k];
      if (v is bool) await sp.setBool(k, v);
    }
    for (final k in _prefIntKeys) {
      final v = raw[k];
      if (v is int) await sp.setInt(k, v);
    }
  }

  /// 只保留白名单里的字段，避免备份文件里多了列导致插入失败
  Map<String, Object?> _sanitize(Map<String, dynamic> raw, Set<String> allowed) {
    final out = <String, Object?>{};
    raw.forEach((k, v) {
      if (!allowed.contains(k)) return;
      out[k] = v is num ? v : (v is String || v == null ? v : v.toString());
    });
    return out;
  }

  // ------------------------------------------------------------ 数据收集

  Future<Map<String, dynamic>> _collectData() async {
    final records = await db.query('pay_record');
    final items = await db.query('pay_item');
    final imageRows = await db.query('pay_image');
    final templates = await db.query('item_template');

    // v2 新增：信息项 + 发薪模板（都属于用户数据，必须一起备份）
    final infos = await db.query('record_info');
    final salaryTemplates = await db.query('salary_template');
    final templateFields = await db.query('template_field');
    final employers = await db.query('employer');

    // 用户偏好快照（换机恢复后设置原样保留）
    final prefs = await _collectPrefs();

    final images = <Map<String, dynamic>>[];
    for (final row in imageRows) {
      final abs = row['file_path'] as String? ?? '';
      if (abs.isEmpty) continue;
      final baseName = p.basename(abs);
      final m = Map<String, dynamic>.from(row);
      m['_abs_path'] = abs;
      // 备份内部统一用相对路径，换手机后绝对路径会变
      m['file_path'] = 'images/$baseName';
      images.add(m);
    }

    return {
      'app': 'xinji',
      'version': 4,
      'exported_at': DateTime.now().toIso8601String(),
      'records': records.map((e) => Map<String, dynamic>.from(e)).toList(),
      'items': items.map((e) => Map<String, dynamic>.from(e)).toList(),
      'images': images,
      'templates': templates.map((e) => Map<String, dynamic>.from(e)).toList(),
      'infos': infos.map((e) => Map<String, dynamic>.from(e)).toList(),
      'salary_templates':
          salaryTemplates.map((e) => Map<String, dynamic>.from(e)).toList(),
      'template_fields':
          templateFields.map((e) => Map<String, dynamic>.from(e)).toList(),
      'employers': employers.map((e) => Map<String, dynamic>.from(e)).toList(),
      'prefs': prefs,
    };
  }

  /// 读取要随备份带走的偏好。没设过的 key 不写，恢复时保持默认值。
  Future<Map<String, dynamic>> _collectPrefs() async {
    final sp = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final k in _prefBoolKeys) {
      final v = sp.getBool(k);
      if (v != null) out[k] = v;
    }
    for (final k in _prefIntKeys) {
      final v = sp.getInt(k);
      if (v != null) out[k] = v;
    }
    return out;
  }

  // ------------------------------------------------------------ CSV

  /// 明细表：一行一个明细项，Excel 里可以直接透视
  String _buildItemsCsv(Map<String, dynamic> data) {
    final records = (data['records'] as List).cast<Map<String, dynamic>>();
    final items = (data['items'] as List).cast<Map<String, dynamic>>();

    final recordInfo = <int, Map<String, dynamic>>{};
    for (final r in records) {
      recordInfo[r['id'] as int] = r;
    }

    final buf = StringBuffer();
    // BOM：不加这 3 个字节，Excel 打开中文会乱码
    buf.write('\uFEFF');
    final employerName = <int, String>{};
    for (final e in ((data['employers'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()) {
      employerName[e['id'] as int] = (e['name'] as String?) ?? '';
    }

    buf.writeln('年份,月份,雇主,记录类型,记录说明,项目,分类,金额,系数');

    for (final it in items) {
      final rec = recordInfo[it['record_id'] as int?];
      if (rec == null) continue;
      final type = rec['record_type'] == 'monthly' ? '月度工资' : '其他收入';
      final label = (rec['record_label'] as String?) ?? '';
      final cents = (it['amount_cents'] as int?) ?? 0;
      final coef = it['coefficient'];
      final value = coef != null ? '' : _plain(cents);
      buf.writeln([
        rec['period_year'],
        rec['period_month'],
        _csv(employerName[rec['employer_id'] as int?] ?? ''),
        type,
        _csv(label),
        _csv((it['name'] as String?) ?? ''),
        it['category'] == 'income' ? '收入' : '扣款',
        value,
        coef ?? '',
      ].join(','));
    }
    return buf.toString();
  }

  /// 月度汇总表：一月一行（同月多笔已合并）
  String _buildSummaryCsv(Map<String, dynamic> data) {
    final records = (data['records'] as List).cast<Map<String, dynamic>>();

    final buf = StringBuffer();
    buf.write('\uFEFF');
    final employerName = <int, String>{};
    for (final e in ((data['employers'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()) {
      employerName[e['id'] as int] = (e['name'] as String?) ?? '';
    }

    buf.writeln('年份,月份,雇主,记录类型,记录说明,应发合计,代扣合计,实发,录入笔数');

    // 分组键必须带上雇主：两家公司在同一个月各发一次工资，
    // 不带雇主就会被合并成一行，金额凭空翻倍
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in records) {
      final key = '${r['employer_id']}-${r['period_year']}-'
          '${r['period_month']}-${r['record_type']}';
      grouped.putIfAbsent(key, () => []).add(r);
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) {
        final pa = a.split('-');
        final pb = b.split('-');
        // key = 雇主-年-月-类型
        final y = int.parse(pb[pb.length - 3]) - int.parse(pa[pa.length - 3]);
        if (y != 0) return y;
        return int.parse(pb[pb.length - 2]) - int.parse(pa[pa.length - 2]);
      });

    for (final k in keys) {
      final list = grouped[k]!;
      final first = list.first;
      final gross = list.fold<int>(0, (s, e) => s + ((e['gross_cents'] as int?) ?? 0));
      final ded = list.fold<int>(0, (s, e) => s + ((e['deduction_cents'] as int?) ?? 0));
      final net = list.fold<int>(0, (s, e) => s + ((e['net_cents'] as int?) ?? 0));
      buf.writeln([
        first['period_year'],
        first['period_month'],
        _csv(employerName[first['employer_id'] as int?] ?? ''),
        first['record_type'] == 'monthly' ? '月度工资' : '其他收入',
        _csv((first['record_label'] as String?) ?? ''),
        _plain(gross),
        _plain(ded),
        _plain(net),
        list.length,
      ].join(','));
    }
    return buf.toString();
  }

  String _plain(int cents) {
    final neg = cents < 0;
    final a = cents.abs();
    return '${neg ? '-' : ''}${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
  }

  String _csv(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  // ------------------------------------------------------------ 加密

  List<int> _deriveKey(String password, List<int> salt) {
    var d = sha256.convert([...salt, ...utf8.encode(password)]).bytes;
    for (var i = 0; i < 10000; i++) {
      d = sha256.convert([...d, ...salt]).bytes;
    }
    return d; // 32 字节，AES-256
  }

  Uint8List _encrypt(Uint8List plain, String password) {
    // 盐和 IV 都用系统安全随机源生成，每次备份都不同
    final salt = Uint8List.fromList(enc.IV.fromSecureRandom(_saltLen).bytes);
    final iv = enc.IV.fromSecureRandom(_ivLen);
    final key = enc.Key(Uint8List.fromList(_deriveKey(password, salt)));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

    final cipher = encrypter.encryptBytes(plain, iv: iv);

    final out = BytesBuilder();
    out.add(utf8.encode(_magic));
    out.add(salt);
    out.add(iv.bytes);
    out.add(cipher.bytes);
    return out.toBytes();
  }

  Uint8List _decrypt(Uint8List raw, String password) {
    if (raw.length < 4 + _saltLen + _ivLen) {
      throw BackupException('文件已损坏');
    }
    final salt = raw.sublist(4, 4 + _saltLen);
    final ivBytes = raw.sublist(4 + _saltLen, 4 + _saltLen + _ivLen);
    final cipherBytes = raw.sublist(4 + _saltLen + _ivLen);

    final key = enc.Key(Uint8List.fromList(_deriveKey(password, salt)));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    final plain = encrypter.decryptBytes(enc.Encrypted(Uint8List.fromList(cipherBytes)),
        iv: enc.IV(Uint8List.fromList(ivBytes)));
    return Uint8List.fromList(plain);
  }
}

/// 导出到 Download 的结果
class DownloadExportResult {
  /// 展示给用户看的路径，如 "Download/xinji_20261119_0930.xbk"
  final String shownPath;
  /// cache 里的绝对路径，供「发送到别处」分享用
  final String sharePath;
  final int size;
  DownloadExportResult({
    required this.shownPath,
    required this.sharePath,
    required this.size,
  });
}

/// 私有备份目录里的一份备份文件（供「本地备份管理」列表展示）
class BackupFileMeta {
  final String path;
  final String name;
  final int size;
  final DateTime modified;
  BackupFileMeta({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });
}

/// 把 `ArchiveFile.content` 统一转成字节数组。
///
/// 为什么需要这个函数：archive 3.x 的 `content` 是 dynamic 类型——
/// 我们自己 new 出来的文件是 List<int>，而从 ZIP 里解出来的文件是
/// `InputStream`（懒加载，读到哪算哪）。
///
/// 注意：`InputStream` 提供的转换方法是 `toUint8List()`，
/// 不是 `toUint8Array()`——后者在这个版本里根本不存在，写了会编译失败。
List<int> _archiveBytes(dynamic content) {
  if (content is List<int>) return content;
  if (content is InputStream) return content.toUint8List();
  throw BackupException('备份文件内容无法解析');
}
