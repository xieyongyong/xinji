import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

// 简单的可逆混淆：不是强加密，只是避免明文躺在 SharedPreferences 里被一眼看到。
// 真正的加密在 .xbk 本身（AES-256），这里保护的是网盘/备份密码。
String obfuscateText(String s) => base64.encode(
      utf8.encode(s).map((b) => (b ^ 0x5A) & 0xFF).toList(),
    );

String deobfuscateText(String s) => utf8.decode(
      base64.decode(s).map((b) => (b ^ 0x5A) & 0xFF).toList(),
    );

/// 云盘备份的「备份加密密码」。
///
/// 这个密码通常是网盘随机生成的，记不住也不该记 —— 存在本机、
/// 下次进页面自动带出即可（本机已经有应用锁保护）。
/// 换手机时仍然要用同一个密码才能解开云端的 .xbk。
class CloudBackupSecrets {
  static const _kCrypt = 'cloud_backup_crypt_obf';

  static Future<String> loadCryptPassword() async {
    final sp = await SharedPreferences.getInstance();
    final obf = sp.getString(_kCrypt) ?? '';
    if (obf.isEmpty) return '';
    try {
      return deobfuscateText(obf);
    } catch (_) {
      return '';
    }
  }

  static Future<void> saveCryptPassword(String password) async {
    final sp = await SharedPreferences.getInstance();
    if (password.isEmpty) {
      await sp.remove(_kCrypt);
      return;
    }
    await sp.setString(_kCrypt, obfuscateText(password));
  }

  static Future<void> clearCryptPassword() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kCrypt);
  }
}

/// 云盘备份提供方。当前只有 WebDAV 实现；接口留着以后接百度/坚果云 SDK。
abstract class CloudBackupProvider {
  Future<void> upload(String remoteName, List<int> bytes);
  Future<List<int>> download(String remoteName);
  Future<bool> exists(String remoteName);
  Future<void> delete(String remoteName);
}

/// WebDAV 配置（用户填的服务器/账号/密码）。密码只存本地，且做混淆，不明文落盘。
class WebDavConfig {
  static const _kUrl = 'webdav_url';
  static const _kUser = 'webdav_user';
  static const _kPass = 'webdav_pass_obf';

  final String url;
  final String user;
  final String password;

  const WebDavConfig({required this.url, required this.user, required this.password});

  bool get isValid => url.trim().isNotEmpty && user.trim().isNotEmpty && password.isNotEmpty;

  static Future<WebDavConfig?> load() async {
    final sp = await SharedPreferences.getInstance();
    final url = sp.getString(_kUrl) ?? '';
    final user = sp.getString(_kUser) ?? '';
    final obf = sp.getString(_kPass) ?? '';
    var pass = '';
    if (obf.isNotEmpty) {
      try {
        pass = deobfuscateText(obf);
      } catch (_) {
        pass = '';
      }
    }
    if (url.isEmpty) return null;
    return WebDavConfig(url: url, user: user, password: pass);
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, url.trim());
    await sp.setString(_kUser, user.trim());
    await sp.setString(_kPass, obfuscateText(password));
  }

  /// 只忘掉密码，保留服务器地址和账号（下次进页面仍是配好的状态）
  static Future<void> forgetPassword() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kPass);
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kUrl);
    await sp.remove(_kUser);
    await sp.remove(_kPass);
  }
}

class WebDavException implements Exception {
  final String message;
  WebDavException(this.message);
  @override
  String toString() => message;
}

/// 标准 WebDAV 客户端：MKCOL/PROPFIND/PUT/GET/DELETE，Basic Auth。
/// 坚果云 / 群晖 / Nextcloud 都吃这一套。
class WebDavClient implements CloudBackupProvider {
  final WebDavConfig config;
  WebDavClient(this.config) {
    if (!config.isValid) throw WebDavException('WebDAV 配置不完整');
  }

  String get _auth =>
      'Basic ${base64.encode(utf8.encode('${config.user}:${config.password}'))}';

  /// 把用户填的根地址和远程文件名拼成完整 URL，并规范化斜杠。
  Uri _uri(String remoteName) {
    var base = config.url.trim();
    while (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final name = remoteName.startsWith('/') ? remoteName.substring(1) : remoteName;
    return Uri.parse('$base/$name');
  }

  Future<void> _ensureRoot() async {
    final base = config.url.trim();
    final uri = Uri.parse(base.endsWith('/') ? base : '$base/');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl('MKCOL', uri).timeout(const Duration(seconds: 12));
      req.headers.set('Authorization', _auth);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain<void>();
      // 200/201=建好，405=已存在，都算成功
      if (resp.statusCode != 200 && resp.statusCode != 201 && resp.statusCode != 405) {
        throw WebDavException('WebDAV 目录不可写（HTTP ${resp.statusCode}）');
      }
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw WebDavException('连不上 WebDAV 服务器，检查地址和网络');
    } catch (e) {
      throw WebDavException('WebDAV 连接失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 全量上传：先 PUT 到 .tmp，成功后再 MOVE 覆盖正式文件（原子替换，
  /// 防止中途断网把云端旧备份覆盖成半截坏包）。
  @override
  Future<void> upload(String remoteName, List<int> bytes) async {
    await _ensureRoot();
    final tmp = Uri.parse('${_uri(remoteName)}.tmp');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final put = await client.openUrl('PUT', tmp).timeout(const Duration(seconds: 20));
      put.headers.set('Authorization', _auth);
      put.headers.set('Content-Type', 'application/octet-stream');
      put.contentLength = bytes.length;
      put.add(bytes);
      final putResp = await put.close().timeout(const Duration(seconds: 30));
      await putResp.drain<void>();
      if (putResp.statusCode != 200 && putResp.statusCode != 201 && putResp.statusCode != 204) {
        throw WebDavException('上传失败（HTTP ${putResp.statusCode}），账号或目录权限不对？');
      }

      // MOVE：Overwrite=T 覆盖正式文件
      final move = await client.openUrl('MOVE', tmp).timeout(const Duration(seconds: 20));
      move.headers.set('Authorization', _auth);
      move.headers.set('Destination', _uri(remoteName).toString());
      move.headers.set('Overwrite', 'T');
      final moveResp = await move.close().timeout(const Duration(seconds: 30));
      await moveResp.drain<void>();
      if (moveResp.statusCode != 200 && moveResp.statusCode != 201 && moveResp.statusCode != 204) {
        throw WebDavException('替换云端备份失败（HTTP ${moveResp.statusCode}）');
      }
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw WebDavException('连不上 WebDAV 服务器');
    } catch (e) {
      throw WebDavException('上传失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<int>> download(String remoteName) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(_uri(remoteName)).timeout(const Duration(seconds: 20));
      req.headers.set('Authorization', _auth);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode == 404) throw WebDavException('云端还没有备份');
      if (resp.statusCode != 200) throw WebDavException('下载失败（HTTP ${resp.statusCode}）');
      return await resp.expand((chunk) => chunk).toList();
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw WebDavException('连不上 WebDAV 服务器');
    } catch (e) {
      throw WebDavException('下载失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<bool> exists(String remoteName) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl('PROPFIND', _uri(remoteName)).timeout(const Duration(seconds: 12));
      req.headers.set('Authorization', _auth);
      req.headers.set('Depth', '0');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain<void>();
      return resp.statusCode == 207 || resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> delete(String remoteName) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl('DELETE', _uri(remoteName)).timeout(const Duration(seconds: 12));
      req.headers.set('Authorization', _auth);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain<void>();
      if (resp.statusCode != 200 && resp.statusCode != 204) {
        throw WebDavException('删除失败（HTTP ${resp.statusCode}）');
      }
    } on WebDavException {
      rethrow;
    } catch (e) {
      throw WebDavException('删除失败：$e');
    } finally {
      client.close(force: true);
    }
  }
}

/// 云端固定文件名：永远只留最新一份（PUT 同名覆盖 / MOVE 原子替换）。
const String kCloudBackupName = 'xinji_backup.xbk';
