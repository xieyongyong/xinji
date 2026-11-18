package com.xinji.payslip

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * 下载完成通知的点击入口 —— 一个"看不见的"前台 Activity。
 *
 * ## 为什么不能直接从通知启动 Service 去安装
 * 原来通知的 contentIntent 是 PendingIntent.getService(...ACTION_INSTALL)，
 * 然后在 Service 里 startActivity() 调系统安装器。Android 8+ 不允许后台启动
 * Service（PendingIntent 会被系统直接丢弃），Android 10+ 又不允许后台 Activity
 * 启动 —— 于是"应用不在前台时点通知"两条路都堵死，点了没反应，通知还因为
 * autoCancel 消失了，看起来就像坏了。
 *
 * ## 为什么这样能行
 * 点通知 = 用户主动操作，PendingIntent.getActivity 拉起本 Activity 是合法的
 * （通知点击属于用户发起）。Activity 在前台，再由它调系统安装器就顺理成章。
 * 这个 Activity 用透明主题、onCreate 里立刻 finish，用户只会看到安装界面弹出来。
 */
class InstallLauncherActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val path = intent?.getStringExtra(UpdateDownloadService.EXTRA_PATH)
        val file = if (path.isNullOrBlank()) null else File(path)
        if (file == null || !file.exists()) {
            Toast.makeText(this, "安装包不见了，请重新下载", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        // Android 8+ 要用户允许"安装未知应用"，否则系统安装器会拒绝
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            // 从前台 Activity 跳系统设置页，是合法的；用户勾完回来再点通知即可
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Throwable) {
                Toast.makeText(this, "打不开安装权限设置，请手动允许安装未知应用", Toast.LENGTH_SHORT).show()
            }
            finish()
            return
        }

        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val i = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
        } catch (t: Throwable) {
            Toast.makeText(this, "调不起安装器：${t.message}", Toast.LENGTH_SHORT).show()
        }
        finish()
    }
}
