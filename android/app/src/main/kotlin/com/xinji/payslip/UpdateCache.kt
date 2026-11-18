package com.xinji.payslip

import android.content.Context
import java.io.File

/**
 * 更新缓存清理。
 *
 * 下载的安装包放在应用私有目录 update/，文件名 xinji-<版本>.apk（未完成的是 .part）。
 * 以前只删同名旧包，不同版本会一直留着：连着升四次就是 4 个 92MB 的包，
 * 应用私有目录越滚越大，用户又看不到、没法手动清。
 *
 * 三处收口：
 * 1. [cleanOnStartup]  新版启动后调用：只留当前版本 apk；其它版本 apk/part 全删；
 *    当前版本没下完的 .part 保留一天（还能续传），超过一天才算残留清掉。
 * 2. [clearAll]        设置页「清理更新缓存」：整个目录清空，返回释放字节数。
 * 3. 正在下载的 .part 一律跳过，不能把断点续传的文件删了。
 */
object UpdateCache {
    private const val DIR = "update"
    private const val DAY_MS = 24L * 60 * 60 * 1000

    private fun dir(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, DIR).apply { mkdirs() }

    private fun apkName(version: String): String = "xinji-$version.apk"
    private fun partName(version: String): String = "xinji-$version.apk.part"

    /** 启动时清理，返回释放字节数。[currentVersion] 来自 PackageManager 的 versionName。 */
    fun cleanOnStartup(context: Context, currentVersion: String): Long {
        val downloading = UpdateDownloadController.state.status ==
            UpdateDownloadController.DOWNLOADING
        val keepApk = apkName(currentVersion)
        val keepPart = partName(currentVersion)
        return sweep(
            dir = dir(context),
            skipPart = downloading,
            keepApk = keepApk,
            keepPart = keepPart,
            partGraceMs = DAY_MS,
        )
    }

    /** 设置页一键清理。正在下载时保留当前 .part，其余全删。 */
    fun clearAll(context: Context): Long {
        val downloading = UpdateDownloadController.state.status ==
            UpdateDownloadController.DOWNLOADING
        return sweep(
            dir = dir(context),
            skipPart = downloading,
            keepApk = null,
            keepPart = if (downloading) partNameOfActive() else null,
            partGraceMs = if (downloading) DAY_MS else 0L,
        )
    }

    private fun partNameOfActive(): String? {
        val v = UpdateDownloadController.state.version
        return if (v.isBlank()) null else partName(v)
    }

    /**
     * @param keepApk 要保留的 apk 文件名；null = 全部删除
     * @param keepPart 要按宽限期保留的 .part 文件名；null = 按 grace 判断
     * @param skipPart 正在下载时跳过所有 .part
     * @param partGraceMs .part 保留时长（毫秒）；0 = 立即全删
     */
    private fun sweep(
        dir: File,
        skipPart: Boolean,
        keepApk: String?,
        keepPart: String?,
        partGraceMs: Long,
    ): Long {
        if (!dir.exists()) return 0L
        var freed = 0L
        val now = System.currentTimeMillis()
        for (f in dir.listFiles() ?: return 0L) {
            val name = f.name
            val isPart = name.endsWith(".part")
            if (isPart) {
                if (skipPart) continue
                if (name == keepPart && now - f.lastModified() < partGraceMs) continue
                if (keepPart == null && partGraceMs > 0 && now - f.lastModified() < partGraceMs) {
                    continue
                }
            } else {
                // 只碰我们自己的 apk，别把用户手动放进来的文件删了
                if (!name.startsWith("xinji-") || !name.endsWith(".apk")) continue
                if (name == keepApk) continue
            }
            val len = if (f.isFile) f.length() else 0L
            if (f.delete()) freed += len
        }
        return freed
    }
}
