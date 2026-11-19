package com.xinji.payslip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.View

/**
 * 后台隐私遮罩，常驻在 FlutterView 之上，平时 alpha = 0。
 *
 * ## 为什么只保留这一个实现
 * 为了让遮罩「稳定被拍进最近任务」，之前试过四层更激进的做法：
 *   ① `onPause` 里临时 addView；
 *   ② 常驻 View 只切 alpha；
 *   ③ 常驻 `SurfaceView` + `lockCanvas/unlockCanvasAndPost` 同步提交 buffer；
 *   ④ 常驻 `SurfaceView` + `SurfaceControl.Transaction.setAlpha()` 切 layer alpha，
 *      buffer 里常放不透明遮罩内容。
 * ③④ 在测机上「全面屏上滑回桌面」依旧拍不到；而 ④ 更糟 —— 那层 layer 的 alpha
 * 会在 surface 重建（窗口 relayout、从后台回到前台、尺寸变化）时被系统复位成 1，
 * 不透明遮罩内容就直接盖在前台界面上，App 完全没法用。
 *
 * 结论：在 App 层，遮罩只能做到「尽力而为」。现在选择的是
 * **宁可偶尔漏拍，也绝不影响正常使用** —— 一个普通 View，alpha 0/1，
 * 拿不到焦点或回到前台时一律压到 0。
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

        // 徽标贴在 96dp 底盘的右下角（和 v2.7.0 的位置一致）
        MaskBadge.draw(canvas, cx + dp(31f), cy + dp(31f), dp(17f))
    }
}
