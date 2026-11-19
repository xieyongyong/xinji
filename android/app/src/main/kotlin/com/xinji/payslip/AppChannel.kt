package com.xinji.payslip

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * `xinji/app` 通道：App 自身的信息、更新下载、以及"打开外部链接"这个退路。
 *
 * - `version`      : 当前安装包的 versionName（来自 pubspec 的 version 前半段）
 * - `download`     : 启动前台服务在后台下载 APK，立刻返回，不阻塞界面
 * - `cancelDownload` / `installApk` / `downloadStatus`
 * - `openUrl`      : 用系统浏览器打开链接（下载失败时让用户自己下）
 *
 * ## 为什么不用 package_info_plus / url_launcher / 下载插件
 * 这几个功能各只需要十几行原生代码，而多引一个插件就多一份
 * "升级 Flutter 版本后插件对不上"的风险 —— 这个项目已经在 google_mlkit
 * 那种插件上吃过一次亏。能自己写的就自己写。
 */
object AppChannel {
    const val NAME = "xinji/app"
    const val UPDATE_EVENTS = "xinji/update_progress"

    private const val REQ_NOTIFY = 7788

    fun handle(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "version" -> result.success(currentVersionName(context))

            "download" -> {
                val urls = call.argument<List<String>>("urls")
                    ?.map { it.trim() }?.filter { it.isNotEmpty() }
                val version = call.argument<String>("version") ?: "新版本"
                val sha256 = call.argument<String>("sha256")?.trim()?.ifBlank { null }
                if (urls.isNullOrEmpty()) {
                    result.error("app_bad_args", "缺少下载地址", null)
                    return
                }
                // Android 13+ 通知要运行时授权。这里只申请、不等结果：
                // 就算用户拒绝，前台服务依然能下载，只是通知栏不显示进度。
                if (Build.VERSION.SDK_INT >= 33 && context is Activity) {
                    if (ContextCompat.checkSelfPermission(
                            context, Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        try {
                            ActivityCompat.requestPermissions(
                                context,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_NOTIFY,
                            )
                        } catch (_: Throwable) {
                        }
                    }
                }
                startUpdateDownload(context.applicationContext, urls, version, sha256)
                result.success(true)
            }

            "cancelDownload" -> {
                val i = Intent(context, UpdateDownloadService::class.java)
                    .setAction(UpdateDownloadService.ACTION_CANCEL)
                try {
                    context.startService(i)
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("app_cancel_failed", t.message, null)
                }
            }

            "installApk" -> {
                val s = UpdateDownloadController.state
                val path = s.path
                if (s.status != UpdateDownloadController.DONE || path.isNullOrBlank()) {
                    result.error("app_not_ready", "还没有下载完成的安装包", null)
                    return
                }
                // 从前台 Activity 拉起透明入口，再由它调系统安装器。
                // 不能从 Service 直接 startActivity：Android 10+ 后台启动会被拦。
                try {
                    val i = Intent(context, InstallLauncherActivity::class.java)
                        .putExtra(UpdateDownloadService.EXTRA_PATH, path)
                    context.startActivity(i)
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("app_install_failed", t.message, null)
                }
            }

            "clearUpdateCache" -> {
                // 返回释放的字节数，界面上换算成 MB 显示
                result.success(UpdateCache.clearAll(context.applicationContext))
            }

            "saveToDownloads" -> {
                // 把 App 私有目录里生成好的备份文件复制到公共 Download。
                // 安卓 10+ 分区存储下 Dart 拿不到公共目录，必须走 MediaStore。
                val srcPath = call.argument<String>("srcPath")
                val displayName = call.argument<String>("displayName")
                if (srcPath.isNullOrBlank() || displayName.isNullOrBlank()) {
                    result.error("app_bad_args", "缺少源文件路径或文件名", null)
                    return
                }
                try {
                    val shown = saveToDownloads(context, srcPath, displayName)
                    result.success(shown)
                } catch (t: Throwable) {
                    result.error("app_save_failed", t.message ?: t.toString(), null)
                }
            }

            "downloadStatus" -> result.success(
                UpdateDownloadController.toMap(UpdateDownloadController.state)
            )

            "openUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("app_bad_args", "缺少 url", null)
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        // 调用方可能是 Application context，必须带 NEW_TASK
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(intent)
                    result.success(true)
                } catch (t: Throwable) {
                    // 没有浏览器 / 系统拦了跳转：把原因交回 Dart 去提示
                    result.error("app_open_failed", t.message ?: t.toString(), null)
                }
            }

            else -> result.notImplemented()
        }
    }

    /** versionName，例如 1.9.0；读不到时给 0.0.0，绝不抛异常 */
    fun currentVersionName(context: Context): String {
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            info.versionName ?: "0.0.0"
        } catch (_: Throwable) {
            "0.0.0"
        }
    }

    /**
     * 把私有目录里的备份文件复制到公共 Download，返回展示给用户看的路径。
     * minSdk 29，直接用 MediaStore.Downloads，不需要存储权限、不需要 SAF。
     */
    private fun saveToDownloads(context: Context, srcPath: String, displayName: String): String {
        val src = File(srcPath)
        if (!src.exists()) throw IllegalStateException("备份文件不存在")
        val mime = if (displayName.endsWith(".xbk", true)) {
            "application/octet-stream"
        } else {
            "application/zip"
        }
        val values = android.content.ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val resolver = context.contentResolver
        val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法在下载目录创建文件")
        try {
            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw IllegalStateException("无法打开输出流")
                FileInputStream(src).use { input -> input.copyTo(out) }
            }
        } catch (t: Throwable) {
            // 写入失败就删掉刚插入的空记录，别在 Download 里留垃圾
            try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
            throw t
        }
        return "Download/$displayName"
    }
}
