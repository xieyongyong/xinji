package com.xinji.payslip

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * 真正的文字识别，跑在**独立进程**（`:ocr`）里。
 * 引擎只有一个：RapidOCR4j + PP-OCRv6_small + OpenCV 预处理。
 *
 * ## 为什么还留在独立进程
 * RapidOCR 底下是 ONNX Runtime + OpenCV 两套 native 库，同样会因为
 * 设备内存紧张、so 和 CPU 架构不匹配、模型文件被裁坏而直接让进程消失。
 * 那种死法 Dart 层连异常都收不到（进程整个没了，日志里只剩半句），
 * 所以识别继续放在独立进程：
 * `OcrBridge` 会收到 binder 断开回调，界面弹「识别没成功，可手动填」，
 * 图片早就存好了，用户不用重新截图。
 *
 * ## 为什么没有引擎开关了
 * ML Kit 早已删干净：它认不准工资条上的密集数字（小数点、千分位、相邻列
 * 串行），留着只是让「识别不准」这件事有两条路径、两套 bug。
 * 现在一个引擎、一条链路。
 */
class OcrService : Service() {

    companion object {
        const val MSG_RECOGNIZE = 11
        const val MSG_RESULT = 12
        const val EXTRA_PATHS = "paths"
        const val EXTRA_PAYLOAD = "payload"

        /** 是否在识别前刷掉浅灰水印 */
        const val EXTRA_CLEAN = "clean"

        /** 分块参数，和 Dart 侧常量保持一致 */
        private const val TILE_HEIGHT = 1400
        private const val TILE_OVERLAP = 120
        private const val MAX_WIDTH = 1600
        private const val TILE_QUALITY = 92

        /** 多图并行上限：中低端机别开太多，3 路够把 3-4 张的等待砍半 */
        private const val MAX_PARALLEL = 3
    }

    // 固定线程池：并发跑多张图。单张图仍按 tiles 顺序识别，去重逻辑不变。
    private val worker = Executors.newFixedThreadPool(MAX_PARALLEL)

    // 分发线程：runRecognition 要往 worker 提交任务并等结果，自己不能占 worker
    // 的线程，否则图数 ≥ 线程数时内层任务排不上队、外层又在 await，直接死锁。
    private val dispatcher = Executors.newSingleThreadExecutor()

    /**
     * 各引擎的模型文件是同一批固定名（cache/xinji_ppocrv6_*），首次初始化
     * 不能同时复制落盘，否则 rename 互相覆盖会失败。建实例+落模型串行化，
     * 建好后各线程用自己的实例并行识别。
     */
    private val engineInitLock = Any()

    /**
     * 每个工作线程一份引擎实例。RapidOCR.run() 内部持有可变的 OpenCV Mat /
     * ONNX session，多线程共享一个实例会互相踩状态；ThreadLocal 让每张图用
     * 自己的引擎。代价是内存里多几份模型（v6_small 不大，3 路可接受）。
     */
    private val engineLocal = object : ThreadLocal<RapidOcrEngine>() {
        override fun initialValue(): RapidOcrEngine = synchronized(engineInitLock) {
            val created = RapidOcrEngine(this@OcrService) { line -> trace(line) }
            created.ensureLoaded()
            trace(created.loadInfo)
            created
        }
    }

    @Volatile
    private var selfTested = false

    private val handler = Handler(Looper.getMainLooper()) { msg ->
        when (msg.what) {
            MSG_RECOGNIZE -> {
                val paths = msg.data?.getStringArrayList(EXTRA_PATHS) ?: arrayListOf()
                val clean = msg.data?.getBoolean(EXTRA_CLEAN, true) ?: true
                val reply = msg.replyTo
                dispatcher.execute { runRecognition(paths, clean, reply) }
                true
            }

            else -> false
        }
    }

    private val messenger = Messenger(handler)

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onCreate() {
        super.onCreate()
        trace("服务启动 pid=${android.os.Process.myPid()}")
    }

    override fun onDestroy() {
        // RapidOCR 没有 close()：ONNX session 和 OpenCV Mat 由 GC 回收。
        // 进程退出时系统会一并收掉 native 资源，这里不能调不存在的方法。
        worker.shutdownNow()
        dispatcher.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 识别主流程

    private fun runRecognition(
        paths: List<String>,
        clean: Boolean,
        reply: Messenger?
    ) {
        val payload = try {
            // 自检只跑一次且必须串行（此时还没分发并行任务），先做掉。
            selfTest()

            // 多图并行：每张图一个任务丢线程池。结果按输入下标回填，
            // 完成顺序不定也不会错位；去重仍在 recognizeImage 内部按图顺序做。
            val results = arrayOfNulls<JSONObject>(paths.size)
            val errors = arrayOfNulls<Throwable>(paths.size)
            val done = CountDownLatch(paths.size)
            for ((i, path) in paths.withIndex()) {
                worker.execute {
                    try {
                        results[i] = recognizeImage(path, i, clean)
                    } catch (t: Throwable) {
                        errors[i] = t
                    } finally {
                        done.countDown()
                    }
                }
            }
            done.await()

            // 按输入顺序收集；任何一张失败就整体报错（和原来串行语义一致）。
            errors.firstOrNull { it != null }?.let { throw it }
            val images = JSONArray()
            for (r in results) images.put(r)
            JSONObject().put("ok", true).put("images", images).toString()
        } catch (t: Throwable) {
            trace("识别失败：${t.javaClass.simpleName} ${t.message}")
            JSONObject()
                .put("ok", false)
                .put("error", humanMessage(t))
                .toString()
        }

        try {
            val msg = Message.obtain(null, MSG_RESULT)
            msg.data = Bundle().apply { putString(EXTRA_PAYLOAD, payload) }
            reply?.send(msg)
        } catch (t: Throwable) {
            trace("回传结果失败：${t.message}")
        }
    }

    /**
     * 开机自检：拿一张 320×120 的合成小图先识别一次。
     *
     * 目的不是校验准确率，而是把两类故障分开：
     * - 自检就崩 → 这台设备上根本跑不起来（模型/ABI/内存限制），
     *   后续任何图都不可能成功，没必要让用户一张张试
     * - 自检过了、真实图崩 → 是图太大或内存问题，方向完全不同
     *
     * 自检还会把识别出来的字写进日志：一旦出现「自检 通过「」」这种空结果，
     * 就说明引擎能跑但输出是空的（模型和字典对不上），比只报个崩溃好定位得多。
     */
    private fun selfTest() {
        if (selfTested) return
        synchronized(this) {
            if (selfTested) return
            trace("自检 开始")
            val bmp = Bitmap.createBitmap(320, 120, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(bmp)
                canvas.drawColor(Color.WHITE)
                val paint = Paint().apply {
                    color = Color.BLACK
                    textSize = 44f
                    isAntiAlias = true
                }
                canvas.drawText("薪迹 1234", 14f, 72f, paint)

                val hits = engineLocal.get().recognize(bmp)
                val text = hits.joinToString("") { it.text }.trim()
                trace("自检 通过「${text.take(24)}」(${hits.size} 段)")
                selfTested = true
            } finally {
                bmp.recycle()
            }
        }
    }

    private fun recognizeImage(path: String, index: Int, clean: Boolean): JSONObject {
        val dir = File(cacheDir, "ocrtiles")
        if (!dir.exists()) dir.mkdirs()
        val tag = "o${System.currentTimeMillis()}_$index"

        trace("图$index 开始分块 ${File(path).name} clean=$clean")
        val tiles = SlipImaging.tiles(
            path = path,
            tileHeight = TILE_HEIGHT,
            overlap = TILE_OVERLAP,
            maxWidth = MAX_WIDTH,
            quality = TILE_QUALITY,
            outDir = dir.absolutePath,
            tag = tag,
            clean = clean
        )
        trace("图$index 分成 ${tiles.size} 块")

        val lines = JSONArray()
        val text = StringBuilder()
        // 重叠区去重：文字相同、纵向相差不到 40px 视为同一行
        val recent = ArrayList<Pair<String, Int>>()

        try {
            for ((ti, tile) in tiles.withIndex()) {
                val tilePath = tile["path"] as String
                val top = (tile["top"] as Number).toInt()
                val w = (tile["width"] as Number).toInt()
                val h = (tile["height"] as Number).toInt()

                val f = File(tilePath)
                if (!f.exists() || f.length() < 256L) {
                    throw IllegalStateException("第 ${ti + 1} 块图片写盘失败")
                }

                // 这一行是排查崩溃的关键线索：日志停在这里，就说明识别 ${w}x${h} 时挂了
                // 后面的「去灰」是水印清理结果，识别不准时先看这个数
                val cleanInfo = tile["clean"] as? String ?: "-"
                trace("图$index 块$ti ${w}x$h 识别开始 去灰=$cleanInfo")

                val bmp = BitmapFactory.decodeFile(tilePath)
                    ?: throw IllegalStateException("第 ${ti + 1} 块图片解码失败")
                val started = System.currentTimeMillis()
                val hits: List<RapidOcrEngine.Hit> = try {
                    engineLocal.get().recognize(bmp)
                } finally {
                    // 一块 1600x1400 的位图就是 9MB，用完立刻放
                    bmp.recycle()
                }
                trace("图$index 块$ti 识别完成 ${hits.size} 段 ${System.currentTimeMillis() - started}ms")

                for (hit in hits) {
                    val t = hit.text.trim()
                    if (t.isEmpty()) continue
                    val y = hit.top.toInt() + top
                    var duplicate = false
                    for (p in recent) {
                        if (p.first == t && abs(p.second - y) < 40) {
                            duplicate = true
                            break
                        }
                    }
                    if (duplicate) continue
                    recent.add(t to y)
                    if (recent.size > 60) recent.removeAt(0)

                    text.append(t).append(' ')
                    lines.put(
                        JSONArray()
                            .put(t)
                            .put(hit.left.toInt())
                            .put(y)
                            .put(hit.right.toInt())
                            .put(hit.bottom.toInt() + top)
                    )
                }
            }
        } finally {
            for (tile in tiles) {
                try {
                    File(tile["path"] as String).delete()
                } catch (_: Throwable) {
                }
            }
        }

        trace("图$index 识别结束 ${lines.length()} 行")
        return JSONObject().put("text", text.toString()).put("lines", lines)
    }

    /** 把技术异常翻译成用户能看懂的一句话 */
    private fun humanMessage(t: Throwable): String {
        val msg = t.message ?: t.toString()
        return when {
            msg.contains("timeout", true) -> "识别超时，这张图可能太长了"
            msg.contains("UnsatisfiedLink", true) ||
                msg.contains("NoSuchMethod", true) ||
                msg.contains("NoClassDefFound", true) ||
                msg.contains("loadLibrary", true) ||
                msg.contains("onnxruntime", true) ||
                msg.contains("opencv", true) ->
                "识别引擎（RapidOCR / OpenCV）在这台机器上装不起来：$msg"
            msg.contains("onnx", true) || msg.contains("模型", true) ->
                "PP-OCRv6 模型加载失败：$msg"
            msg.contains("out of memory", true) || msg.contains("OOM", true) ->
                "内存不足，这张图太长，可以裁成两张再导入"
            else -> msg
        }
    }

    /**
     * 面包屑日志，写在应用私有目录。
     *
     * 崩溃发生在 native 层时，Dart 的 CrashLog 完全收不到信号，
     * 只有这种「动手之前先写一行」的记录能说明崩在哪一步。
     * 主进程和 :ocr 进程同 UID、同一 filesDir，所以 Dart 侧能直接读。
     */
    private fun trace(text: String) {
        // 并行线程同时 append 会写花，串行化
        synchronized(traceLock) {
            try {
                val f = File(filesDir, "ocr_trace.log")
                if (f.exists() && f.length() > 128 * 1024) f.delete()
                val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())
                f.appendText("$stamp $text\n")
            } catch (_: Throwable) {
                // 日志写不进去绝不影响识别
            }
        }
    }

    private val traceLock = Any()
}
