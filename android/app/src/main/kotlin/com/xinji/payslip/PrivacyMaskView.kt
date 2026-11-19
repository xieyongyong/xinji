package com.xinji.payslip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.View

/**
 * 切后台时的隐私遮罩，常驻在 FlutterView 之上，平时 alpha = 0。
 *
 * ## 为什么是原生 View
 * Flutter 的 didChangeAppLifecycleState 要走
 *   platform channel → Dart isolate → scheduler → build/layout/paint → raster → 合成
 * 一整条链路，而系统在 onPause 之后就抓最近任务缩略图；Activity 一旦不可见，
 * Flutter engine 还会暂停帧调度，那帧遮罩可能永远画不出来。
 *
 * ## 为什么要常驻，而不是 onPause 时才 addView
 * 临时 addView 要走 measure → layout → draw → 上传 buffer → 合成，至少一帧；
 * 系统抓图几乎总是早于这一帧，实测「大部分时候没生效」就是这个原因。
 * 常驻之后切到可见只差一次 draw，再由 MainActivity 提前到 onUserLeaveHint
 * 触发，就有足够的时间在抓图前上屏。
 *
 * ## 底图是真实画面的模糊
 * 由 MainActivity 用 PixelCopy 抓 Flutter SurfaceView 的 buffer
 * （SurfaceView 的内容不在 View.draw 里，decorView.draw 只能画出一个洞），
 * 降到 1/6 宽再放大铺满 —— 放大本身即强低通滤波，观感就是毛玻璃。
 * 抓不到图时（冷启动第一次离开）退化成深色渐变，至少不泄露内容。
 */
class PrivacyMaskView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val density = resources.displayMetrics.density
    private fun dp(v: Float): Float = v * density

    /** 应用图标，由 MainActivity 预取后传入；为 null 时只显示柔光和徽标 */
    private var icon: Drawable? = null

    /** 当前画面的缩小模糊图，null 表示还没有可用快照 */
    private var snapshot: Bitmap? = null

    private val snapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    /** 压在模糊图上的暗层：不做过头，保留一点「隔着玻璃」的透亮感 */
    private val dimPaint = Paint().apply {
        color = Color.argb(0x3D, 0x0A, 0x0C, 0x10)
    }

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
    private val srcRect = Rect()
    private val dstRect = Rect()

    fun bindIcon(d: Drawable?) {
        icon = d
    }

    /**
     * 换底图。传 null 表示还没有快照，回落到渐变兜底。
     * 调用方负责回收换下来的旧 Bitmap。
     */
    fun bindSnapshot(bmp: Bitmap?) {
        snapshot = bmp
        if (alpha > 0f) invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // 纵向渐变让整块不是一个死黑，而像一块深色磨砂玻璃
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

        val snap = snapshot
        if (snap != null && !snap.isRecycled && snap.width > 0 && snap.height > 0) {
            // 小图放大铺满：观感即毛玻璃，能看出界面轮廓但读不出任何数字
            srcRect.set(0, 0, snap.width, snap.height)
            dstRect.set(0, 0, width, height)
            canvas.drawBitmap(snap, srcRect, dstRect, snapPaint)
            canvas.drawRect(0f, 0f, w, h, dimPaint)
        } else {
            canvas.drawRect(0f, 0f, w, h, bgPaint)
            canvas.drawRect(0f, 0f, w, h, glowPaint)
        }

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
