package com.xinji.payslip

import android.app.Service
import android.content.Context
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
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * 真正的文字识别，跑在**独立进程**（`:ocr`）里。
 *
 * ## 为什么不放在主进程
 * ML Kit 的中文识别是纯 native 实现。它在某些设备上会直接段错误（SIGSEGV）
 * 或者被系统 OOM 杀掉，这种情况下：
 * - Dart 层来不及抛异常（进程整个没了，日志里什么都不留）
 * - try/catch 完全无效（catch 抓不到 native 崩溃）
 *
 * 放在独立进程后，`:ocr` 崩了只是这个进程没了，主 App 还活着：
 * `OcrBridge` 会收到 binder 断开回调，界面弹「识别没成功，可手动填」，
 * 用户至少不会丢掉刚选好的图片、也不用重新截图。
 *
 * 顺带好处：主进程不再加载 ML Kit 的 so 和模型，内存占用小一大截。
 *
 * ## 为什么用 Tasks.await 而不是回调链
 * 一块一块顺序识别，逻辑最简单。这里已经在后台线程，阻塞等待不会卡 UI。
 */
class OcrService : Service() {

    companion object {
        const val MSG_RECOGNIZE = 11
        const val MSG_RESULT = 12
        const val EXTRA_PATHS = "paths"
        const val EXTRA_PAYLOAD = "payload"

        /** 是否在识别前刷掉浅灰水印 */
        const val EXTRA_CLEAN = "clean"

        /** 用哪个引擎：ppocr（默认，PP-OCRv6） / mlkit（老引擎，留作兜底） */
        const val EXTRA_ENGINE = "engine"

        const val ENGINE_PPOCR = "ppocr"
        const val ENGINE_MLKIT = "mlkit"

        /** 单块识别超时。正常一块 1~2 秒，60 秒已经非常宽松 */
        private const val TILE_TIMEOUT_SEC = 60L

        /** 分块参数，和 Dart 侧常量保持一致 */
        private const val TILE_HEIGHT = 1400
        private const val TILE_OVERLAP = 120
        private const val MAX_WIDTH = 1600
        private const val TILE_QUALITY = 92
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var recognizer: TextRecognizer? = null
    private var ppEngine: PpOcrEngine? = null
    private var selfTested = false

    private val handler = Handler(Looper.getMainLooper()) { msg ->
        when (msg.what) {
            MSG_RECOGNIZE -> {
                val paths = msg.data?.getStringArrayList(EXTRA_PATHS) ?: arrayListOf()
                val clean = msg.data?.getBoolean(EXTRA_CLEAN, true) ?: true
                val engine = msg.data?.getString(EXTRA_ENGINE) ?: ENGINE_PPOCR
                val reply = msg.replyTo
                worker.execute { runRecognition(paths, clean, engine, reply) }
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
        // ML Kit 的初始化改成用到时才做：默认走 PP-OCR，没必要为它付启动开销
    }

    /**
     * 初始化 ML Kit。
     *
     * ## 为什么必须手动做、而且只能用反射
     * ML Kit 靠 `com.google.mlkit:common` 里注册的 ContentProvider 自动初始化，
     * 但那套初始化在**独立进程里没执行**（实测日志：
     * `IllegalStateException: MlKitContext has not been initialized`）。
     *
     * 而 `MlKitContext.init(Context)` 是 `@RestrictTo` 的包级私有方法，
     * Kotlin 直接写会报 `Unresolved reference: init`（上一版构建就卡在这里）。
     *
     * 所以这里用反射：不认方法名（版本之间改过名），只按
     * 「静态方法 + 唯一参数是 Context」来找，找到就调。
     * 每一步结果都写进 ocr_trace.log，下次出问题能直接看出卡在哪。
     */
    private fun ensureMlKit() {
        val cls = try {
            Class.forName("com.google.mlkit.common.sdkinternal.MlKitContext")
        } catch (t: Throwable) {
            trace("找不到 MlKitContext：${describe(t)}")
            return
        }

        // 已经初始化过就别重复调，会抛 IllegalStateException
        try {
            cls.getMethod("getInstance").invoke(null)
            trace("MlKit 已初始化，跳过")
            return
        } catch (_: Throwable) {
            // 未初始化，继续往下走
        }

        for (m in cls.declaredMethods) {
            if (!java.lang.reflect.Modifier.isStatic(m.modifiers)) continue
            if (m.parameterTypes.size != 1) continue
            if (m.parameterTypes[0] != Context::class.java) continue
            try {
                m.isAccessible = true
                m.invoke(null, applicationContext)
                trace("MlKit 反射初始化成功（${m.name}）")
                return
            } catch (t: Throwable) {
                trace("MlKit 反射初始化失败（${m.name}）：${describe(t)}")
            }
        }

        trace("MlKit 初始化没有成功，识别会直接报错")
    }

    /** 反射调用失败时真正的原因藏在 targetException 里 */
    private fun describe(t: Throwable): String {
        val real = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
        return "${real.javaClass.simpleName}: ${real.message}"
    }

    override fun onDestroy() {
        try {
            recognizer?.close()
        } catch (_: Throwable) {
        }
        try {
            ppEngine?.close()
        } catch (_: Throwable) {
        }
        worker.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 识别主流程

    private fun runRecognition(
        paths: List<String>,
        clean: Boolean,
        engineName: String,
        reply: Messenger?
    ) {
        val payload = try {
            selfTest(engineName)
            val images = JSONArray()
            for ((i, path) in paths.withIndex()) {
                images.put(recognizeImage(path, i, clean, engineName))
            }
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
     * 自检还会把识别出来的字写进日志：一旦出现「自检 通过「」「」」这种空结果，
     * 就说明引擎能跑但输出是空的（模型对不上），比只报个崩溃好定位得多。
     */
    private fun selfTest(engineName: String) {
        if (selfTested) return
        trace("自检 引擎=$engineName 开始")
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

            val hits = if (engineName == ENGINE_MLKIT) mlKitHits(bmp) else ensurePpEngine().recognize(bmp)
            val text = hits.joinToString("") { it.text }.trim()
            trace("自检 通过「${text.take(24)}」(${hits.size} 段)")
            selfTested = true
        } finally {
            bmp.recycle()
        }
    }

    /** ML Kit 的识别结果，统一成 [PpOcrEngine.Hit] 方便上层一致处理 */
    private fun mlKitHits(bmp: Bitmap): List<PpOcrEngine.Hit> {
        val image = InputImage.fromBitmap(bmp, 0)
        val result = Tasks.await(engine().process(image), TILE_TIMEOUT_SEC, TimeUnit.SECONDS)
        val out = ArrayList<PpOcrEngine.Hit>()
        for (block in result.textBlocks) {
            for (line in block.lines) {
                val t = line.text.trim()
                if (t.isEmpty()) continue
                val bb = line.boundingBox ?: continue
                out.add(
                    PpOcrEngine.Hit(
                        text = t,
                        left = bb.left.toFloat(),
                        top = bb.top.toFloat(),
                        right = bb.right.toFloat(),
                        bottom = bb.bottom.toFloat(),
                        score = 1f
                    )
                )
            }
        }
        return out
    }

    private fun ensurePpEngine(): PpOcrEngine {
        ppEngine?.let { return it }
        val created = PpOcrEngine(this) { line -> trace(line) }
        created.ensureLoaded()
        trace(created.loadInfo)
        ppEngine = created
        return created
    }

    private fun recognizeImage(
        path: String,
        index: Int,
        clean: Boolean,
        engineName: String
    ): JSONObject {
        val dir = File(cacheDir, "ocrtiles")
        if (!dir.exists()) dir.mkdirs()
        val tag = "o${System.currentTimeMillis()}_$index"

        trace("图$index 开始分块 ${File(path).name} clean=$clean 引擎=$engineName")
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
                val hits: List<PpOcrEngine.Hit> = try {
                    if (engineName == ENGINE_MLKIT) mlKitHits(bmp) else ensurePpEngine().recognize(bmp)
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

    private fun engine(): TextRecognizer {
        recognizer?.let { return it }
        // ML Kit 在独立进程里不会自动初始化，第一次用之前必须补上
        ensureMlKit()
        val created = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        recognizer = created
        return created
    }

    /** 把技术异常翻译成用户能看懂的一句话 */
    private fun humanMessage(t: Throwable): String {
        val msg = t.message ?: t.toString()
        return when {
            msg.contains("timeout", true) -> "识别超时，这张图可能太长了"
            msg.contains("not been initialized", true) -> "识别引擎初始化失败"
            msg.contains("download", true) -> "识别模型不可用（本机不支持离线中文识别）"
            msg.contains("UnsatisfiedLink", true) ||
                msg.contains("NoSuchMethod", true) ||
                msg.contains("NoClassDefFound", true) ||
                msg.contains("loadLibrary", true) ->
                "识别引擎在这台机器上装不起来，可在设置里换回「兼容模式」"
            msg.contains("onnx", true) || msg.contains("模型", true) ->
                "PP-OCR 模型加载失败：$msg"
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
