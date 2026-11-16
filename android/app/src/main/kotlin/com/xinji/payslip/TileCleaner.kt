package com.xinji.payslip

import android.graphics.Bitmap

/**
 * 识别前的图像清理：把「浅灰色水印」直接刷成纯白。
 *
 * ## 为什么要在识别前做
 * 企业工资条截图普遍铺着对角水印（"安心工资条 1279"这类）。
 * 之前只在文字层面过滤（同一串文字重复 3 次以上就当水印丢掉），
 * 有三个躲不掉的问题：
 * 1. 水印和正文黏在一个文本框里（"1279产品开发技术支持部"）时，
 *    整串文字不会重复，规则匹配不上；
 * 2. 水印文字被 OCR 认错一两个字，就不再"完全相同"，频率统计失效；
 * 3. 水印夹在金额列里，会把金额挤掉或冒充金额。
 *
 * 水印和正文在**像素**上差得很远：正文是墨色（亮度几十），
 * 水印是纸面掺了一点灰（亮度 200 上下）。所以最干脆的做法是
 * 在交给 ML Kit 之前，把"比纸面浅一截"的像素全部刷成白纸。
 *
 * ## 阈值怎么定（不能写死）
 * 不同截图的水印深浅、纸面亮度都不一样，写死一个 200 会误伤或漏网。
 * 这里看**亮度直方图的空隙**：
 *
 * ```
 * 像素数
 *   │████                     ← 纸面（白）
 *   │                        ██
 *   │        ████            ██   ← 水印是中间那一坨
 *   │        ████            ██
 *   │  ████  ████            ██   ← 正文在最左边（墨色）
 *   └──┴─────┴───────────────┴──► 亮度
 *         ↑            ↑
 *      正文   ←空隙→   水印
 * ```
 *
 * 找「最宽的一段空档」，把阈值放在空档的**右端**：
 * 空档右边的东西（水印、纸面噪点）一律刷白，左边的东西（正文）一个像素都不碰。
 *
 * 这个选择很关键 —— 阈值放在空档中间也能去水印，但会把正文的
 * 抗锯齿灰边一起削掉，细笔画会断。放在右端是"只删空档右边，
 * 绝不切进正文"的保守做法。
 *
 * 没有水印的图自然也会有一段大空档（正文和水印之间没有东西），
 * 阈值自动落到 240 上下，等于只清了纸面噪点，正文原样保留。
 */
object TileCleaner {

    /** 纸面亮度下限：低于这个值说明是深色模式截图，整张不能动 */
    private const val MIN_PAPER = 170

    /** 纸面与最深处墨色至少要差这么多，否则这图本来就没对比度 */
    private const val MIN_CONTRAST = 40

    /** 空档至少这么宽（亮度级数）才认为是"真的分开了"，否则走保守兜底 */
    private const val MIN_GAP = 10

    /**
     * 刷白之后至少要剩下这么多比例的深色像素，否则说明阈值选歪了。
     *
     * 不用「刷白比例超多少就放弃」来兜底：白底偏灰的截图（纸面 240）
     * 整片背景都会被刷白，比例天然就高，但那是正确行为。
     * 真正该警惕的是「把正文一起刷没了」—— 用剩下的深色像素来判断。
     */
    private const val MIN_KEEP_RATIO = 0.002

    class Result(val bitmap: Bitmap, val summary: String)

    fun clean(src: Bitmap): Result {
        val w = src.width
        val h = src.height
        val n = w * h
        if (n <= 0) return Result(src, "跳过：空图")

        val px = IntArray(n)
        try {
            src.getPixels(px, 0, w, 0, 0, w, h)
        } catch (t: Throwable) {
            return Result(src, "跳过：读像素失败 ${t.javaClass.simpleName}")
        }

        // 1) 亮度直方图。77/150/29 是 BT.601 的整数近似，比浮点快很多
        val hist = IntArray(256)
        for (i in 0 until n) {
            hist[luma(px[i])]++
        }

        // 2) 平滑一下：JPEG 会在每个亮度上都撒一点噪点，不平滑会割碎空档
        val smooth = IntArray(256)
        for (v in 0..255) {
            val a = if (v < 2) 0 else v - 2
            val b = if (v > 253) 255 else v + 2
            var sum = 0
            for (k in a..b) sum += hist[k]
            smooth[v] = sum / (b - a + 1)
        }

        // 3) 纸面 = 90 分位亮度；墨色 = 2 分位亮度
        val paper = percentile(hist, n, 0.90)
        val ink = percentile(hist, n, 0.02)
        if (paper < MIN_PAPER || paper - ink < MIN_CONTRAST) {
            return Result(src, "跳过：非白底图片 paper=$paper ink=$ink")
        }

        // 4) 在「墨色之上、纸面之下」找最宽的空档
        val floor = maxOf((n * 0.001).toInt(), 6)
        val from = maxOf(ink + 15, 60)
        val to = paper - 6
        if (from >= to) return Result(src, "跳过：区间太窄 paper=$paper ink=$ink")

        var runs = 0
        var bestLen = 0
        var bestEnd = 0
        for (v in from..to) {
            if (smooth[v] < floor) {
                runs++
                if (runs > bestLen) {
                    bestLen = runs
                    bestEnd = v
                }
            } else {
                runs = 0
            }
        }

        val threshold = if (bestLen >= MIN_GAP) {
            bestEnd + 1
        } else {
            // 没有清晰空档（水印和正文的灰阶连成一片）→ 退一步只清纸面噪点
            (paper - (paper - ink) * 0.18).toInt()
        }
        val t = threshold.coerceIn(100, paper - 8)

        // 5) 刷白：只动 >= t 的像素，正文原样
        var whitened = 0
        var kept = 0
        for (i in 0 until n) {
            val c = px[i]
            if (luma(c) >= t) {
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                // 纯白才不会再被当成"浅灰文字"
                if (r != 255 || g != 255 || b != 255) {
                    px[i] = 0xFFFFFFFF.toInt()
                    whitened++
                }
            } else {
                kept++
            }
        }

        if (whitened == 0) {
            return Result(src, "无浅灰像素 paper=$paper ink=$ink T=$t")
        }
        // 刷完几乎没剩多少深色像素 → 阈值算歪了（把正文也刷了），宁可不清
        if (kept < n * MIN_KEEP_RATIO) {
            return Result(src, "跳过：刷完只剩 ${kept * 1000 / n / 10.0}% 深色像素 T=$t")
        }

        // 直接用像素数组造一张新图：比 copy() 少一次整图拷贝，峰值内存更低
        val out = try {
            Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
        } catch (e: Throwable) {
            return Result(src, "跳过：建图失败 ${e.javaClass.simpleName}")
        }
        return Result(
            out,
            "去掉浅灰 ${whitened * 1000 / n / 10.0}%（paper=$paper ink=$ink T=$t 空档=$bestLen）"
        )
    }

    private fun luma(c: Int): Int {
        val r = (c shr 16) and 0xFF
        val g = (c shr 8) and 0xFF
        val b = c and 0xFF
        return (r * 77 + g * 150 + b * 29) shr 8
    }

    /** 从暗往亮累加，累计占比达到 [ratio] 时的亮度值 */
    private fun percentile(hist: IntArray, total: Int, ratio: Double): Int {
        val target = total * ratio
        var cum = 0
        for (v in 0..255) {
            cum += hist[v]
            if (cum >= target) return v
        }
        return 255
    }
}
