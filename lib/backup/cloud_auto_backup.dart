import '../core/app_settings.dart';
import '../data/db.dart';
import 'backup_service.dart';
import 'cloud_backup.dart';

/// 每月自动把全量加密备份传到云盘。
///
/// 为什么是「打开应用时补做」而不是真后台定时：
/// 真后台要引 workmanager、拉一个常驻通知、还得让用户去各家 ROM 里加白名单，
/// 对一个"一个月只用一两次"的工资条工具来说太重了。而用户每个月总会打开应用，
/// 那一刻补做一次就够，而且不耗电、不会被系统杀。
///
/// 触发点有两处（都走同一个 [_running] 互斥）：
/// - 首页挂载（冷启动、解锁后进首页）
/// - 从后台回到前台
class CloudAutoBackup {
  /// 同一时刻只允许跑一个上传，避免首页和 resume 同时触发传两遍
  static bool _running = false;

  /// 距离上次**失败**至少隔这么久才重试，避免连不上网盘时每次打开都卡一下。
  /// 原来是 6 小时 —— 一次超时后半天内都不再试，用户误以为备份坏了；
  /// 缩短到 15 分钟，慢网失败后下次打开能较快自愈，又不至于每次都卡。
  static const _retryGap = Duration(minutes: 15);

  /// 现在该不该备份
  static bool isDue(AppSettings s, DateTime now) {
    if (!s.cloudAutoBackup) return false;
    // 设的是每月 15 号、今天才 3 号 → 这个月还没到日子
    if (now.day < s.cloudAutoBackupDay) return false;
    // 本月已经成功备份过
    final last = s.cloudAutoBackupLastAt;
    if (last > 0) {
      final t = DateTime.fromMillisecondsSinceEpoch(last);
      if (t.year == now.year && t.month == now.month) return false;
    }
    // 刚失败过，等一会儿再试
    final tried = s.cloudAutoBackupLastTry;
    if (tried > 0 && now.difference(DateTime.fromMillisecondsSinceEpoch(tried)) < _retryGap) {
      return false;
    }
    return true;
  }

  /// 到了日子就备份一次。返回一句人话结果，不需要备份则返回 null。
  static Future<String?> runIfDue(AppSettings s) async {
    if (!isDue(s, DateTime.now())) return null;
    return runNow(s);
  }

  /// 不管到没到日子，立刻备份一次（"立即备份一次"按钮用）。
  ///
  /// 失败不弹窗、不打断用户 —— 结果记在设置里，云盘页能看到具体原因。
  static Future<String?> runNow(AppSettings s) async {
    if (_running) return null;

    final cfg = await WebDavConfig.load();
    if (cfg == null || !cfg.isValid) return null;
    final pass = await CloudBackupSecrets.loadCryptPassword();
    // 没有记住备份密码就没法加密上传：宁可不备份，也不能传一份明文的工资数据
    if (pass.length < 4) return null;

    _running = true;
    await s.markCloudAutoBackupTry();
    try {
      final db = await AppDb.instance;
      final bytes = await BackupService(db).buildBytes(encrypted: true, password: pass);
      await WebDavClient(cfg).upload(kCloudBackupName, bytes);
      await s.markCloudAutoBackupDone();
      return '已自动备份 ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB';
    } on BackupException catch (e) {
      await s.markCloudAutoBackupError(e.message);
      return null;
    } on WebDavException catch (e) {
      await s.markCloudAutoBackupError(e.message);
      return null;
    } catch (e) {
      await s.markCloudAutoBackupError('$e');
      return null;
    } finally {
      _running = false;
    }
  }
}
