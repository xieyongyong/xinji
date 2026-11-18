import 'package:flutter_test/flutter_test.dart';
import 'package:xinji/core/money.dart';
import 'package:xinji/data/models.dart';
import 'package:xinji/ocr/field_parser.dart';
import 'package:xinji/ocr/merge_engine.dart';
import 'package:xinji/ocr/ocr_models.dart';

/// 构造一行解析结果
ParsedRow r(
  String name,
  int? cents, {
  int img = 0,
  double top = 0,
  ParsedRowKind kind = ParsedRowKind.item,
}) =>
    ParsedRow(
      name: name,
      amountCents: cents,
      kind: kind,
      raw: name,
      imageIndex: img,
      top: top,
    );

ParsedImage image(int index, List<ParsedRow> rows) =>
    ParsedImage(index: index, filePath: 'img$index.jpg', rows: rows, rawText: '');

void main() {
  group('多图重叠合并', () {
    test('相邻两张图的重叠行只保留一份', () {
      final img1 = image(0, [
        r('基本工资', 800000),
        r('岗位津贴', 100000),
        r('绩效工资', 200000),
      ]);
      final img2 = image(1, [
        r('绩效工资', 200000, img: 1), // 与图1最后一行重叠
        r('工龄补贴', 50000, img: 1),
        r('个人社保', 30000, img: 1),
      ]);

      final result = MergeEngine(const []).merge([img1, img2]);

      expect(result.overlapRemovedRows, 1, reason: '应该识别出 1 行重叠');
      expect(result.items.length, 5, reason: '合计 5 项，绩效工资不能重复');
      expect(
        result.items.map((e) => e.name).toList(),
        ['基本工资', '岗位津贴', '绩效工资', '工龄补贴', '个人社保'],
      );
    });

    test('多行重叠也能正确去掉', () {
      final img1 = image(0, [
        r('基本工资', 800000),
        r('岗位津贴', 100000),
        r('绩效工资', 200000),
        r('工龄补贴', 50000),
      ]);
      final img2 = image(1, [
        r('绩效工资', 200000, img: 1),
        r('工龄补贴', 50000, img: 1),
        r('个人社保', 30000, img: 1),
        r('所得税', 20000, img: 1),
      ]);

      final result = MergeEngine(const []).merge([img1, img2]);

      expect(result.overlapRemovedRows, 2);
      expect(result.items.length, 6);
    });

    test('整张图都是重复内容时跳过整张', () {
      final img1 = image(0, [r('基本工资', 800000), r('岗位津贴', 100000)]);
      final img2 = image(1, [
        r('基本工资', 800000, img: 1),
        r('岗位津贴', 100000, img: 1),
      ]);

      final result = MergeEngine(const []).merge([img1, img2]);

      expect(result.items.length, 2);
    });

    test('没有重叠时要给出告警，而不是静默拼接', () {
      final img1 = image(0, [r('基本工资', 800000)]);
      final img2 = image(1, [r('个人社保', 30000, img: 1)]);

      final result = MergeEngine(const []).merge([img1, img2]);

      expect(result.items.length, 2, reason: '数据都要保留');
      expect(
        result.issues.any((e) => e.type == MergeIssueType.noOverlap),
        isTrue,
        reason: '应提示可能漏截',
      );
    });

    test('同名不同额不能合并（可能是两笔真实记录）', () {
      final img1 = image(0, [r('基本工资', 800000), r('项目奖金', 500000)]);
      final img2 = image(1, [r('项目奖金', 300000, img: 1)]);

      final result = MergeEngine(const []).merge([img1, img2]);

      final bonuses = result.items.where((e) => e.name == '项目奖金').toList();
      expect(bonuses.length, 2, reason: '两个不同金额都是真实数据，都要留');
      expect(
        result.issues.any((e) => e.type == MergeIssueType.sameNameConflict),
        isTrue,
      );
    });

    test('明细加总与应发合计不一致时要告警', () {
      final img = image(0, [
        r('基本工资', 800000),
        r('应发合计', 900000, kind: ParsedRowKind.totalGross),
      ]);

      final result = MergeEngine(const []).merge([img]);

      expect(result.grossCents, 900000);
      expect(
        result.issues.any((e) => e.type == MergeIssueType.totalMismatch),
        isTrue,
      );
    });

    test('工资条没写合计时，用明细自动算出来', () {
      final img = image(0, [
        r('基本工资', 800000),
        r('岗位津贴', 100000),
        r('个人社保', 50000),
      ]);

      final result = MergeEngine(const []).merge([img]);

      expect(result.grossCents, 900000);
      expect(result.deductionTotalCents, 50000);
      expect(result.netCents, 850000);
    });
  });

  group('金额解析', () {
    test('千分位与货币符号', () {
      expect(parseAmountToCents('¥12,345.67'), 1234567);
      expect(parseAmountToCents('12,345.67元'), 1234567);
      expect(parseAmountToCents('￥12345.6'), 1234560);
    });

    test('负数两种写法', () {
      expect(parseAmountToCents('-1,234.00'), -123400);
      expect(parseAmountToCents('(1,234.00)'), -123400);
    });

    test('OCR 常见误识纠正', () {
      expect(parseAmountToCents('1.2O'), 120);
      expect(parseAmountToCents('l234.00'), 123400);
    });

    test('不是金额的不能误判', () {
      expect(parseAmountToCents('姓名'), isNull);
      expect(parseAmountToCents('2026年10月'), isNull);
      expect(parseAmountToCents(''), isNull);
    });

    test('格式化', () {
      expect(formatCents(1234567), '¥12,345.67');
      expect(formatCents(-123400), '-¥1,234.00');
      expect(formatCents(0), '¥0.00');
      expect(centsToPlain(1234567), '12345.67');
    });
  });

  group('系数解析', () {
    test('正常系数', () {
      expect(parseCoefficient('1.20'), 1.2);
      expect(parseCoefficient('0.85'), 0.85);
    });

    test('离谱的数要被拒掉，交给人工', () {
      expect(parseCoefficient('120'), isNull);
      expect(parseCoefficient('0'), isNull);
    });
  });

  // 奖金条的字段结构和月度完全不同，这一组都是为了别再出现
  // "整张奖金条只认出个税" 那种情况。
  group('奖金条识别', () {
    test('「本月应发奖金」不能被当噪声丢掉', () {
      final parser = FieldParser([]);
      final img = parser.parseImage(
        index: 0,
        filePath: 'a.jpg',
        rawText: '',
        lines: [
          raw('本月应发奖金', 0, left: 0),
          raw('8000.00', 0, left: 200),
          raw('个人所得税', 1, left: 0),
          raw('800.00', 1, left: 200),
        ],
      );

      final gross = img.rows.firstWhere((e) => e.name.contains('应发奖金'));
      expect(gross.kind, ParsedRowKind.item);
      expect(gross.amountCents, 800000);

      final tax = img.rows.firstWhere((e) => e.name.contains('个税')
          || e.name.contains('所得税'));
      expect(tax.kind, ParsedRowKind.item);
    });

    test('「实发奖金」是净额，不是一笔收入', () {
      final parser = FieldParser([]);
      final img = parser.parseImage(
        index: 0,
        filePath: 'a.jpg',
        rawText: '',
        lines: [
          raw('实发奖金', 0, left: 0),
          raw('7200.00', 0, left: 200),
        ],
      );
      expect(img.rows.first.kind, ParsedRowKind.totalNet);
    });

    test('对不上任何合计的「奖金合计」会被兜回来当收入', () {
      final merged = MergeEngine([]).merge([
        image(0, [
          r('奖金合计', 800000, kind: ParsedRowKind.ambiguousTotal),
          r('个人所得税', 80000, kind: ParsedRowKind.item),
          r('实发奖金', 720000, kind: ParsedRowKind.totalNet),
        ]),
      ]);

      final income = merged.items.where((e) => e.isIncome).toList();
      expect(income.length, 1);
      expect(income.first.amountCents, 800000);
      // "奖金合计" 去掉"合计"再取名字，别把"合计"写进项目名
      expect(income.first.name, '奖金');
      expect(merged.grossCents, 800000);
      expect(merged.netCents, 720000);
      expect(
        merged.issues.any((e) => e.type == MergeIssueType.recovered),
        isTrue,
      );
    });

    // 真实截图（2025年终奖金，奔图）：同一个数印了三遍 + 铺满水印。
    // 曾经的 bug：水印规则把"重复出现"当成水印，25299 印三次就被整片删掉，
    // 于是整张纸只剩「个税」一项 —— 用户看到的就是"只识别出个税"。
    test('年终奖条：同一个数印三遍，不能被当成水印删掉', () {
      final templates = [
        ItemTemplate(
          name: '应发奖金合计',
          category: kCategoryIncome,
          aliases: ['本次应发奖金', '年终奖金'],
        ),
        ItemTemplate(name: '个人所得税', category: kCategoryDeduction, aliases: ['个税']),
      ];
      final parser = FieldParser(templates);

      final lines = <RawLine>[
        raw('2025年终奖金', 0, left: 4), // 顶部标题，和下面项目名一模一样
        raw('24540', 3, left: 120, h: 46), // 头图大号数字，是装饰不是明细
        raw('工号', 6, left: 4),
        raw('199438', 6, left: 200),
        raw('2025年终奖金', 7, left: 4),
        raw('25299', 7, left: 200),
        raw('应发奖金合计', 8, left: 4),
        raw('25299', 8, left: 200),
        raw('本次应发奖金', 9, left: 4),
        raw('25299', 9, left: 200),
        raw('个税', 10, left: 4),
        raw('759', 10, left: 210),
        raw('实发奖金', 11, left: 4),
        raw('24540', 11, left: 200),
        // 浅灰水印：斜着铺，位置每次都不一样，重复次数远多于真实金额
        raw('1279', 6, left: 118),
        raw('1279', 7, left: 330),
        raw('1279', 8, left: 60),
        raw('1279', 9, left: 250),
        raw('1279', 10, left: 150),
        raw('1279', 11, left: 320),
        raw('安心工资条', 6, left: 300),
        raw('安心工资条', 8, left: 300),
      ];

      final img = parser.parseImage(
        index: 0,
        filePath: 'a.jpg',
        rawText: '',
        lines: lines,
      );

      // 三行印的是同一笔钱，都识别到了，归一到模板里的同一个项目名
      final bonus = img.rows.where((e) => e.name == '应发奖金合计').toList();
      expect(bonus.length, 3);
      expect(bonus.every((e) => e.amountCents == 2529900), isTrue,
          reason: '金额不能被水印规则吞掉');

      final tax = img.rows.firstWhere((e) => e.name.contains('所得税'));
      expect(tax.kind, ParsedRowKind.item);
      expect(tax.amountCents, 75900);

      final net = img.rows.firstWhere((e) => e.name.contains('实发奖金'));
      expect(net.kind, ParsedRowKind.totalNet);
      expect(net.amountCents, 2454000);

      // 头图那个大号 24540 不能变成第二笔收入，水印编号也不能变成金额
      expect(img.rows.where((e) => e.amountCents == 2454000).length, 1);
      expect(img.rows.where((e) => e.amountCents == 127900).isEmpty, isTrue);
    });

    test('年终奖条合并后：收入只算一笔，实发能对上', () {
      final templates = [
        ItemTemplate(
          name: '应发奖金合计',
          category: kCategoryIncome,
          aliases: ['本次应发奖金', '年终奖金'],
        ),
        ItemTemplate(name: '个人所得税', category: kCategoryDeduction, aliases: ['个税']),
      ];
      final img = FieldParser(templates).parseImage(
        index: 0,
        filePath: 'a.jpg',
        rawText: '',
        lines: [
          raw('2025年终奖金', 0, left: 4),
          raw('2025年终奖金', 7, left: 4),
          raw('25299', 7, left: 200),
          raw('应发奖金合计', 8, left: 4),
          raw('25299', 8, left: 200),
          raw('本次应发奖金', 9, left: 4),
          raw('25299', 9, left: 200),
          raw('个税', 10, left: 4),
          raw('759', 10, left: 210),
          raw('实发奖金', 11, left: 4),
          raw('24540', 11, left: 200),
        ],
      );

      final merged = MergeEngine(templates).merge([img]);

      expect(merged.items.where((e) => e.isIncome).length, 1, reason: '不能算三遍');
      expect(merged.grossCents, 2529900);
      expect(merged.deductionTotalCents, 75900);
      expect(merged.netCents, 2454000);
      expect(
        merged.issues.any((e) => e.type == MergeIssueType.totalMismatch),
        isFalse,
        reason: '25299 - 759 = 24540，应该能对上',
      );
    });
  });
}

/// 造一个 OCR 文本片段（同一 top 的两个片段会被 LineBuilder 合成一行）
///
/// [h] 是字高：真实截图里「头图大号数字」的字高是正文的两三倍。
RawLine raw(String text, int row, {required double left, double h = 20}) => RawLine(
      text: text,
      left: left,
      right: left + 90,
      top: 10.0 + row * 30,
      bottom: 10.0 + row * 30 + h,
    );
