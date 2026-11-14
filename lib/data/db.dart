import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

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
      version: 1,
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

    await _seedTemplates(db);
  }

  /// 版本升级入口。将来加字段就在这里写 ALTER TABLE，用户数据不会丢。
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 目前只有 v1。后续示例：
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE pay_record ADD COLUMN xxx TEXT');
    // }
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
        aliases: ['绩效奖金', '绩效', '考核工资'],
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
        aliases: ['加班工资', '延时加班'],
        sortOrder: 7,
      ),
      // 扣款项（管理费、水电费按两项预置，若你公司是一项可自行合并）
      ItemTemplate(
        name: '个人社保',
        category: kCategoryDeduction,
        aliases: ['社会保险', '社保个人', '养老', '医疗保险', '失业保险'],
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
    ];

    final batch = db.batch();
    for (final t in seeds) {
      batch.insert('item_template', t.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// 仅供备份恢复使用：整体清空后重建
  static Future<void> resetAll(Database db) async {
    await db.delete('pay_item');
    await db.delete('pay_image');
    await db.delete('pay_record');
  }
}
