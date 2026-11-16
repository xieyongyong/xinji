package com.xinji.payslip

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * 应用内更新的下载服务。
 *
 * ## 为什么要前台服务
 * 后台下载装进 APK 要几十秒到几分钟，普通 Service 会被系统随手杀掉；
 * 前台服务带一条常驻通知，系统不会杀，用户也能看见进度。
 * 下载线程和服务生命周期分离：用户切页面、锁屏、去别的页面继续操作工资数据，
 * 下载都不受影响。下载完只是弹一条通知，**不会自动跳到安装界面**打断手头的事。
 *
 * ## 安装为什么要 FileProvider
 * APK 放在应用私有目录，系统安装器没权限直接读。FileProvider 只把
 * update/ 这一个目录临时授权给它，比放开外部存储安全得多。
 */
class UpdateDownloadService : Service() {

    companion object {
        const val ACTION_START = "com.xinji.payslip.update.START"
        const val ACTION_CANCEL = "com.xinji.payslip.update.CANCEL"
        const val ACTION_INSTALL = "com.xinji.payslip.update.INSTALL"

        const val EXTRA_URL = "url"
        const val EXTRA_VERSION = "version"
        const val EXTRA_PATH = "path"

        private const val CHANNEL_ID = "xinji_update"
        private const val NOTIFY_ID = 2026
    }

    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "xinji-update") }

    @Volatile
    private var connection: HttpURLConnection? = null

    @Volatile
    private var cancelled = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val url = intent.getStringExtra(EXTRA_URL)
                val version = intent.getStringExtra(EXTRA_VERSION) ?: "新版本"
                if (url.isNullOrBlank()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (UpdateDownloadController.state.status == UpdateDownloadController.DOWNLOADING) {
                    // 已经在下了：重复点「立即更新」不能开第二个下载覆盖同一个文件
                    stopSelf()
                    return START_NOT_STICKY
                }
                cancelled = false
                startForeground(NOTIFY_ID, progressNotification(-1, version))
                executor.execute { download(url, version) }
            }

            ACTION_CANCEL -> {
                cancelled = true
                try {
                    connection?.disconnect()
                } catch (_: Throwable) {
                }
                UpdateDownloadController.publish(
                    UpdateDownloadController.State(status = UpdateDownloadController.CANCELLED)
                )
                stopForegroundCompat(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }

            ACTION_INSTALL -> {
                val path = intent.getStringExtra(EXTRA_PATH)
                if (!path.isNullOrBlank()) installApk(path)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 下载

    private fun download(url: String, version: String) {
        val dir = File(getExternalFilesDir(null) ?: filesDir, "update").apply { mkdirs() }
        val final = File(dir, "xinji-$version.apk")
        val partial = File(dir, "xinji-$version.apk.part")

        try {
            if (partial.exists()) partial.delete()
            val conn = URL(url).openConnection() as HttpURLConnection
            connection = conn
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", "xinji-android-updater")
            conn.instanceFollowRedirects = true
            conn.connect()

            val code = conn.responseCode
            if (code !in 200..299) throw IOException("下载失败：HTTP $code")
            val total = conn.contentLength.toLong().coerceAtLeast(0)
            var received = 0L
            var lastUi = 0L

            FileOutputStream(partial).use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        if (cancelled) throw InterruptedException("已取消")
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        received += n

                        val now = System.currentTimeMillis()
                        if (now - lastUi >= 250 || (total > 0 && received >= total)) {
                            lastUi = now
                            val pct = if (total > 0) (received * 100 / total).toInt().coerceIn(0, 99) else -1
                            publish(
                                UpdateDownloadController.DOWNLOADING,
                                pct, received, total, version, null, null
                            )
                            notifyProgress(pct, version)
                        }
                    }
                }
                out.flush()
            }

            // 下到几 KB 就"成功"基本是 GitHub 的错误页或被网关截了，别拿去安装
            if (partial.length() < 1024 * 1024) {
                throw IOException("下载到的文件太小，可能不是安装包")
            }
            if (final.exists() && !final.delete()) throw IOException("旧安装包删不掉")
            if (!partial.renameTo(final)) throw IOException("安装包保存失败")

            publish(
                UpdateDownloadController.DONE,
                100, final.length(), final.length(), version, final.absolutePath, null
            )
            // DETACH：通知栏留着让用户空闲时点安装，但服务本身可以退出
            startForeground(NOTIFY_ID, doneNotification(final, version))
            stopForegroundCompat(STOP_FOREGROUND_DETACH)
        } catch (t: Throwable) {
            if (!cancelled) {
                val msg = when {
                    t is IOException && t.message?.contains("HTTP", true) == true -> t.message!!
                    t.message?.contains("failed to connect", true) == true ->
                        "连不上下载服务器，换个网络再试（也可以在浏览器里下载）"
                    t.message?.contains("timeout", true) == true -> "下载超时，换个网络再试"
                    else -> t.message ?: t.toString()
                }
                publish(UpdateDownloadController.FAILED, 0, 0, 0, version, null, msg)
                startForeground(NOTIFY_ID, failedNotification(msg))
                stopForegroundCompat(STOP_FOREGROUND_DETACH)
            }
        } finally {
            connection = null
            stopSelf()
        }
    }

    private fun publish(
        status: String,
        progress: Int,
        received: Long,
        total: Long,
        version: String,
        path: String?,
        error: String?,
    ) {
        UpdateDownloadController.publish(
            UpdateDownloadController.State(status, progress, received, total, version, path, error)
        )
    }

    // ------------------------------------------------------------ 通知

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_LOW).apply {
                description = "后台下载新版本，点通知可以安装"
            }
        )
    }

    private fun openAppIntent(): PendingIntent {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            this, 0, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun progressNotification(pct: Int, version: String): android.app.Notification {
        ensureChannel()
        val cancel = PendingIntent.getService(
            this, 2,
            Intent(this, UpdateDownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("薪迹 正在下载 v$version")
            .setContentText(if (pct >= 0) "已完成 $pct%，可以继续用 App" else "正在连接…")
            .setContentIntent(openAppIntent())
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_delete, "取消", cancel)
        if (pct >= 0) b.setProgress(100, pct, false) else b.setProgress(100, 0, true)
        return b.build()
    }

    private fun notifyProgress(pct: Int, version: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.notify(NOTIFY_ID, progressNotification(pct, version))
        } catch (_: Throwable) {
            // 没通知权限（Android 13+ 用户没给）时前台服务照样跑，只是看不见进度
        }
    }

    private fun doneNotification(file: File, version: String): android.app.Notification {
        ensureChannel()
        val install = PendingIntent.getService(
            this, 3,
            Intent(this, UpdateDownloadService::class.java)
                .setAction(ACTION_INSTALL)
                .putExtra(EXTRA_PATH, file.absolutePath),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("薪迹 v$version 已下载完成")
            .setContentText("点这里安装，数据会原样保留")
            .setContentIntent(install)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
    }

    private fun failedNotification(msg: String): android.app.Notification {
        ensureChannel()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("薪迹 更新下载失败")
            .setContentText(msg.take(80))
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
    }

    private fun stopForegroundCompat(behavior: Int) {
        try {
            stopForeground(behavior)
        } catch (_: Throwable) {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
    }

    // ------------------------------------------------------------ 安装

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            publish(UpdateDownloadController.FAILED, 0, 0, 0, "", null, "安装包不见了，请重新下载")
            return
        }
        // Android 8+ 必须用户允许"安装未知应用"；系统设置页勾一下再回来点通知
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            try {
                val i = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
            } catch (t: Throwable) {
                publish(UpdateDownloadController.FAILED, 0, 0, 0, "", null, "打不开安装权限设置：$t")
            }
            return
        }
        try {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val i = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(i)
        } catch (t: Throwable) {
            publish(UpdateDownloadController.FAILED, 0, 0, 0, "", null, "调不起安装器：${t.message}")
        }
    }
}

/** 给 AppChannel 用：把下载请求交给服务，顺手申请 Android 13+ 通知权限 */
fun startUpdateDownload(context: Context, url: String, version: String) {
    val i = Intent(context, UpdateDownloadService::class.java)
        .setAction(UpdateDownloadService.ACTION_START)
        .putExtra(UpdateDownloadService.EXTRA_URL, url)
        .putExtra(UpdateDownloadService.EXTRA_VERSION, version)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(i)
    } else {
        context.startService(i)
    }
}
