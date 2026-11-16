package com.xinji.payslip

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.Context
import android.graphics.Bitmap
import java.io.File
import java.nio.FloatBuffer
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * PP-OCRv6（small）离线识别引擎，用 ONNX Runtime 在本机 CPU 上跑。
 *
 * ## 为什么换掉 ML Kit
 * ML Kit 在"表格 + 密集数字"的工资条上，小数点、千分位逗号、相邻列的金额
 * 经常串行或认错，而这些恰好是工资条里唯一不能错的东西。
 * PP-OCRv6 的 rec 模型专门优化过数字与表格：同一张样图上
 * 12,736.50 / 2,155.32 / 1,826.00 / 1.10 全部一次认对（置信度 1.00）。
 *
 * ## 流程（与 PaddleOCR 官方推理一致）
 * 1. 检测 det：整块图等比缩放到长边 ≤1280、补到 32 的倍数，
 *    BGR + ImageNet 归一化 → DB 输出概率图；
 * 2. 后处理：0.2 阈值二值化 → 连通域 → 平均置信度 <0.45 丢弃
 *    → 按面积/周长外扩（unclip_ratio=1.4，这里是轴对齐矩形，够用且简单）；
 * 3. 识别 rec：逐框裁出、高 48、BGR、(x/127.5-1) → CTC 贪心解码。
 *
 * 模型和字典在 assets/ppocr/ 下，首次使用时释放到私有目录 ——
 * ONNX Runtime 只认文件路径，读不了 assets。
 */
class PpOcrEngine(private val ctx: Context, private val log: (String) -> Unit = {}) {

    /** 一段识别结果（坐标是传入位图的坐标系） */
    data class Hit(
        val text: String,
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val score: Float,
    )

    /** det 的输出：概率图 + 它的宽高 */
    private class DetOut(val probs: FloatArray, val width: Int, val height: Int)

    /** rec 的输出：logits 摊平后的数组 + 时间步 + 类别数 */
    private class RecOut(val probs: FloatArray, val steps: Int, val classes: Int)

    private companion object {
        /** 模型版本标记：换模型时改这个字符串，旧拷贝会被覆盖 */
        const val MODEL_TAG = "ppocrv6_small_v1"

        /** 检测时长边上限。再放大只是变慢，小字并不会更清楚 */
        const val DET_LIMIT = 1280

        /** DB 二值化阈值 */
        const val DET_THRESH = 0.2f

        /** 框的平均置信度门槛 */
        const val BOX_THRESH = 0.45f

        /** 外扩比例 */
        const val UNCLIP_RATIO = 1.4f

        /** 识别输入高度（模型定死 48） */
        const val REC_H = 48

        /** 识别输入宽度上限（模型支持动态宽，太长的行只会拖慢） */
        const val REC_MAX_W = 2000

        // det 的 ImageNet 归一化（BGR 顺序）
        const val MEAN_B = 0.406f
        const val MEAN_G = 0.456f
        const val MEAN_R = 0.485f
        const val STD_B = 0.225f
        const val STD_G = 0.224f
        const val STD_R = 0.229f
    }

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var det: OrtSession? = null
    private var rec: OrtSession? = null
    private var detInput = "x"
    private var recInput = "x"
    private var dict: List<String> = emptyList()
    private var numClasses = 0

    /** 加载摘要，写进诊断日志 */
    var loadInfo: String = ""
        private set

    fun ensureLoaded() {
        if (det != null && rec != null) return
        val dir = prepareModels()
        dict = readDict()

        val opts = OrtSession.SessionOptions()
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        // 识别是串行跑的，2 个线程够用；再多只是抢 CPU、更费电
        opts.setIntraOpNumThreads(2)

        val d = env.createSession(File(dir, "det.onnx").absolutePath, opts)
        val r = env.createSession(File(dir, "rec.onnx").absolutePath, opts)
        detInput = d.inputNames.firstOrNull() ?: "x"
        recInput = r.inputNames.firstOrNull() ?: "x"

        // 输出最后一维是类别数：blank + 18708 个字 + 空格 = 18710
        val info = r.outputInfo.values.firstOrNull()?.info as? TensorInfo
        val shape = info?.shape
        numClasses = if (shape != null && shape.isNotEmpty()) shape[shape.size - 1].toInt() else 0

        det = d
        rec = r
        loadInfo = "PP-OCRv6 就绪 字典=${dict.size} 类别=$numClasses 字典行=${if (numClasses == dict.size + 2) "含空格" else "无空格"}"
    }

    fun close() {
        try {
            det?.close()
        } catch (_: Throwable) {
        }
        try {
            rec?.close()
        } catch (_: Throwable) {
        }
        det = null
        rec = null
    }

    // ------------------------------------------------------------ 对外入口

    fun recognize(bmp: Bitmap): List<Hit> {
        ensureLoaded()
        val boxes = detect(bmp)
        if (boxes.isEmpty()) return emptyList()

        val hits = ArrayList<Hit>(boxes.size)
        for (b in boxes) {
            val text = recognizeBox(bmp, b)
            if (text.first.isEmpty()) continue
            hits.add(Hit(text.first, b[0], b[1], b[2], b[3], text.second))
        }
        return mergeRows(hits)
    }

    // ------------------------------------------------------------ 检测

    private fun detect(bmp: Bitmap): List<FloatArray> {
        val sess = det ?: return emptyList()
        val sw = bmp.width
        val sh = bmp.height
        if (sw < 8 || sh < 8) return emptyList()

        var scale = min(DET_LIMIT.toFloat() / max(sw, sh).toFloat(), 2.0f)
        // 缩略图级别的小图就放大到能认字
        if (min(sw, sh) * scale < 64f) scale = 64f / min(sw, sh).toFloat()
        val rw = max(32, (sw * scale / 32f).roundToInt() * 32)
        val rh = max(32, (sh * scale / 32f).roundToInt() * 32)

        val px = IntArray(sw * sh)
        bmp.getPixels(px, 0, sw, 0, 0, sw, sh)

        val xs = Sampler.build(sw, rw)
        val ys = Sampler.build(sh, rh)

        val plane = rw * rh
        val buf = FloatBuffer.allocate(3 * plane)
        val ch = FloatArray(plane)
        // PaddleOCR 全程按 BGR：通道 0=B 1=G 2=R
        val means = floatArrayOf(MEAN_B, MEAN_G, MEAN_R)
        val stds = floatArrayOf(STD_B, STD_G, STD_R)
        val shifts = intArrayOf(0, 8, 16)

        for (c in 0..2) {
            val bit = shifts[c]
            val mean = means[c]
            val std = stds[c]
            var k = 0
            for (j in 0 until rh) {
                val rowA = ys.i0[j] * sw
                val rowB = ys.i1[j] * sw
                val fy = ys.w[j]
                for (i in 0 until rw) {
                    val a = (px[rowA + xs.i0[i]] shr bit) and 0xFF
                    val b = (px[rowA + xs.i1[i]] shr bit) and 0xFF
                    val c0 = (px[rowB + xs.i0[i]] shr bit) and 0xFF
                    val d = (px[rowB + xs.i1[i]] shr bit) and 0xFF
                    val top = a + (b - a) * xs.w[i]
                    val bot = c0 + (d - c0) * xs.w[i]
                    ch[k++] = ((top + (bot - top) * fy) / 255f - mean) / std
                }
            }
            buf.put(ch)
        }
        buf.rewind()

        val out = runDet(sess, buf, rw, rh) ?: return emptyList()
        val pw = out.width
        val ph = out.height
        if (pw <= 0 || ph <= 0 || out.probs.size < pw * ph) return emptyList()

        // 二值化 + 连通域（4 邻域，显式栈，避免递归爆栈）
        val probs = out.probs
        val seen = BooleanArray(ph * pw)
        val stack = IntArray(ph * pw)
        val boxes = ArrayList<FloatArray>()
        val ratioW = sw.toFloat() / rw
        val ratioH = sh.toFloat() / rh

        for (start in 0 until ph * pw) {
            if (probs[start] < DET_THRESH || seen[start]) continue
            var sp = 0
            stack[sp++] = start
            seen[start] = true
            var minX = pw
            var maxX = -1
            var minY = ph
            var maxY = -1
            var cnt = 0
            var sum = 0.0
            while (sp > 0) {
                val cur = stack[--sp]
                val cy = cur / pw
                val cx = cur - cy * pw
                cnt++
                sum += probs[cur]
                if (cx < minX) minX = cx
                if (cx > maxX) maxX = cx
                if (cy < minY) minY = cy
                if (cy > maxY) maxY = cy
                if (cx > 0 && !seen[cur - 1] && probs[cur - 1] >= DET_THRESH) {
                    seen[cur - 1] = true
                    stack[sp++] = cur - 1
                }
                if (cx < pw - 1 && !seen[cur + 1] && probs[cur + 1] >= DET_THRESH) {
                    seen[cur + 1] = true
                    stack[sp++] = cur + 1
                }
                if (cy > 0 && !seen[cur - pw] && probs[cur - pw] >= DET_THRESH) {
                    seen[cur - pw] = true
                    stack[sp++] = cur - pw
                }
                if (cy < ph - 1 && !seen[cur + pw] && probs[cur + pw] >= DET_THRESH) {
                    seen[cur + pw] = true
                    stack[sp++] = cur + pw
                }
            }
            if (maxX - minX < 2 || maxY - minY < 2) continue
            if ((sum / cnt).toFloat() < BOX_THRESH) continue

            val bw = (maxX - minX + 1).toFloat()
            val bh = (maxY - minY + 1).toFloat()
            val d = bw * bh * UNCLIP_RATIO / (2f * (bw + bh))
            val l = max(0f, (minX - d) * ratioW)
            val t = max(0f, (minY - d) * ratioH)
            val r = min(sw.toFloat(), (maxX + 1 + d) * ratioW)
            val b = min(sh.toFloat(), (maxY + 1 + d) * ratioH)
            if (r - l < 6f || b - t < 6f) continue
            boxes.add(floatArrayOf(l, t, r, b))
        }
        log("检测 ${rw}x$rh 得 ${boxes.size} 框")
        return boxes
    }

    private fun runDet(sess: OrtSession, buf: FloatBuffer, w: Int, h: Int): DetOut? {
        val tensor = OnnxTensor.createTensor(
            env, buf, longArrayOf(1L, 3L, h.toLong(), w.toLong())
        )
        try {
            val feed = HashMap<String, OnnxTensor>()
            feed[detInput] = tensor
            val res = sess.run(feed)
            try {
                val out = res.get(0) as OnnxTensor
                val shape = out.info.shape
                val ph = if (shape.size > 2 && shape[2] > 0) shape[2].toInt() else h
                val pw = if (shape.size > 3 && shape[3] > 0) shape[3].toInt() else w
                val fb = out.floatBuffer
                val arr = FloatArray(fb.remaining())
                fb.get(arr)
                return DetOut(arr, pw, ph)
            } finally {
                res.close()
            }
        } finally {
            tensor.close()
        }
    }

    // ------------------------------------------------------------ 识别

    private fun recognizeBox(bmp: Bitmap, b: FloatArray): Pair<String, Float> {
        val sess = rec ?: return "" to 0f
        val pad = 2
        val x0 = max(0, b[0].roundToInt() - pad)
        val y0 = max(0, b[1].roundToInt() - pad)
        val x1 = min(bmp.width, b[2].roundToInt() + pad)
        val y1 = min(bmp.height, b[3].roundToInt() + pad)
        val cw = x1 - x0
        val chh = y1 - y0
        if (cw < 4 || chh < 4) return "" to 0f

        var rw = (REC_H * (cw.toFloat() / chh)).roundToInt()
        rw = rw.coerceIn(16, REC_MAX_W)

        val px = IntArray(cw * chh)
        bmp.getPixels(px, 0, cw, x0, y0, cw, chh)

        val xs = Sampler.build(cw, rw)
        val ys = Sampler.build(chh, REC_H)

        val plane = rw * REC_H
        val buf = FloatBuffer.allocate(3 * plane)
        val ch = FloatArray(plane)
        val shifts = intArrayOf(0, 8, 16)
        for (c in 0..2) {
            val bit = shifts[c]
            var k = 0
            for (j in 0 until REC_H) {
                val rowA = ys.i0[j] * cw
                val rowB = ys.i1[j] * cw
                val fy = ys.w[j]
                for (i in 0 until rw) {
                    val a = (px[rowA + xs.i0[i]] shr bit) and 0xFF
                    val b1 = (px[rowA + xs.i1[i]] shr bit) and 0xFF
                    val c0 = (px[rowB + xs.i0[i]] shr bit) and 0xFF
                    val d = (px[rowB + xs.i1[i]] shr bit) and 0xFF
                    val top = a + (b1 - a) * xs.w[i]
                    val bot = c0 + (d - c0) * xs.w[i]
                    // rec 的归一化是 (x/255 - 0.5) / 0.5
                    ch[k++] = (top + (bot - top) * fy) / 127.5f - 1f
                }
            }
            buf.put(ch)
        }
        buf.rewind()

        val out = runRec(sess, buf, rw) ?: return "" to 0f
        if (out.steps <= 0 || out.classes <= 0) return "" to 0f

        val sb = StringBuilder()
        var prev = -1
        var sum = 0f
        var n = 0
        for (s in 0 until out.steps) {
            val base = s * out.classes
            if (base + out.classes > out.probs.size) break
            var best = 0
            var mx = -1e9f
            for (c in 0 until out.classes) {
                val v = out.probs[base + c]
                if (v > mx) {
                    mx = v
                    best = c
                }
            }
            // 0 是 CTC 的 blank；连续重复帧只算一个字
            if (best != 0 && best != prev) {
                val idx = best - 1
                if (idx < dict.size) {
                    sb.append(dict[idx])
                } else if (idx == dict.size) {
                    sb.append(' ')
                }
                sum += mx
                n++
            }
            prev = best
        }
        if (n == 0) return "" to 0f

        var text = sb.toString().trim()
        // 纯中文/数字里冒出空格，多半是字距被当成空白词，去掉更安全；
        // 含英文字母的保留（"Basic Salary" 不能被粘成一坨）
        if (!text.any { it in 'a'..'z' || it in 'A'..'Z' }) {
            text = text.replace(" ", "")
        }
        return text to (sum / n)
    }

    private fun runRec(sess: OrtSession, buf: FloatBuffer, w: Int): RecOut? {
        val tensor = OnnxTensor.createTensor(
            env, buf, longArrayOf(1L, 3L, REC_H.toLong(), w.toLong())
        )
        try {
            val feed = HashMap<String, OnnxTensor>()
            feed[recInput] = tensor
            val res = sess.run(feed)
            try {
                val out = res.get(0) as OnnxTensor
                val shape = out.info.shape
                if (shape.size < 3) return null
                val steps = shape[1].toInt()
                val classes = shape[2].toInt()
                val fb = out.floatBuffer
                val arr = FloatArray(fb.remaining())
                fb.get(arr)
                return RecOut(arr, steps, classes)
            } finally {
                res.close()
            }
        } finally {
            tensor.close()
        }
    }

    // ------------------------------------------------------------ 聚成行

    /**
     * 把检测框聚成"视觉行"，并把同一行里贴得很近的框合并。
     *
     * 检测是按字块出框的，一个"基本工资"可能被切成两三段；而 Dart 侧
     * 是按"一行里有哪些片段"来判列的，切太碎反而认不出项目名。
     * 所以：间距小于行高一半 → 并（正常字距），大于 → 保留为独立列（表格列间距）。
     */
    private fun mergeRows(hits: List<Hit>): List<Hit> {
        if (hits.isEmpty()) return emptyList()
        val sorted = hits.sortedBy { (it.top + it.bottom) / 2f }

        val rows = ArrayList<MutableList<Hit>>()
        var rowTop = 0f
        var rowBottom = 0f
        for (h in sorted) {
            val cy = (h.top + h.bottom) / 2f
            val tol = (h.bottom - h.top) * 0.4f
            if (rows.isNotEmpty() && cy >= rowTop - tol && cy <= rowBottom + tol) {
                rows[rows.size - 1].add(h)
                if (h.top < rowTop) rowTop = h.top
                if (h.bottom > rowBottom) rowBottom = h.bottom
            } else {
                rows.add(mutableListOf(h))
                rowTop = h.top
                rowBottom = h.bottom
            }
        }

        val out = ArrayList<Hit>(rows.size)
        for (row in rows) {
            val cells = row.sortedBy { it.left }
            if (cells.isEmpty()) continue
            var cur = cells[0]
            for (i in 1 until cells.size) {
                val nx = cells[i]
                val gap = nx.left - cur.right
                val limit = max(cur.bottom - cur.top, nx.bottom - nx.top) * 0.5f
                cur = if (gap <= limit) {
                    Hit(
                        text = cur.text + " " + nx.text,
                        left = min(cur.left, nx.left),
                        top = min(cur.top, nx.top),
                        right = max(cur.right, nx.right),
                        bottom = max(cur.bottom, nx.bottom),
                        score = min(cur.score, nx.score),
                    )
                } else {
                    out.add(cur)
                    nx
                }
            }
            out.add(cur)
        }
        return out
    }

    // ------------------------------------------------------------ 模型文件

    /**
     * 把 assets 里的模型释放到私有目录。
     *
     * ONNX Runtime 只接受文件路径（不接受 InputStream），而 assets 在 APK 里
     * 是压缩存放的，拿不到真实路径，所以首次使用必须落一次盘。
     * [MODEL_TAG] 做标记：以后换模型只改这个常量，旧文件会被覆盖重拷。
     */
    private fun prepareModels(): File {
        val dir = File(ctx.filesDir, "ppocr")
        if (!dir.exists()) dir.mkdirs()
        val marker = File(dir, ".tag")
        val ready = marker.exists() &&
            marker.readText().trim() == MODEL_TAG &&
            File(dir, "det.onnx").length() > 1_000_000L &&
            File(dir, "rec.onnx").length() > 1_000_000L
        if (ready) return dir

        log("首次使用，释放模型到私有目录")
        copyAsset("det.onnx", dir)
        copyAsset("rec.onnx", dir)
        marker.writeText(MODEL_TAG)
        return dir
    }

    private fun copyAsset(name: String, dir: File) {
        ctx.assets.open("ppocr/$name").use { input ->
            File(dir, name).outputStream().use { out ->
                input.copyTo(out, 256 * 1024)
            }
        }
    }

    private fun readDict(): List<String> =
        ctx.assets.open("ppocr/dict.txt").bufferedReader(Charsets.UTF_8).use { it.readLines() }

    /** 双线性缩放的采样表：目标每个像素对应源图的哪两个像素、权重多少 */
    private class Sampler(val i0: IntArray, val i1: IntArray, val w: FloatArray) {
        companion object {
            fun build(srcLen: Int, dstLen: Int): Sampler {
                val i0 = IntArray(dstLen)
                val i1 = IntArray(dstLen)
                val w = FloatArray(dstLen)
                for (i in 0 until dstLen) {
                    val s = (i + 0.5f) * srcLen / dstLen - 0.5f
                    var a = floor(s.toDouble()).toInt()
                    var f = s - a
                    if (a < 0) {
                        a = 0
                        f = 0f
                    }
                    var b = a + 1
                    if (b > srcLen - 1) b = srcLen - 1
                    i0[i] = a
                    i1[i] = b
                    w[i] = f
                }
                return Sampler(i0, i1, w)
            }
        }
    }
}
