package com.xinji.payslip

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface
import android.os.Build
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * 长截图安全处理。
 *
 * ## 为什么必须在原生侧做
 * 一张 1080×12000 的工资条长截图，解码成位图就是 1080×12000×4 ≈ 50MB。
 * 再加编码缓冲、缩放副本，峰值轻松过 150MB —— 中低端机会被系统直接 kill。
 * 这种情况下 Dart 层连异常都来不及抛，用户看到的就是"选完图片瞬间闪退"，
 * 日志里什么都没有。
 *
 * 所以这里用 [BitmapRegionDecoder] 按块解码：只把当前这一块读进内存
 * （1080×1600 ≈ 7MB），识别完回收再读下一块。峰值内存从"整张"降到"一块"。
 *
 * 顺带处理两件 Dart 侧做起来很别扭的事：
 * - EXIF 旋转（照片拍的纸质工资条），Dart 的 decodeImage 不管这个，
 *   会把图当没转过，OCR 全歪
 * - 归档压缩，同样不能整图读进 Dart 堆
 */
object SlipImaging {

    /** 单块像素上限：超过就继续降采样，防止一张横向巨图把一块也撑爆 */
    private const val MAX_TILE_PIXELS = 20_000_000L

    // ------------------------------------------------------------ probe

    /** 只读尺寸，不解码像素（inJustDecodeBounds） */
    fun probe(path: String): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val sw = bounds.outWidth
        val sh = bounds.outHeight
        if (sw <= 0 || sh <= 0) throw IllegalStateException("无法读取图片尺寸，可能不是有效图片")
        val rot = readRotation(path)
        val turned = rot == 90 || rot == 270
        return mapOf(
            "width" to (if (turned) sh else sw),
            "height" to (if (turned) sw else sh),
            "storedWidth" to sw,
            "storedHeight" to sh,
            "rotation" to rot
        )
    }

    // ------------------------------------------------------------ tiles

    /**
     * 把图竖直切成若干块 JPEG 落到 [outDir]，返回每块的路径与顶部偏移。
     *
     * 返回的 `top` 已经是**识别图坐标系**（即缩放到 maxWidth 之后）的偏移，
     * Dart 侧直接用 `line.top + top` 就能拼回整图，不用再换算比例。
     */
    fun tiles(
        path: String,
        tileHeight: Int,
        overlap: Int,
        maxWidth: Int,
        quality: Int,
        outDir: String,
        tag: String,
        clean: Boolean = true
    ): List<Map<String, Any>> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val sw = bounds.outWidth
        val sh = bounds.outHeight
        if (sw <= 0 || sh <= 0) throw IllegalStateException("无法读取图片尺寸")

        val rot = readRotation(path)
        val turned = rot == 90 || rot == 270
        // logical = 转正之后的"正常方向"尺寸
        val logicalW = if (turned) sh else sw
        val logicalH = if (turned) sw else sh

        val sample = pickSample(logicalW, logicalH, maxWidth)

        val dir = File(outDir)
        if (!dir.exists()) dir.mkdirs()

        @Suppress("DEPRECATION")
        val decoder = BitmapRegionDecoder.newInstance(path, false)
            ?: throw IllegalStateException("系统无法分块解析这张图（格式不支持）")

        val out = ArrayList<Map<String, Any>>()
        var start = 0
        var index = 0
        var scale = 1.0
        while (start < logicalH) {
            val end = minOf(start + tileHeight, logicalH)
            val len = end - start
            if (len <= 8) break // 末尾残条，没意义

            val rect = if (turned) {
                Rect(start, 0, end, sh)
            } else {
                Rect(0, start, sw, end)
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            var bmp = decoder.decodeRegion(rect, opts)
                ?: throw IllegalStateException("分块解码失败（第 ${index + 1} 块）")

            if (rot != 0) bmp = rotate(bmp, rot)

            // 降采样是 2 的幂，最后再精确缩到 maxWidth
            if (bmp.width > maxWidth) {
                val nh = maxOf(1, (bmp.height.toFloat() * maxWidth / bmp.width).toInt())
                val scaled = Bitmap.createScaledBitmap(bmp, maxWidth, nh, true)
                if (scaled !== bmp) {
                    bmp.recycle()
                    bmp = scaled
                }
            }

            if (index == 0) scale = bmp.width.toDouble() / logicalW.toDouble()

            // 去掉浅灰水印：只影响「送给 OCR 的分块」，归档图（compress）保持原样，
            // 用户想回看原始截图时水印还在，不会被我们改掉。
            // 设置里可以关掉：极少数情况下它会把很浅的小字也一起刷白。
            val cleanSummary: String
            if (clean) {
                val cleaned = TileCleaner.clean(bmp)
                if (cleaned.bitmap !== bmp) {
                    bmp.recycle()
                    bmp = cleaned.bitmap
                }
                cleanSummary = cleaned.summary
            } else {
                cleanSummary = "已关闭"
            }

            // 用 **PNG 无损** 送识别，而不是 JPEG。
            // 分块是要交给 OCR 的：JPEG 的块效应会让笔画粘连、小数点糊成逗号，
            // 而这些都是临时文件（识别完立刻删），多占的几百 KB 完全值得。
            val file = File(dir, "${tag}_$index.png")
            FileOutputStream(file).use { fos ->
                bmp.compress(Bitmap.CompressFormat.PNG, 100, fos)
                fos.flush()
            }

            out.add(
                mapOf(
                    "path" to file.absolutePath,
                    // 偏移换到识别图坐标系，保证和识别结果的 y 同尺度
                    "top" to (start * scale).toInt(),
                    "width" to bmp.width,
                    "height" to bmp.height,
                    // 去水印的结果摘要，写进 ocr_trace.log 便于按日志调阈值
                    "clean" to cleanSummary
                )
            )

            bmp.recycle()

            if (end >= logicalH) break
            start = end - overlap
            index++
            if (index > 400) break // 防御：异常图别死循环
        }

        // 注意：这里**不能**写 decoder.recycle()。
        // BitmapRegionDecoder.recycle() 是 API 31 才加的，在 Android 8~11 上调用
        // 会抛 NoSuchMethodError —— 那就又变成一个新的闪退源了。
        // 解码器句柄本身很小（不含像素数据），交给 GC 即可。
        if (out.isEmpty()) throw IllegalStateException("图片分块结果为空")
        return out
    }

    // ------------------------------------------------------------ compress

    /**
     * 归档压缩：给详情页查看用，同时控制磁盘占用。
     *
     * 注意别把 [maxPixels] 设小：这张图之后会被 Flutter 的 Image 组件拿去显示，
     * 仍然是整图解码，压得太狠字就糊了（长截图尤其明显）。
     * 这里优先保**宽度**，像素上限只用于拦极端大图。
     */
    fun compress(
        src: String,
        dest: String,
        maxWidth: Int,
        maxPixels: Long,
        quality: Int
    ): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(src, bounds)
        val sw = bounds.outWidth
        val sh = bounds.outHeight
        if (sw <= 0 || sh <= 0) throw IllegalStateException("无法读取图片尺寸")

        var sample = 1
        // 先按宽度定：宽度不超过 maxWidth*2 就不再降采样。
        // 这一条是保清晰度的关键 —— 长截图高度很大，如果按"总像素"降采样，
        // 宽度会被压到 500 多，工资条上的数字直接糊掉，归档后放大也看不清。
        while (sw / sample > maxWidth * 2 && sample < 16) sample *= 2
        // 再按总像素兜底，只用于防极端大图把内存撑爆
        while (sample < 16 &&
            (sw / sample).toLong() * (sh / sample).toLong() > maxPixels
        ) {
            sample *= 2
        }

        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        var bmp = BitmapFactory.decodeFile(src, opts)
            ?: throw IllegalStateException("图片解码失败")

        val rot = readRotation(src)
        if (rot != 0) bmp = rotate(bmp, rot)

        if (bmp.width > maxWidth) {
            val nh = maxOf(1, (bmp.height.toFloat() * maxWidth / bmp.width).toInt())
            val scaled = Bitmap.createScaledBitmap(bmp, maxWidth, nh, true)
            if (scaled !== bmp) {
                bmp.recycle()
                bmp = scaled
            }
        }
        // 再兜一道像素上限（宽度合规但极高的长图）
        val pixels = bmp.width.toLong() * bmp.height.toLong()
        if (pixels > maxPixels) {
            val s = Math.sqrt(maxPixels.toDouble() / pixels.toDouble())
            val nw = maxOf(1, (bmp.width * s).toInt())
            val nh = maxOf(1, (bmp.height * s).toInt())
            val scaled = Bitmap.createScaledBitmap(bmp, nw, nh, true)
            if (scaled !== bmp) {
                bmp.recycle()
                bmp = scaled
            }
        }

        val f = File(dest)
        f.parentFile?.mkdirs()
        FileOutputStream(f).use { fos ->
            bmp.compress(Bitmap.CompressFormat.JPEG, quality, fos)
            fos.flush()
        }
        val w = bmp.width
        val h = bmp.height
        bmp.recycle()
        return mapOf("path" to f.absolutePath, "width" to w, "height" to h)
    }

    // ------------------------------------------------------------ 内部

    /**
     * 选降采样倍数（必须是 2 的幂）。
     *
     * 规则：让降采样后的宽度尽量贴近 maxWidth 但不小于它
     * （小了就把字压糊了，OCR 直接废掉），同时保证单块像素不超上限。
     */
    private fun pickSample(logicalW: Int, logicalH: Int, maxWidth: Int): Int {
        var sample = 1
        while (logicalW / (sample * 2) >= maxWidth && sample < 32) sample *= 2
        // 单块（高 1600 左右）像素上限兜底
        while (sample < 32 &&
            (logicalW / sample).toLong() * minOf(logicalH, 1600).toLong() > MAX_TILE_PIXELS
        ) {
            sample *= 2
        }
        return sample
    }

    private fun rotate(src: Bitmap, degrees: Int): Bitmap {
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        val out = Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
        if (out !== src) src.recycle()
        return out
    }

    /** EXIF 方向 → 顺时针角度 */
    @Suppress("DEPRECATION")
    private fun readRotation(path: String): Int {
        return try {
            val exif = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                ExifInterface(path)
            } else {
                // API 23 只有 InputStream 构造器；24 起才有文件路径版
                ExifInterface(FileInputStream(path))
            }
            when (exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } catch (t: Throwable) {
            // 截图基本没有 EXIF；读不到就当没旋转，绝不因为这一步失败而中断
            0
        }
    }
}
