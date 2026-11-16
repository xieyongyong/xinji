import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'salary_template.dart';

/// 本地 SQLite。
///
/// 用 sqflite 手写 SQL 而不是 drift：省掉 build_runner 代码生成这一步，
/// 少一个环境坑（你本机现在还没装任何开发工具，能少一步就少一步）。
/// 数据模型和表结构完全不变。
class AppDb {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'xinji.db');
    _db = await openDatabase(
      fullPath,
      version: 5,
      onConfigure: (db) async {
        // 打开外键约束，保证删记录时级联清理明细/图片
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE pay_record (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employer_id INTEGER,
        period_year INTEGER NOT NULL,
        period_month INTEGER NOT NULL,
        record_type TEXT NOT NULL DEFAULT 'monthly',
        record_label TEXT,
        gross_cents INTEGER NOT NULL DEFAULT 0,
        deduction_cents INTEGER NOT NULL DEFAULT 0,
        net_cents INTEGER NOT NULL DEFAULT 0,
        extra TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_record_period ON pay_record(period_year, period_month)');

    await db.execute('''
      CREATE TABLE pay_image (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        ocr_text TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (record_id) REFERENCES pay_record(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_image_record ON pay_image(record_id)');

    await db.execute('''
      CREATE TABLE pay_item (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'income',
        value_type TEXT NOT NULL DEFAULT 'amount',
        amount_cents INTEGER NOT NULL DEFAULT 0,
        coefficient REAL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        source_image_id INTEGER,
        FOREIGN KEY (record_id) REFERENCES pay_record(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_item_record ON pay_item(record_id)');

    await db.execute('''
      CREATE TABLE item_template (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT NOT NULL DEFAULT 'income',
        aliases TEXT,
        value_type TEXT NOT NULL DEFAULT 'amount',
        sort_order INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await _createV2Tables(db);
    await _createV4Tables(db);
    await _seedTemplates(db);
    // 顺序有讲究：先建雇主，模板才知道挂给谁
    await _seedDefaultEmployer(db);
    await _seedDefaultSalaryTemplate(db);
  }

  /// v2 新增的三张表。
  ///
  /// 抽成函数是为了让「新建库」和「老库升级」走**同一段 SQL**，
  /// 避免两边写得不一样导致新老用户行为不同（这种 bug 最难查）。
  static Future<void> _createV2Tables(Database db) async {
    // 信息项：只记录、不计入合计
    await db.execute('''
      CREATE TABLE IF NOT EXISTS record_info (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        value TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (record_id) REFERENCES pay_record(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_info_record ON record_info(record_id)');

    // 发薪模板（可多套，仅一套 is_active = 1）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS salary_template (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employer_id INTEGER,
        name TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS template_field (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        template_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'income',
        value_type TEXT NOT NULL DEFAULT 'amount',
        sort_order INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (template_id) REFERENCES salary_template(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_field_template ON template_field(template_id)');
  }

  /// 版本升级入口。老用户的数据一条都不能丢，所以只做「加表/加字段」，从不删改。
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v2：信息项 + 发薪模板
      await _createV2Tables(db);
      await _seedDefaultSalaryTemplate(db);
    }
    if (oldVersion < 3) {
      // v3：基本绩效改为「推算值」（它不在应发里，早年被当成收入会多算一遍）
      await _migrateV3(db);
    }
    if (oldVersion < 4) {
      // v4：多雇主档案（跳槽后新旧工资条并存、互不干扰）
      await _migrateV4(db);
    }
    if (oldVersion < 5) {
      // v5：发薪模板挂到雇主下（一家公司可以有多套模板，各自一套生效）
      await _migrateV5(db);
    }
  }

  /// v5 迁移：模板归属到具体雇主。
  ///
  /// 老库里的模板是"全局一套"，跳槽后切生效会把别家一起改掉。
  /// 迁移做两件事：
  /// 1) 现有模板全部挂到第一家雇主（一条都不能丢，否则录入页突然不预填）
  /// 2) 其它有记录但没有模板的雇主，复制一份过去的模板
  ///    —— 否则那家公司的录入页永远是空表单
  static Future<void> _migrateV5(Database db) async {
    if (!await _hasColumn(db, 'salary_template', 'employer_id')) {
      await db.execute('ALTER TABLE salary_template ADD COLUMN employer_id INTEGER');
    }

    final first = await db.query('employer', columns: ['id'], orderBy: 'id ASC', limit: 1);
    if (first.isEmpty) return;
    final firstId = first.first['id'] as int;

    await db.update('salary_template', {'employer_id': firstId},
        where: 'employer_id IS NULL');

    final employers = await db.query('employer', columns: ['id']);
    for (final e in employers) {
      final id = e['id'] as int;
      if (id == firstId) continue;

      final recCount = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM pay_record WHERE employer_id = ?', [id])) ??
          0;
      if (recCount == 0) continue;

      final tplCount = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM salary_template WHERE employer_id = ?', [id])) ??
          0;
      if (tplCount > 0) continue;

      await _copyTemplateTo(db, firstId, id);
    }
  }

  /// 把 [fromEmployerId] 当前生效的模板复制一份给 [toEmployerId]
  static Future<void> _copyTemplateTo(
      Database db, int fromEmployerId, int toEmployerId) async {
    var src = await db.query('salary_template',
        where: 'employer_id = ? AND is_active = 1',
        whereArgs: [fromEmployerId],
        limit: 1);
    if (src.isEmpty) {
      src = await db.query('salary_template',
          where: 'employer_id = ?', whereArgs: [fromEmployerId], limit: 1);
    }
    if (src.isEmpty) return;

    final srcId = src.first['id'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    final newId = await db.insert('salary_template', {
      'employer_id': toEmployerId,
      'name': (src.first['name'] as String?) ?? '默认发薪模板',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    final fields = await db.query('template_field',
        where: 'template_id = ?', whereArgs: [srcId], orderBy: 'sort_order ASC, id ASC');
    final batch = db.batch();
    for (final f in fields) {
      batch.insert('template_field', {
        'template_id': newId,
        'name': f['name'],
        'category': f['category'],
        'value_type': f['value_type'],
        'sort_order': f['sort_order'],
      });
    }
    await batch.commit(noResult: true);
  }

  /// v4 新增：雇主表。新库、老库共用同一段 SQL。
  static Future<void> _createV4Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS employer (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        start_year INTEGER,
        start_month INTEGER,
        end_year INTEGER,
        end_month INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// 字段是否已存在（SQLite 没有 ADD COLUMN IF NOT EXISTS，只能自己查）
  static Future<bool> _hasColumn(Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    for (final r in rows) {
      if (r['name'] == column) return true;
    }
    return false;
  }

  /// v4 迁移：给所有历史记录挂上「第一家雇主」。
  ///
  /// 名字尽量从数据里猜：工资条上的「业务单位」最接近真实雇主。
  /// 猜不到才用「原雇主」兜底 —— 用户可以在「雇主档案」里改名。
  /// 关键点：**所有老记录都要挂上**，一条都不能漏。
  /// 漏掉的记录在"只看当前雇主"的视图里会彻底消失，那是最坏的结果。
  static Future<void> _migrateV4(Database db) async {
    await _createV4Tables(db);
    if (!await _hasColumn(db, 'pay_record', 'employer_id')) {
      await db.execute('ALTER TABLE pay_record ADD COLUMN employer_id INTEGER');
    }

    final existing = await db.query('employer', columns: ['id'], limit: 1);
    int? employerId = existing.isEmpty ? null : existing.first['id'] as int;

    if (employerId == null) {
      employerId = await db.insert('employer', {
        'name': await _guessEmployerName(db),
        'sort_order': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    await db.update('pay_record', {'employer_id': employerId},
        where: 'employer_id IS NULL');
  }

  /// 从历史数据里猜一个像样的雇主名
  static Future<String> _guessEmployerName(Database db) async {
    try {
      final rows = await db.rawQuery(
        "SELECT value, COUNT(*) AS c FROM record_info "
        "WHERE name = '业务单位' AND TRIM(COALESCE(value,'')) <> '' "
        "GROUP BY value ORDER BY c DESC LIMIT 1",
      );
      if (rows.isNotEmpty) {
        var v = (rows.first['value'] as String? ?? '').trim();
        // "生产运营一中心-奔图电子" → "奔图电子"：短一点更像公司名
        if (v.contains('-')) {
          final last = v.split('-').last.trim();
          if (last.length >= 2) v = last;
        }
        if (v.isNotEmpty && v.length <= 20) return v;
      }
    } catch (_) {
      // 表不存在或数据异常都无所谓，走兜底
    }
    return '原雇主';
  }

  /// 首次安装预置一家雇主，避免录入时"没得选"
  static Future<void> _seedDefaultEmployer(Database db) async {
    final existing = await db.query('employer', columns: ['id'], limit: 1);
    if (existing.isNotEmpty) return;
    await db.insert('employer', {
      'name': '我的公司',
      'sort_order': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// v3 迁移：只改「解释方式」，不动用户数据。
  ///
  /// 起因是真实工资条长这样：只印「本月绩效系数 1.1」和「实发绩效工资 1826」，
  /// 基本绩效 1660 是反推出来的，已经含在实发绩效里。
  /// 老版本把「基本绩效」当普通收入项，反推出来会凭空多 1660。
  static Future<void> _migrateV3(Database db) async {
    // 1) 基本绩效 → 推算值（不计入合计）
    await db.rawUpdate(
      "UPDATE template_field SET value_type = 'derived' "
      "WHERE name IN ('基本绩效','绩效基数','绩效基薪') AND value_type <> 'derived'",
    );

    // 2) 新识别叫法补进别名，保证跨月对比不断裂
    Future<void> addAlias(String name, String aliases) async {
      await db.rawUpdate(
        'UPDATE item_template SET aliases = TRIM(COALESCE(aliases, \'\') || \',$aliases\') '
        'WHERE name = ?',
        [name],
      );
    }

    await addAlias('绩效工资', '实发绩效工资,实发绩效');
    await addAlias('个人社保', '社保');
    await addAlias('加班费', '加班工资总额');

    // 3) 老模板里没有的项目补上（存在就跳过，绝不影响用户已改过的内容）
    Future<void> ensureItem(String name, String category, String aliases, int order) async {
      final exist = await db.query('item_template',
          columns: ['id'], where: 'name = ?', whereArgs: [name], limit: 1);
      if (exist.isNotEmpty) return;
      await db.insert('item_template', {
        'name': name,
        'category': category,
        'aliases': aliases,
        'value_type': 'amount',
        'sort_order': order,
        'enabled': 1,
      });
    }

    await ensureItem('特别奖金', 'income', '奖金,一次性奖金', 9);
    await ensureItem('伙食费', 'deduction', '透支伙食费,餐费,伙食', 17);

    // 4) 每套发薪模板补「特别奖金」和「部门」两个字段
    final templates = await db.query('salary_template', columns: ['id']);
    for (final t in templates) {
      final id = t['id'] as int;
      Future<void> ensureField(String name, String category, int order) async {
        final exist = await db.query('template_field',
            columns: ['id'],
            where: 'template_id = ? AND name = ?',
            whereArgs: [id, name],
            limit: 1);
        if (exist.isNotEmpty) return;
        await db.insert('template_field', {
          'template_id': id,
          'name': name,
          'category': category,
          'value_type': 'amount',
          'sort_order': order,
        });
      }

      await ensureField('特别奖金', 'income', 30);
      await ensureField('部门', 'info', 27);
    }
  }

  /// 首次安装时预置一套「默认发薪模板」并设为生效。
  ///
  /// 这样用户第一次录入就能直接看到常用字段，不用从零一个个加。
  static Future<void> _seedDefaultSalaryTemplate(Database db) async {
    final existing = await db.query('salary_template', limit: 1);
    if (existing.isNotEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    // 从 v1 直升上来时，雇主表可能还没建（建表在 _migrateV4 里），
    // 这里查不到就留空，后面 `_migrateV5` 会把它补到第一家雇主名下
    int? employerId;
    try {
      final employer = await db.query('employer', columns: ['id'], limit: 1);
      employerId = employer.isEmpty ? null : employer.first['id'] as int;
    } catch (_) {
      employerId = null;
    }
    final templateId = await db.insert('salary_template', {
      'employer_id': employerId,
      'name': '默认发薪模板',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    final fields = <TemplateField>[
      // ---- 收入项
      TemplateField(name: '基本工资', category: kCategoryIncome, sortOrder: 1),
      TemplateField(name: '岗位津贴', category: kCategoryIncome, sortOrder: 2),
      // 基本绩效不是"发给你的一笔钱"，而是绩效工资的基数：
      // 工资条上常常只给系数和实发绩效，它是反推出来的 → 设成推算值，不计入合计
      TemplateField(
          name: '基本绩效',
          category: kCategoryIncome,
          valueType: kValueDerived,
          sortOrder: 3),
      TemplateField(
          name: '绩效系数',
          category: kCategoryIncome,
          valueType: kValueCoefficient,
          sortOrder: 4),
      TemplateField(name: '绩效工资', category: kCategoryIncome, sortOrder: 5),
      TemplateField(name: '工龄补贴', category: kCategoryIncome, sortOrder: 6),
      TemplateField(name: '其他津贴', category: kCategoryIncome, sortOrder: 7),
      TemplateField(name: '加班费', category: kCategoryIncome, sortOrder: 8),
      TemplateField(name: '特别奖金', category: kCategoryIncome, sortOrder: 9),
      // ---- 扣款项
      TemplateField(name: '个人社保', category: kCategoryDeduction, sortOrder: 11),
      TemplateField(name: '个人公积金', category: kCategoryDeduction, sortOrder: 12),
      TemplateField(name: '所得税', category: kCategoryDeduction, sortOrder: 13),
      TemplateField(name: '管理费', category: kCategoryDeduction, sortOrder: 14),
      TemplateField(name: '水电费', category: kCategoryDeduction, sortOrder: 15),
      TemplateField(name: '其他扣款', category: kCategoryDeduction, sortOrder: 16),
      // ---- 信息项（不计入任何合计）
      TemplateField(name: '姓名', category: kFieldInfo, sortOrder: 21),
      TemplateField(name: '工号', category: kFieldInfo, sortOrder: 22),
      TemplateField(name: '部门', category: kFieldInfo, sortOrder: 23),
      TemplateField(name: '业务单位', category: kFieldInfo, sortOrder: 24),
      TemplateField(name: '薪级', category: kFieldInfo, sortOrder: 25),
      TemplateField(name: '薪级对应基薪', category: kFieldInfo, sortOrder: 26),
      TemplateField(name: '应出勤天数', category: kFieldInfo, sortOrder: 27),
    ];

    final batch = db.batch();
    for (final f in fields) {
      final m = f.toMap();
      m['template_id'] = templateId;
      m.remove('id');
      batch.insert('template_field', m);
    }
    await batch.commit(noResult: true);
  }

  /// 预置项目模板。用户随时可以改名、加别名、增删。
  static Future<void> _seedTemplates(Database db) async {
    final seeds = <ItemTemplate>[
      // 收入项
      ItemTemplate(
        name: '基本工资',
        category: kCategoryIncome,
        aliases: ['基薪', '基础工资', '岗位工资', '标准工资'],
        sortOrder: 1,
      ),
      ItemTemplate(
        name: '岗位津贴',
        category: kCategoryIncome,
        aliases: ['岗位补贴', '职务津贴', '岗位津贴合计'],
        sortOrder: 2,
      ),
      ItemTemplate(
        name: '绩效系数',
        category: kCategoryIncome,
        valueType: kValueCoefficient,
        aliases: ['绩效比例', '考核系数', '绩效分值'],
        sortOrder: 3,
      ),
      ItemTemplate(
        name: '绩效工资',
        category: kCategoryIncome,
        // 「实发绩效工资」必须在这里拦住：它含"实发"，
        // 不在别名里就会被判成实发合计（1826 顶替 8181）
        aliases: ['绩效奖金', '绩效', '考核工资', '实发绩效工资', '实发绩效'],
        sortOrder: 4,
      ),
      ItemTemplate(
        name: '工龄补贴',
        category: kCategoryIncome,
        aliases: ['工龄工资', '司龄补贴', '年功工资'],
        sortOrder: 5,
      ),
      ItemTemplate(
        name: '其他津贴',
        category: kCategoryIncome,
        aliases: ['其他补贴', '补助', '交通补贴', '餐补', '通讯补贴'],
        sortOrder: 6,
      ),
      ItemTemplate(
        name: '加班费',
        category: kCategoryIncome,
        aliases: ['加班工资', '延时加班', '加班工资总额', '加班费总额'],
        sortOrder: 7,
      ),
      ItemTemplate(
        name: '特别奖金',
        category: kCategoryIncome,
        aliases: ['奖金', '一次性奖金', '特殊奖金'],
        sortOrder: 8,
      ),
      // 扣款项（管理费、水电费按两项预置，若你公司是一项可自行合并）
      ItemTemplate(
        name: '个人社保',
        category: kCategoryDeduction,
        aliases: ['社会保险', '社保个人', '社保', '养老', '医疗保险', '失业保险'],
        sortOrder: 11,
      ),
      ItemTemplate(
        name: '个人公积金',
        category: kCategoryDeduction,
        aliases: ['住房公积金', '公积金个人', '公积金'],
        sortOrder: 12,
      ),
      ItemTemplate(
        name: '所得税',
        category: kCategoryDeduction,
        aliases: ['个人所得税', '个税', '扣缴个税'],
        sortOrder: 13,
      ),
      ItemTemplate(
        name: '管理费',
        category: kCategoryDeduction,
        aliases: ['综合管理费'],
        sortOrder: 14,
      ),
      ItemTemplate(
        name: '水电费',
        category: kCategoryDeduction,
        aliases: ['水电', '宿舍水电'],
        sortOrder: 15,
      ),
      ItemTemplate(
        name: '其他扣款',
        category: kCategoryDeduction,
        aliases: ['其他扣除', '罚款', '借款扣款', '补扣'],
        sortOrder: 16,
      ),
      ItemTemplate(
        name: '伙食费',
        category: kCategoryDeduction,
        aliases: ['透支伙食费', '餐费', '伙食'],
        sortOrder: 17,
      ),
    ];

    final batch = db.batch();
    for (final t in seeds) {
      batch.insert('item_template', t.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// 仅供备份恢复使用：整体清空后重建
  static Future<void> resetAll(Database db) async {
    await db.delete('record_info');
    await db.delete('pay_item');
    await db.delete('pay_image');
    await db.delete('pay_record');
  }
}
