package com.xinji.payslip

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
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

        const val EXTRA_URLS = "urls"
        const val EXTRA_VERSION = "version"
        const val EXTRA_SHA256 = "sha256"
        const val EXTRA_PATH = "path"

        // 换 id：老用户已建的 xinji_update 渠道是 LOW，系统不允许改 importance，
        // 用新 id 才能让"下载完成"通知正常弹出来。
        private const val CHANNEL_ID = "xinji_update_v2"
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
                val urls = intent.getStringArrayExtra(EXTRA_URLS)?.toList()
                    ?.map { it.trim() }?.filter { it.isNotEmpty() }
                val version = intent.getStringExtra(EXTRA_VERSION) ?: "新版本"
                val sha256 = intent.getStringExtra(EXTRA_SHA256)?.trim()?.ifBlank { null }
                if (urls.isNullOrEmpty()) {
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
                // 依次尝试每条线路：某条失败（且不是用户取消）就换下一条。
                // 校验值对全部线路一致 —— .download 内容是同一个 APK。
                executor.execute {
                    try {
                        download(urls, version, sha256)
                    } finally {
                        // download 全部线路走完（成功/失败/取消）后结束服务。
                        // 通知已经 DETACH，退出服务不会把"点此安装"通知带走。
                        stopSelf()
                    }
                }
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
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 下载

    /**
     * 按线路顺序下载。任何一条失败（且不是用户取消）就换下一条；
     * 全部失败才报错。下载完成后可选做 SHA-256 校验，防止拿到错误页/截断包。
     */
    private fun download(urls: List<String>, version: String, expectedSha: String?) {
        val dir = File(getExternalFilesDir(null) ?: filesDir, "update").apply { mkdirs() }
        val final = File(dir, "xinji-$version.apk")
        val partial = File(dir, "xinji-$version.apk.part")
        var lastError = "下载失败"

        for ((idx, url) in urls.withIndex()) {
            if (cancelled) return
            try {
                // 换线路时删掉上一条的残留，从头下 —— 不同线路的响应长度可能不同，
                // 拿 A 线路的半截去续 B 线路会拼出坏包。同一条线路内才续传。
                if (idx > 0 && partial.exists() && !partial.delete()) {
                    // 删不掉就跳过这条，别硬拼
                    continue
                }
                if (idx > 0) {
                    publish(UpdateDownloadController.DOWNLOADING, -1, 0, 0, version, null, null)
                    startForeground(NOTIFY_ID, progressNotification(-1, version))
                }
                downloadOne(url, version, partial)

                // 下到几 KB 就"成功"基本是错误页或被网关截了，别拿去安装
                if (partial.length() < 1024 * 1024) {
                    throw IOException("下载到的文件太小，可能不是安装包")
                }
                // 校验值由 CI 随包发布，命中就能挡住"线路返回了别的页面/半截文件"
                if (expectedSha != null && !sha256Matches(partial, expectedSha)) {
                    try { partial.delete() } catch (_: Throwable) {}
                    throw IOException("校验不通过，这个线路给的文件不完整")
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
                return
            } catch (t: Throwable) {
                if (cancelled) return
                lastError = friendlyError(t)
                val msg = t.message.orEmpty()
                // 内容损坏类的失败必须删掉 .part，否则下次续传接着拼坏文件
                if (msg.contains("太小") || msg.contains("不一致") || msg.contains("校验")) {
                    try { partial.delete() } catch (_: Throwable) {}
                }
            }
        }

        // 所有线路都失败
        val shown = if (urls.size > 1) "$lastError（已尝试 ${urls.size} 条线路）" else lastError
        publish(UpdateDownloadController.FAILED, 0, 0, 0, version, null, shown)
        startForeground(NOTIFY_ID, failedNotification(shown))
        stopForegroundCompat(STOP_FOREGROUND_DETACH)
    }

    /** 单条线路的实际下载（含断点续传）。失败抛异常由 [download] 决定换线路。 */
    private fun downloadOne(url: String, version: String, partial: File) {
        val already = if (partial.exists()) partial.length() else 0L
        val conn = URL(url).openConnection() as HttpURLConnection
        connection = conn
        try {
            conn.connectTimeout = 20_000
            // 慢速网络下 120s 没有新数据才判超时；期间有字节进来会重置计时
            conn.readTimeout = 120_000
            conn.setRequestProperty("User-Agent", "xinji-android-updater")
            conn.instanceFollowRedirects = true
            if (already > 0) conn.setRequestProperty("Range", "bytes=$already-")
            conn.connect()

            val code = conn.responseCode
            if (code !in 200..299) throw IOException("下载失败：HTTP $code")
            // 206 = 服务端接受 Range，接着写；200 = 不支持 Range，从头写
            val resume = already > 0 && code == HttpURLConnection.HTTP_PARTIAL
            var received = if (resume) already else 0L
            // 206 时 contentLength 是"剩余字节"，加上已下的才是总大小
            val contentLen = conn.contentLength.toLong().coerceAtLeast(0)
            val total = if (resume && contentLen > 0) already + contentLen else contentLen
            if (!resume && partial.exists() && !partial.delete()) {
                throw IOException("旧的不完整文件删不掉")
            }

            FileOutputStream(partial, resume).use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    var lastUi = 0L
                    var lastSpeedAt = System.currentTimeMillis()
                    var bytesSinceSpeed = 0L
                    while (true) {
                        if (cancelled) throw InterruptedException("已取消")
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        received += n
                        bytesSinceSpeed += n

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
                        if (now - lastSpeedAt >= 10_000) {
                            if (bytesSinceSpeed <= 0) throw IOException("下载停滞，换个线路再试")
                            lastSpeedAt = now
                            bytesSinceSpeed = 0L
                        }
                    }
                }
                out.flush()
            }
            // 服务端给了总大小时核一遍，防止续传拼出损坏的 APK
            if (total > 0 && partial.length() != total) {
                throw IOException("文件大小与服务器不一致，已删除重下")
            }
        } finally {
            connection = null
        }
    }

    /** 流式算 SHA-256，对大写/小写、前后空白都宽容 */
    private fun sha256Matches(file: File, expected: String): Boolean {
        val want = expected.trim().lowercase()
        if (want.length != 64) return false
        val md = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) } == want
    }

    private fun friendlyError(t: Throwable): String {
        val msg = t.message.orEmpty()
        return when {
            t is IOException && msg.contains("HTTP", true) -> msg
            msg.contains("failed to connect", true) -> "连不上下载服务器"
            msg.contains("timeout", true) || msg.contains("停滞", true) -> "下载超时"
            msg.contains("校验", true) || msg.contains("太小") || msg.contains("不一致") -> msg
            else -> msg.ifBlank { t.toString() }.take(60)
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
            NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "后台下载新版本，完成后点通知安装"
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
        // 用 getActivity 拉起透明入口 Activity，由前台 Activity 去调系统安装器。
        // 原来用 getService：后台服务再 startActivity 会被 Android 10+ 拦掉，
        // 通知点了没反应；而且 autoCancel 把通知消了，用户以为功能坏了。
        val install = PendingIntent.getActivity(
            this, 3,
            Intent(this, InstallLauncherActivity::class.java)
                .putExtra(EXTRA_PATH, file.absolutePath)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("薪迹 v$version 已下载完成")
            .setContentText("点这里安装，数据会原样保留")
            .setContentIntent(install)
            .setAutoCancel(false)
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
}

/** 给 AppChannel 用：把下载请求交给服务，顺手申请 Android 13+ 通知权限 */
fun startUpdateDownload(
    context: Context,
    urls: List<String>,
    version: String,
    sha256: String?,
) {
    val i = Intent(context, UpdateDownloadService::class.java)
        .setAction(UpdateDownloadService.ACTION_START)
        .putExtra(UpdateDownloadService.EXTRA_URLS, urls.toTypedArray())
        .putExtra(UpdateDownloadService.EXTRA_VERSION, version)
        .putExtra(UpdateDownloadService.EXTRA_SHA256, sha256)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(i)
    } else {
        context.startService(i)
    }
}
