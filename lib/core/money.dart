/// 金额工具。
///
/// 设计原则：**内部一律用「分」为单位的 int 存储与计算**，
/// 绝不用 double 存钱。原因是 0.1 + 0.2 != 0.3，
/// 而工资条要对"明细加总 == 合计"做校验，浮点误差会天天误报。
/// 只在显示和导出时才做格式化。
library;

/// 把一段文本解析成金额（单位：分）。解析不出来返回 null。
///
/// 能处理的现实情况：
/// - 千分位：`12,345.67`
/// - 货币符号：`¥12,345.67` / `￥12,345.67` / `12,345.67元`
/// - 负数两种写法：`-1,234.00` 和 `(1,234.00)`
/// - 全角符号：`１２３４．５６`
/// - OCR 常见误识：`1.2O`（字母 O 认成数字 0）、`l234`（字母 l 认成 1）
/// - 只有小数点后一位：`1234.5` 视为 1234.50
int? parseAmountToCents(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  // 1) 全角 -> 半角，去掉货币符号与单位
  s = s
      .replaceAll('．', '.')
      .replaceAll('，', ',')
      .replaceAll('－', '-')
      .replaceAll('—', '-')
      .replaceAll('￥', '')
      .replaceAll('¥', '')
      .replaceAll('元', '')
      .replaceAll(' ', '')
      .replaceAll('\u00A0', '');

  // 2) 负数：括号包裹 或 前置负号
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = true;
    s = s.substring(1);
  }

  if (s.isEmpty) return null;

  // 3) 只在"这段文本确实含数字"时，才做字母->数字纠正，
  //    避免把纯文字（如"奖金A"）中的字母硬转成数字而误判为金额。
  final hasDigit = RegExp(r'\d').hasMatch(s);
  if (hasDigit) {
    s = s
        .replaceAll(RegExp(r'[Oo]'), '0')
        .replaceAll(RegExp(r'[lI]'), '1')
        .replaceAll(RegExp(r'[Ss]'), '5'); // 仅当整串已是数字混排时生效
  }

  // 4) 去掉千分位逗号
  s = s.replaceAll(',', '');

  // 5) 严格校验：整数部分 + 最多两位小数
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(s)) return null;

  final parts = s.split('.');
  final yuan = int.tryParse(parts[0]);
  if (yuan == null) return null;

  var cent = 0;
  if (parts.length > 1) {
    // "5" -> "50"，"56" -> "56"
    cent = int.parse(parts[1].padRight(2, '0').substring(0, 2));
  }

  final total = yuan * 100 + cent;
  return negative ? -total : total;
}

/// 一个文本片段"像不像金额"。用于在视觉行里挑出金额列。
/// 比 parseAmountToCents 宽松一点：允许 1 位小数、允许带符号。
bool looksLikeAmount(String raw) {
  final v = parseAmountToCents(raw);
  if (v == null) return false;
  // 排除"2026"这类年份、"10"这类序号：工资条金额通常带小数点或有千分位。
  final t = raw.trim();
  if (RegExp(r'[.,]').hasMatch(t)) return true;
  // 整数金额也常见（如 5000），但和"序号"难区分，这里只看长度
  return t.replaceAll(RegExp(r'[^\d]'), '').length >= 3;
}

/// 界面上是否把金额打码（设置里的"金额打码"）。
///
/// 只影响**显示**：导出 CSV、备份、表单输入仍走 [formatCents]，
/// 否则打码一开，导出的备份就全是星号了。
bool kMaskAmounts = false;

/// 界面显示金额的统一入口。
String displayCents(int cents, {bool withSymbol = true, bool withSign = false}) {
  if (kMaskAmounts) return withSymbol ? '¥****' : '****';
  return formatCents(cents, withSymbol: withSymbol, withSign: withSign);
}

/// 分 -> 展示文本。`1234567` => `¥12,345.67`
String formatCents(int cents, {bool withSymbol = true, bool withSign = false}) {
  final negative = cents < 0;
  final abs = cents.abs();
  final yuan = abs ~/ 100;
  final frac = abs % 100;

  final buf = StringBuffer();
  final yuanStr = yuan.toString();
  // 从右往左每 3 位插一个逗号
  for (var i = 0; i < yuanStr.length; i++) {
    if (i > 0 && (yuanStr.length - i) % 3 == 0) buf.write(',');
    buf.write(yuanStr[i]);
  }

  final body = '$buf.${frac.toString().padLeft(2, '0')}';
  final sign = negative ? '-' : (withSign ? '+' : '');
  return '$sign${withSymbol ? '¥' : ''}$body';
}

/// 分 -> 不带符号不带千分位的纯数字，用于 CSV 导出（Excel 才能认成数字）
String centsToPlain(int cents) {
  final negative = cents < 0;
  final abs = cents.abs();
  final yuan = abs ~/ 100;
  final frac = abs % 100;
  final s = '$yuan.${frac.toString().padLeft(2, '0')}';
  return negative ? '-$s' : s;
}

/// 解析"绩效系数"这类小数（1.20 / 1.2）。允许 OCR 把小数点丢掉（120 -> 1.20 需人工确认）。
double? parseCoefficient(String raw) {
  var s = raw
      .trim()
      .replaceAll('．', '.')
      .replaceAll(' ', '')
      .replaceAll('%', '');
  if (s.isEmpty) return null;
  if (RegExp(r'\d').hasMatch(s)) {
    s = s.replaceAll(RegExp(r'[Oo]'), '0').replaceAll(RegExp(r'[lI]'), '1');
  }
  final v = double.tryParse(s);
  if (v == null) return null;
  // 系数合理区间：0 ~ 10。超出说明识别有误，交给人工。
  if (v <= 0 || v > 10) return null;
  return v;
}

/// 文本归一化用到的正则。提成顶层常量：模板匹配时按「行 × 模板 × 别名」
/// 放大调用，每次现建 RegExp 是白费的开销。
final class _NamePatterns {
  static final colonSpace = RegExp(r'[：:\s]');
  static final paren = RegExp(r'\(.*?\)');
  static final yearPrefix = RegExp(r'^20\d{2}年?');
}

/// 归一化结果缓存。项目名高度重复（同一份工资条几十行、跨月又是同一批名字），
/// 缓存后基本都是命中；上限防护避免极端情况下无限增长。
final Map<String, String> _normalizeCache = <String, String>{};
final Map<String, List<String>> _variantsCache = <String, List<String>>{};
const int _nameCacheMax = 2000;

/// 文本归一化：用于项目名比较（合并重复行、跨月对比对齐）
String normalizeName(String raw) {
  final cached = _normalizeCache[raw];
  if (cached != null) return cached;
  var s = raw.trim().toUpperCase();
  // 全角括号 -> 半角
  s = s.replaceAll('（', '(').replaceAll('）', ')');
  // 去掉常见噪声：末尾冒号、空白、括号内容里的编号、"金额"字样
  s = s.replaceAll(_NamePatterns.colonSpace, '');
  s = s.replaceAll(_NamePatterns.paren, '');
  s = s.replaceAll('金额', '');
  s = s.replaceAll('本月', '');
  if (_normalizeCache.length < _nameCacheMax) _normalizeCache[raw] = s;
  return s;
}

/// 字符多重集签名：把归一化后的字符排序拼成串，用来容忍 OCR 把项目名折行后
/// 拼错顺序（「数休息日加班时」与「休息日加班时数」的字符集合完全相同）。
/// 加 `sig:` 前缀避免和普通项目名撞车；只在匹配候选里用，不作存储键。
String nameSignature(String raw) {
  final n = normalizeName(raw);
  if (n.isEmpty) return '';
  final chars = n.split('')..sort();
  return 'sig:${chars.join()}';
}

/// 一个项目名的几种等价写法，用于匹配模板里的别名。
///
/// 「2025年终奖金」这串有两种读法：年份前缀「2025年」+「终奖金」，
/// 或者「2025」+「年终奖金」。奖金条的标题/项目名常常带年份，
/// 两种都得试 —— 只剥「20xx年」会把「年终奖金」的年一起吃掉，剩个「终奖金」，
/// 于是对不上模板，这笔钱就被当成另一个项目算两遍。
///
/// 注意：这只是**匹配用的候选**，不要拿它当存储键，否则同一个月会出现两行。
List<String> nameVariants(String raw) {
  final cached = _variantsCache[raw];
  if (cached != null) return cached;
  final n = normalizeName(raw);
  if (n.isEmpty) return const [];
  final out = <String>{n};
  final m = _NamePatterns.yearPrefix.firstMatch(n);
  if (m != null) {
    final rest = n.substring(m.end);
    if (rest.length >= 2) {
      out.add(rest);
      // 被当成"年份后缀"吃掉的这个「年」，可能是项目名自己的第一个字
      if (m.group(0)!.endsWith('年')) out.add('年$rest');
    }
  }
  // 字符多重集签名：容忍 OCR 折行后拼错顺序的乱序名（「数休息日加班时」）。
  // 注意签名只在双方都算时才对得上，模板侧见 TemplateItem._buildMatchTargets。
  final sig = nameSignature(n);
  if (sig.isNotEmpty) out.add(sig);
  final result = out.toList();
  if (_variantsCache.length < _nameCacheMax) _variantsCache[raw] = result;
  return result;
}
