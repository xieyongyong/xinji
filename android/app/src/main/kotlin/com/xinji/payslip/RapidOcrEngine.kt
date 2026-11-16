package com.xinji.payslip

import android.content.Context
import android.graphics.Bitmap
import io.github.hzkitty.RapidOCR
import io.github.hzkitty.entity.OcrConfig
import io.github.hzkitty.entity.ParamConfig
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.MatOfDouble
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.io.FileOutputStream

/**
 * RapidOCR4j-Android + PP-OCRv6_small + OpenCV 预处理。
 *
 * ## 为什么是这套
 * 用户指定的方案：RapidOCR 的 Java/Android 移植版负责完整的检测→识别流程
 * （它内部已经用 OpenCV 做检测框后处理、CTC 解码），我们这边再补一道
 * **工资条专用预处理**：灰度 → CLAHE（灰底 / 拍照阴影）→ 高斯去噪 → 三通道。
 *
 * ## 模型从哪来
 * rapidocr4j-android 的 AAR 自带 PP-OCRv4 模型，但我们要的是 **v6_small**。
 * 库的 [OcrConfig.DetConfig.modelPath] 支持相对 assets 的路径，会自己复制到
 * cacheDir；这里有两点坑：
 *  1. 它的 copyAssetToCache 不会创建父目录 → 必须给**平铺文件名**，
 *     所以我们自己先把 assets/ppocr 下的 .onnx 复制到 cacheDir 顶层
 *  2. recKeysPath 走 Files.newInputStream(绝对路径)，不认 assets 相对路径
 *     → 字典也必须自己复制一份
 *
 * v6_small 的 CTC 约定和库一致：0=blank，1..N=字典，N+1=空格；
 * 我们的 dict.txt 有 18708 行，库会在末尾插空格、开头插 blank，正好对上。
 *
 * ## 为什么保留 :ocr 独立进程
 * RapidOCR 底层还是 ONNX Runtime + OpenCV 两套 native 库，so 不匹配、
 * 内存紧张时照样会让进程直接消失。放在独立进程，主 App 还活着，
 * 用户能手动填，不用重新截图。
 */
class RapidOcrEngine(
    private val context: Context,
    private val log: (String) -> Unit,
) {
    /** 一行文字 + 它在**当前分块图**里的外接矩形 */
    data class Hit(
        val text: String,
        val left: Double,
        val top: Double,
        val right: Double,
        val bottom: Double,
        val confidence: Float,
    )

    private var engine: RapidOCR? = null
    private var param: ParamConfig? = null

    val loadInfo: String
        get() = "RapidOCR4j + PP-OCRv6_small(det/rec) + OpenCV(灰度/CLAHE/去噪)"

    fun ensureLoaded() {
        if (engine != null) return
        log("RapidOCR 引擎初始化开始")

        // 1) 把 v6_small 模型和字典从 assets 落到 cache（平铺文件名）
        val detFile = copyAsset("ppocr/det.onnx", "xinji_ppocrv6_det.onnx")
        val recFile = copyAsset("ppocr/rec.onnx", "xinji_ppocrv6_rec.onnx")
        val dictFile = copyAsset("ppocr/dict.txt", "xinji_ppocrv6_dict.txt")
        log("模型就位 det=${detFile.length() / 1024}KB rec=${recFile.length() / 1024}KB dict=${dictFile.length()}B")

        val cfg = OcrConfig().apply {
            global.apply {
                useCls = false           // 工资条都是正的，方向分类白跑一遍还多占内存
                textScore = 0.35f        // 比库默认 0.5 宽松，宁可多认一行让后面去挑
                maxSideLen = 1600        // 分块图最大边就是 1600，不让库再放大
                intraOpNumThreads = 2    // 限制线程，防止中低端机上内存暴涨
                interOpNumThreads = 2
            }
            det.apply {
                modelPath = detFile.name
                limitType = "max"        // 和前面本地验证过的算法一致：长边 <=1280
                limitSideLen = 1280
                thresh = 0.2f
                boxThresh = 0.5f
                unclipRatio = 1.4f
                useArena = false         // arena 常驻不释放，OCR 进程容易被 OOM
            }
            rec.apply {
                modelPath = recFile.name
                recKeysPath = dictFile.absolutePath
                recImgShape = intArrayOf(3, 48, 320)
                useArena = false
                intraOpNumThreads = 2
                interOpNumThreads = 2
            }
        }

        try {
            engine = RapidOCR.create(context.applicationContext, cfg)
            param = ParamConfig().apply {
                useCls = false
                textScore = 0.35f
                returnWordBox = false
            }
            log("RapidOCR 引擎初始化完成")
        } catch (t: Throwable) {
            log("RapidOCR 引擎初始化失败：${t.javaClass.simpleName} ${t.message}")
            throw t
        }
    }

    fun recognize(bitmap: Bitmap): List<Hit> {
        val e = engine ?: throw IllegalStateException("RapidOCR 引擎尚未初始化")
        val p = param ?: throw IllegalStateException("RapidOCR 参数尚未初始化")

        val src = Mat()
        org.opencv.android.Utils.bitmapToMat(bitmap, src)
        val prepared = preprocess(src)
        try {
            val result = e.run(prepared, p)
            val hits = ArrayList<Hit>()
            for (r in result.recRes ?: emptyList()) {
                val box = r.dtBoxes ?: continue
                val text = r.text.trim()
                if (text.isEmpty()) continue
                var x0 = Double.MAX_VALUE
                var y0 = Double.MAX_VALUE
                var x1 = -Double.MAX_VALUE
                var y1 = -Double.MAX_VALUE
                for (pt in box) {
                    x0 = minOf(x0, pt.x)
                    y0 = minOf(y0, pt.y)
                    x1 = maxOf(x1, pt.x)
                    y1 = maxOf(y1, pt.y)
                }
                if (x1 <= x0 || y1 <= y0) continue
                hits.add(Hit(text, x0, y0, x1, y1, r.confidence))
            }
            return hits
        } finally {
            prepared.release()
            src.release()
        }
    }

    /**
     * OpenCV 图像预处理：灰度 →（低对比度时）CLAHE → 高斯去噪 → 三通道。
     *
     * 不做全局二值化：工资条里有彩色印章、灰底表格，Otsu 容易把浅色数字
     * 一起吃掉。灰度 + 局部对比度增强对截图和拍照两种来源都稳。
     *
     * 输出必须是 **3 通道**：RapidOCR 的 DetPreProcess 里写死了
     * convertTo(CV_32FC3)，传 4 通道 RGBA 进去会直接炸。
     */
    private fun preprocess(src: Mat): Mat {
        val gray = Mat()
        try {
            val code = if (src.channels() == 4) Imgproc.COLOR_RGBA2GRAY else Imgproc.COLOR_BGR2GRAY
            Imgproc.cvtColor(src, gray, code)

            val mean = MatOfDouble()
            val std = MatOfDouble()
            Core.meanStdDev(gray, mean, std)
            val contrast = std.toArray().firstOrNull() ?: 0.0

            val boosted = Mat()
            if (contrast < 55.0) {
                // 灰底/阴影照片：局部直方图均衡，比全局拉伸更保笔画
                val clahe = Imgproc.createCLAHE(2.0, Size(8.0, 8.0))
                clahe.apply(gray, boosted)
            } else {
                gray.copyTo(boosted)
            }

            try {
                val denoised = Mat()
                Imgproc.GaussianBlur(boosted, denoised, Size(3.0, 3.0), 0.0)
                try {
                    val out = Mat()
                    Imgproc.cvtColor(denoised, out, Imgproc.COLOR_GRAY2BGR)
                    return out
                } finally {
                    denoised.release()
                }
            } finally {
                boosted.release()
                mean.release()
                std.release()
            }
        } finally {
            gray.release()
        }
    }

    /** assets → cacheDir 的平铺文件；rapidocr4j 自己不建父目录，所以不能带子路径 */
    private fun copyAsset(asset: String, name: String): File {
        val out = File(context.cacheDir, name)
        val tmp = File(context.cacheDir, "$name.tmp")
        try {
            context.assets.open(asset).use { input ->
                FileOutputStream(tmp).use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.flush()
                }
            }
            if (out.exists() && !out.delete()) {
                throw IllegalStateException("无法覆盖旧模型文件：$name")
            }
            if (!tmp.renameTo(out)) throw IllegalStateException("模型文件落盘失败：$name")
            return out
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }
}
