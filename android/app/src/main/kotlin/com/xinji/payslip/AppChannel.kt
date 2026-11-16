package com.xinji.payslip

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
            "version" -> result.success(versionName(context))

            "download" -> {
                val url = call.argument<String>("url")
                val version = call.argument<String>("version") ?: "新版本"
                if (url.isNullOrBlank()) {
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
                startUpdateDownload(context.applicationContext, url, version)
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
                val i = Intent(context, UpdateDownloadService::class.java)
                    .setAction(UpdateDownloadService.ACTION_INSTALL)
                    .putExtra(UpdateDownloadService.EXTRA_PATH, path)
                try {
                    context.startService(i)
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("app_install_failed", t.message, null)
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
    private fun versionName(context: Context): String {
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            info.versionName ?: "0.0.0"
        } catch (_: Throwable) {
            "0.0.0"
        }
    }
}
