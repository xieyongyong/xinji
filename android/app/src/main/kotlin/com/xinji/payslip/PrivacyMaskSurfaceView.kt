package com.xinji.payslip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * 后台隐私遮罩的主实现：一个常驻、平时全透明的 SurfaceView。
 *
 * ## 为什么不用普通 View
 * 系统在 `onPause` 返回后极短时间就抓最近任务快照。普通 View 改 alpha 之后还要
 *   等 vsync → measure/layout/draw → RenderThread 上传 buffer → 合成
 * 至少一帧，几乎必然晚于抓图。而 SurfaceView 有自己独立的 surface，
 * `lockCanvas()` → 画 → `unlockCanvasAndPost()` 是**同步提交 buffer** 的，
 * 完全绕开 UI 线程的渲染管线，只剩 SurfaceFlinger 合成这一步 ——
 * 系统抓图读的也是合成结果，所以只要 buffer 先到就一定拍得到。
 *
 * ## 平时为什么是透明的
 * `setZOrderOnTop(true)` 让这层 surface 位于 window 之上。平时画一帧全透明，
 * 用户看到的仍然是 Flutter 界面；`showMask()` 时同步画上模糊图 + 图标，
 * 下一帧合成就是遮罩。整个过程约 2~5ms，全部在 UI 线程同步完成。
 */
class PrivacyMaskSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    private val density = resources.displayMetrics.density
    private fun dp(v: Float): Float = v * density

    /** 当前画面的缩小模糊图，由 MainActivity 用 PixelCopy 抓取后传入 */
    private var blurred: Bitmap? = null

    private var icon: Drawable? = null

    /** 当前是否处于「遮住」状态。false 时 surface 上是一帧全透明 */
    private var showing = false

    private val snapPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    /** 压在模糊图上的暗层，保留一点透亮感 */
    private val dimPaint = Paint().apply { color = Color.argb(0x3D, 0x0A, 0x0C, 0x10) }

    /** 还没有可用快照时的兜底底色（冷启动第一次离开 App） */
    private val fallbackPaint = Paint().apply { color = Color.rgb(0x14, 0x17, 0x1C) }

    private val platePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(0x26, 0xFF, 0xFF, 0xFF)
    }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.2f)
        color = Color.argb(0x59, 0xFF, 0xFF, 0xFF)
    }

    private val dst = Rect()

    init {
        // 独立 layer 放在 window 之上，否则会被 Flutter 的 surface 盖住
        setZOrderOnTop(true)
        holder.setFormat(PixelFormat.TRANSLUCENT)
        holder.addCallback(this)
        // 不吃触摸事件：透明时事件要继续传给下面的 Flutter
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun bindIcon(d: Drawable?) {
        icon = d
    }

    fun bindSnapshot(b: Bitmap?) {
        blurred = b
        if (showing) render()
    }

    /** 立刻把遮罩画进 surface 并提交。这是 onPause 里唯一的关键动作。 */
    fun showMask() {
        showing = true
        render()
    }

    /** 恢复成全透明。 */
    fun hideMask() {
        if (!showing) return
        showing = false
        render()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        // 首次创建 / 从后台回来 surface 重建时补一帧，避免出现未定义的底色
        render()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        render()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {}

    /**
     * 同步往 surface 里画一帧。
     *
     * `lockCanvas` 无参版本拿到的是整块可写 buffer（保留上一帧内容），
     * 所以两条分支都必须自己铺满，不能指望它自动清空。
     */
    @Synchronized
    private fun render() {
        val h = holder
        if (!h.surface.isValid) return
        val canvas = try {
            h.lockCanvas()
        } catch (_: Throwable) {
            null
        } ?: return

        try {
            if (showing) {
                drawMask(canvas)
            } else {
                canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
            }
        } catch (_: Throwable) {
            // 画失败就直接 post（可能是半帧），至少不会崩
        } finally {
            try {
                h.unlockCanvasAndPost(canvas)
            } catch (_: Throwable) {
            }
        }
    }

    private fun drawMask(canvas: Canvas) {
        val w = canvas.width
        val h = canvas.height

        val bmp = blurred
        if (bmp != null && !bmp.isRecycled && bmp.width > 0 && bmp.height > 0) {
            // 小图放大铺满：放大本身即强低通滤波，观感就是毛玻璃
            dst.set(0, 0, w, h)
            canvas.drawBitmap(bmp, null, dst, snapPaint)
        } else {
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), fallbackPaint)
        }
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), dimPaint)

        val cx = w / 2f
        val cy = h / 2f
        val plateR = dp(48f)

        canvas.drawCircle(cx, cy, plateR, platePaint)
        canvas.drawCircle(cx, cy, plateR, ringPaint)

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
