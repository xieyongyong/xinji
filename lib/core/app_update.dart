import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 在线检查更新。
///
/// ## 为什么是 GitHub Releases
/// 安装包本来就由 CI 发到 Release 上（`v1.9.0` 永久保留 + `latest` 门牌），
/// 版本信息现成的，不用再额外维护一个"版本清单"文件。
///
/// ## 但仓库必须是公开的
/// GitHub 的 API 对私有仓库要求带 token，而把 token 打进 APK 等于没有保密
/// （谁都能反编译出来），所以这条路在私有仓库上行不通。
/// 仓库改成 Public 之后：不登录、不鉴权，直接读
/// `api.github.com/repos/<owner>/<repo>/releases` 就能拿到版本号。
///
/// 万一哪天又改回私有，这里会收到 404，界面上会明说
/// 「仓库不可访问」，而不是含糊地报"检查失败"。
class UpdateChecker {
  /// 代码仓库（改仓库名只改这一处）
  static const String repo = 'xieyongyong/xinji';

  static const String _apiBase = 'https://api.github.com/repos/$repo';
  static const String _channelName = 'xinji/app';

  /// 自动检查的间隔：一天一次。手动点「检查更新」不受这个限制
  static const Duration autoInterval = Duration(hours: 12);

  static const String _kLastCheck = 'update_last_check';
  static const String _kSkipVersion = 'update_skip_version';

  static const MethodChannel _channel = MethodChannel(_channelName);

  /// 当前安装包的版本号（如 `1.9.0`）
  static Future<String> currentVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('version');
      if (v != null && v.trim().isNotEmpty) return v.trim();
    } catch (_) {
      // 通道不可用（非 Android / 老安装包）时给个兜底，界面显示不致命
    }
    return '0.0.0';
  }

  /// 用系统浏览器打开链接（下载 APK）
  static Future<void> openUrl(String url) =>
      _channel.invokeMethod<bool>('openUrl', {'url': url});

  /// 拉一次最新版本。`null` 表示远端没有任何 `vX.Y.Z` 形式的 Release。
  ///
  /// 失败抛 [UpdateException]（message 可直接展示给用户）。
  static Future<ReleaseInfo?> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse('$_apiBase/releases?per_page=30');
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
      // GitHub 要求带 UA，不带会被直接 403
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'xinji-android-updater');
      final resp = await req.close().timeout(const Duration(seconds: 15));

      if (resp.statusCode == 404) {
        throw UpdateException(
          '仓库不可访问（404）。如果代码仓库还是 Private，'
          'GitHub 不允许匿名读取版本信息，需要把它改成 Public。',
        );
      }
      if (resp.statusCode == 403) {
        throw UpdateException('GitHub 暂时限制了访问（403），过一会儿再试。');
      }
      if (resp.statusCode != 200) {
        throw UpdateException('GitHub 返回 HTTP ${resp.statusCode}');
      }

      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw UpdateException('版本信息格式不对');
      }

      ReleaseInfo? best;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        if (raw['draft'] == true) continue;
        final tag = (raw['tag_name'] ?? '').toString().trim();
        // 只认 v1.2.3 这种正式版本号：
        // CI 每次构建还会推一个 tag=latest 的"门牌"Release，它不是版本，跳过
        final m = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$').firstMatch(tag);
        if (m == null) continue;
        final version = '${m.group(1)}.${m.group(2)}.${m.group(3)}';
        final candidate = ReleaseInfo(
          version: version,
          tag: tag,
          notes: (raw['body'] ?? '').toString().trim(),
          pageUrl: (raw['html_url'] ?? 'https://github.com/$repo/releases').toString(),
          apkUrl: _apkUrlOf(raw, version),
          publishedAt: (raw['published_at'] ?? '').toString(),
        );
        if (best == null || compareVersions(version, best.version) > 0) {
          best = candidate;
        }
      }
      return best;
    } on UpdateException {
      rethrow;
    } on SocketException {
      throw UpdateException('连不上 GitHub（网络不通，或需要代理）。');
    } on HttpException {
      throw UpdateException('网络请求失败，换个网络再试。');
    } on FormatException {
      throw UpdateException('GitHub 返回的内容不是预期的格式。');
    } catch (e) {
      throw UpdateException('检查更新失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// Release 里那个 `xinji.apk` 的直链；找不到就用约定好的固定路径
  static String _apkUrlOf(Map raw, String version) {
    final assets = raw['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString().toLowerCase();
        final url = (a['browser_download_url'] ?? '').toString();
        if (name.endsWith('.apk') && url.isNotEmpty) return url;
      }
    }
    return 'https://github.com/$repo/releases/download/v$version/xinji.apk';
  }

  /// 比较两个 `x.y.z` 版本号：a > b 返回正数，相等 0，小于负数
  static int compareVersions(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    for (var i = 0; i < 3; i++) {
      final d = pa[i] - pb[i];
      if (d != 0) return d;
    }
    return 0;
  }

  static List<int> _parts(String v) {
    final out = [0, 0, 0];
    final bits = v.split('.');
    for (var i = 0; i < 3; i++) {
      if (i < bits.length) {
        out[i] = int.tryParse(bits[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      }
    }
    return out;
  }

  /// 启动时的静默检查：关掉弹窗就安静失败，绝不因为网络问题打扰用户。
  ///
  /// 返回"有新版本"的 [ReleaseInfo]（调用方负责弹窗），否则 null。
  static Future<ReleaseInfo?> autoCheck() async {
    final sp = await SharedPreferences.getInstance();
    final last = sp.getInt(_kLastCheck) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < autoInterval.inMilliseconds) return null;
    // 先记时间再请求：失败了也不要每次冷启动都去撞一遍网络
    await sp.setInt(_kLastCheck, now);

    ReleaseInfo? latest;
    try {
      latest = await fetchLatest();
    } catch (_) {
      return null;
    }
    if (latest == null) return null;
    final found = latest;

    final current = await currentVersion();
    // 读不到本机版本（通道异常）就别猜：宁可这次不提示，也不能让用户
    // 每次开 App 都看到一个"发现新版本"，点下载又装不上
    if (current == '0.0.0') return null;
    if (compareVersions(found.version, current) <= 0) return null;
    // 用户对这个版本点过「以后再说」，就别再弹了
    if (sp.getString(_kSkipVersion) == found.version) return null;
    return found;
  }

  /// 记住"这个版本先不更新"
  static Future<void> skipVersion(String version) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kSkipVersion, version);
  }

  /// 手动检查后记一笔，避免紧接着冷启动又自动请求一次
  static Future<void> markChecked() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLastCheck, DateTime.now().millisecondsSinceEpoch);
  }
}

/// 远端某个版本的信息
class ReleaseInfo {
  final String version;
  final String tag;
  final String notes;
  final String pageUrl;
  final String apkUrl;
  final String publishedAt;

  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.apkUrl,
    required this.publishedAt,
  });

  /// 发布日期（只取 yyyy-MM-dd）
  String get dateLabel {
    if (publishedAt.length >= 10) return publishedAt.substring(0, 10);
    return publishedAt;
  }
}

class UpdateException implements Exception {
  final String message;
  UpdateException(this.message);
  @override
  String toString() => message;
}
