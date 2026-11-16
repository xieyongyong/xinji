package com.xinji.payslip

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 记录「上一次进程是怎么死的」。
 *
 * 这是排查闪退最硬的证据：native 崩溃时 Dart 层拿不到任何东西，
 * 但系统自己记着账（Android 11 / API 30 起开放给应用查）。
 *
 * 典型读法：
 * - `原因=CRASH_NATIVE 信号=11` → native 段错误（库不兼容 / 对齐问题）
 * - `原因=LOW_MEMORY`          → 内存不够被系统杀
 * - `原因=SIGNALED 信号=9`      → 被 kill（多半是内存）
 * - `进程=com.xinji.payslip:ocr` → 崩的是识别进程，主 App 没受影响
 *
 * 采集时机：主进程启动时顺手抓一次，结果写到 files/last_exit.txt，
 * 设置页的「诊断日志」会把它一起显示出来。
 */
object ExitReasons {

    // ApplicationExitInfo 整个类是 API 30 才有的，下面用 SDK_INT 做了运行时兜底，
    // 这里的 @Suppress 只是为了不让静态检查把构建卡在"新 API"告警上。
    @Suppress("NewApi")
    fun capture(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
            val list = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 4)
            if (list.isNullOrEmpty()) return

            val fmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)
            val sb = StringBuilder()
            sb.append("采集于 ").append(fmt.format(Date())).append('\n')
            for ((i, info) in list.withIndex()) {
                sb.append("#").append(i + 1)
                    .append(" 进程=").append(info.processName ?: "?")
                    .append(" 原因=").append(reasonName(info.reason))
                if (info.reason == ApplicationExitInfo.REASON_SIGNALED ||
                    info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE
                ) {
                    sb.append(" 信号=").append(info.status)
                }
                sb.append(" 时间=").append(fmt.format(Date(info.timestamp)))
                val desc = info.description
                if (!desc.isNullOrBlank()) sb.append(" 描述=").append(desc)
                sb.append('\n')
            }
            File(ctx.filesDir, "last_exit.txt").writeText(sb.toString())
        } catch (_: Throwable) {
            // 查不到就算了，绝不影响启动
        }
    }

    @Suppress("NewApi")
    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INIT_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        // 14/15/16（FREEZER / PACKAGE_STATE_CHANGE / PACKAGE_UPDATED）是 API 31 才有的
        // 常量，这里不直接引用，落到下面的兜底分支显示数字，避免新 API 告警
        else -> "UNKNOWN($reason)"
    }
}
