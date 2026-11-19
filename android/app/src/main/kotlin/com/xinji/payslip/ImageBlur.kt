package com.xinji.payslip

import android.graphics.Bitmap

/**
 * 极简高斯近似：两轮横向 + 两轮纵向 box blur。
 *
 * 为什么自己写：
 * - RenderScript 要多带一份 support so（涨包体），而且 API 31 已废弃；
 * - RenderEffect 是 API 31+，本项目 minSdk 29 用不了；
 * - 作用对象是降到 1/6 屏宽的小图（约 180×400），单次耗时 2~4ms，
 *   放在 onPause 主线程上也不会被系统判定卡顿。
 */
internal object ImageBlur {

    fun blur(bitmap: Bitmap, radius: Int) {
        if (radius < 1) return
        val w = bitmap.width
        val h = bitmap.height
        if (w < 2 || h < 2) return
        val px = IntArray(w * h)
        try {
            bitmap.getPixels(px, 0, w, 0, 0, w, h)
            // 两轮 box blur 已非常接近高斯，肉眼分不出差别
            repeat(2) {
                pass(px, w, h, radius, horizontal = true)
                pass(px, w, h, radius, horizontal = false)
            }
            bitmap.setPixels(px, 0, w, 0, 0, w, h)
        } catch (_: Throwable) {
            // 极端情况下（Bitmap 已被回收）放弃模糊，直接用未模糊的小图，
            // 放大后同样是糊的，不影响隐私保护。
        }
    }

    private fun pass(px: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val len = if (horizontal) w else h
        val lines = if (horizontal) h else w
        if (len < 2) return
        val div = r * 2 + 1
        val out = IntArray(len)

        for (i in 0 until lines) {
            var a = 0
            var rr = 0
            var gg = 0
            var bb = 0

            // 初始化滑动窗口
            for (k in -r..r) {
                val x = k.coerceIn(0, len - 1)
                val c = if (horizontal) px[i * w + x] else px[x * w + i]
                a += (c ushr 24) and 0xFF
                rr += (c shr 16) and 0xFF
                gg += (c shr 8) and 0xFF
                bb += c and 0xFF
            }

            for (x in 0 until len) {
                out[x] = ((a / div) shl 24) or ((rr / div) shl 16) or
                    ((gg / div) shl 8) or (bb / div)

                val xOut = (x - r).coerceIn(0, len - 1)
                val xIn = (x + r + 1).coerceIn(0, len - 1)
                val cOut = if (horizontal) px[i * w + xOut] else px[xOut * w + i]
                val cIn = if (horizontal) px[i * w + xIn] else px[xIn * w + i]
                a += ((cIn ushr 24) and 0xFF) - ((cOut ushr 24) and 0xFF)
                rr += ((cIn shr 16) and 0xFF) - ((cOut shr 16) and 0xFF)
                gg += ((cIn shr 8) and 0xFF) - ((cOut shr 8) and 0xFF)
                bb += (cIn and 0xFF) - (cOut and 0xFF)
            }

            for (x in 0 until len) {
                if (horizontal) px[i * w + x] = out[x] else px[x * w + i] = out[x]
            }
        }
    }
}
