package com.xinji.payslip

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path

/**
 * 遮罩右下角的「内容已隐藏」徽标。
 *
 * 形状对齐 Material 的 `Icons.visibility_off`（睁眼 + 斜杠），也就是 v2.7.0 用的那个图标。
 * v2.7.3 手写的「一条弧线 + 斜杠」在 19dp 这种小尺寸下看着像个斜杠笑脸，用户明确反馈不对，
 * 所以这里按标准眼形重画：杏仁形眼廓 + 挖空瞳孔 + 左上到右下的斜杠。
 *
 * 纯 Path 绘制，不依赖图标字体或位图资源，两个遮罩实现（Surface 版 / View 版）共用。
 */
internal object MaskBadge {

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        style = Paint.Style.FILL
    }

    private val glyphPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF2A2E33.toInt()
        style = Paint.Style.FILL
    }

    private val cutPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = 0xFFFFFFFF.toInt()
    }

    private val eye = Path()

    /**
     * @param cx     徽标圆心 X
     * @param cy     徽标圆心 Y
     * @param radius 徽标半径（v2.7.0 是 17dp，即直径 34dp）
     */
    fun draw(canvas: Canvas, cx: Float, cy: Float, radius: Float) {
        // 白色圆底
        canvas.drawCircle(cx, cy, radius, bgPaint)

        // 图标占徽标直径的 56%（19dp / 34dp），与 v2.7.0 的比例一致。
        // 下面的坐标按 Material 图标的 24×24 viewport 归一化后缩放。
        val s = radius * 1.118f / 24f
        fun px(v: Float) = cx + (v - 12f) * s
        fun py(v: Float) = cy + (v - 12f) * s

        // 杏仁形眼廓（上下两条三次贝塞尔）
        eye.reset()
        eye.moveTo(px(2f), py(12f))
        eye.cubicTo(px(4.6f), py(6.5f), px(8.1f), py(4.6f), px(12f), py(4.6f))
        eye.cubicTo(px(15.9f), py(4.6f), px(19.4f), py(6.5f), px(22f), py(12f))
        eye.cubicTo(px(19.4f), py(17.5f), px(15.9f), py(19.4f), px(12f), py(19.4f))
        eye.cubicTo(px(8.1f), py(19.4f), px(4.6f), py(17.5f), px(2f), py(12f))
        eye.close()
        canvas.drawPath(eye, glyphPaint)

        // 瞳孔：用底色挖出来
        canvas.drawCircle(px(12f), py(12f), s * 3.2f, bgPaint)

        // 斜杠：Material visibility_off 是左上 → 右下，同样用底色切一刀
        cutPaint.strokeWidth = s * 2.4f
        canvas.drawLine(px(3.4f), py(3.4f), px(20.6f), py(20.6f), cutPaint)
    }
}
