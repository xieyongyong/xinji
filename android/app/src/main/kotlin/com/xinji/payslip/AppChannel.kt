package com.xinji.payslip

import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `xinji/app` 通道：App 自身的信息与"打开外部链接"。
 *
 * 只有两个方法，都是同步小结果：
 * - `version` : 当前安装包的 versionName（来自 pubspec 的 version 前半段）
 * - `openUrl` : 用系统浏览器打开链接（检查更新后去下载 APK）
 *
 * ## 为什么不用 package_info_plus / url_launcher
 * 这两个功能各只需要十几行原生代码，而多引一个插件就多一份
 * "升级 Flutter 版本后插件对不上"的风险 —— 这个项目已经在
 * google_mlkit 那种插件上吃过一次亏（插件把 native 拽进主进程，崩了没法兜）。
 * 能自己写的就自己写，版本号从 PackageManager 读，不走 BuildConfig
 * （AGP 8 默认关掉了 buildConfig 生成）。
 */
object AppChannel {
    const val NAME = "xinji/app"

    fun handle(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "version" -> result.success(versionName(context))

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
