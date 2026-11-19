package com.xinji.payslip

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.View

/**
 * 切后台时的隐私遮罩，挂在 FlutterView 之上。
 *
 * 为什么必须用原生 View，而不是 Flutter 画遮罩：
 * Flutter 的 didChangeAppLifecycleState(inactive) 要经过
 *   platform channel → Dart isolate → scheduler → build/layout/paint → raster → 合成
 * 一整条链路，而系统在 onPause 之后就抓最近任务缩略图；
 * 更要命的是 Activity 一旦不可见，Flutter engine 会暂停帧调度，
 * 那帧遮罩可能永远画不出来 —— 实测「很大概率没生效」就是这个原因。
 * 原生 View 的 traversal 是窗口级的，不受引擎停帧影响，且同步执行在 UI 线程上。
 *
 * 全代码绘制，零位图资源：纵向深色渐变 + 中心柔光 + 应用图标 + 闭眼徽标。
 * 微信/Alipay 之类的做法同理，视觉上就是「一块深色磨砂玻璃 + logo」。
 */
class PrivacyMaskView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val density = resources.displayMetrics.density
    private fun dp(v: Float): Float = v * density

    /** 应用图标，由 MainActivity 预取后传入；为 null 时只显示柔光和徽标 */
    private var icon: Drawable? = null

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private val platePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(0x26, 0xFF, 0xFF, 0xFF) // 15% 白，图标底盘
    }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.2f)
        color = Color.argb(0x59, 0xFF, 0xFF, 0xFF) // 35% 白描边
    }
    private val badgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.WHITE
    }
    private val eyePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.6f)
        strokeCap = Paint.Cap.ROUND
        color = Color.argb(0xE6, 0x2A, 0x2E, 0x33) // 深灰，闭眼图形
    }

    private val eyePath = Path()

    fun bindIcon(d: Drawable?) {
        icon = d
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // 纵向渐变让整块不是一个死黑，而像一块深色磨砂玻璃；
        // alpha 用 F0（94%）而不是全不透明，保留一点点「透过玻璃」的观感，
        // 同时把工资条的文字压到不可辨认。
        bgPaint.shader = LinearGradient(
            0f, 0f, 0f, h.toFloat(),
            intArrayOf(
                Color.argb(0xF0, 0x0E, 0x10, 0x14),
                Color.argb(0xF0, 0x1A, 0x1E, 0x25),
            ),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP,
        )
        // 中心柔光：把视线引到图标上，也避免整屏太"平"
        val radius = dp(180f).coerceAtLeast(1f)
        glowPaint.shader = RadialGradient(
            w / 2f, h / 2f, radius,
            intArrayOf(Color.argb(0x1F, 0xFF, 0xFF, 0xFF), Color.TRANSPARENT),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP,
        )
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        canvas.drawRect(0f, 0f, w, h, bgPaint)
        canvas.drawRect(0f, 0f, w, h, glowPaint)

        val cx = w / 2f
        val cy = h / 2f
        val plateR = dp(48f)

        // 图标底盘
        canvas.drawCircle(cx, cy, plateR, platePaint)
        canvas.drawCircle(cx, cy, plateR, ringPaint)

        // 应用图标
        val d = icon
        if (d != null) {
            val half = dp(31f)
            d.setBounds(
                (cx - half).toInt(),
                (cy - half).toInt(),
                (cx + half).toInt(),
                (cy + half).toInt(),
            )
            d.draw(canvas)
        }

        // 右下角闭眼徽标：明确表达「内容已隐藏」
        val br = dp(17f)
        val bx = cx + plateR - dp(6f)
        val by = cy + plateR - dp(6f)
        canvas.drawCircle(bx, by, br, badgePaint)
        drawClosedEye(canvas, bx, by, dp(6f))
    }

    /** 一只闭合的眼睛 + 一道斜杠，纯 Path 绘制，不依赖图标字体 */
    private fun drawClosedEye(canvas: Canvas, cx: Float, cy: Float, halfW: Float) {
        eyePath.reset()
        eyePath.moveTo(cx - halfW, cy - halfW * 0.15f)
        eyePath.quadTo(cx, cy + halfW * 0.85f, cx + halfW, cy - halfW * 0.15f)
        canvas.drawPath(eyePath, eyePaint)
        canvas.drawLine(
            cx - halfW * 0.8f, cy + halfW * 0.7f,
            cx + halfW * 0.8f, cy - halfW * 0.7f,
            eyePaint,
        )
    }
}
