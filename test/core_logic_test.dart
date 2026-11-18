import 'package:flutter_test/flutter_test.dart';
import 'package:xinji/core/money.dart';
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
  });
}

/// 造一个 OCR 文本片段（同一 top 的两个片段会被 LineBuilder 合成一行）
RawLine raw(String text, int row, {required double left}) => RawLine(
      text: text,
      left: left,
      right: left + 90,
      top: 10.0 + row * 30,
      bottom: 30.0 + row * 30,
    );
