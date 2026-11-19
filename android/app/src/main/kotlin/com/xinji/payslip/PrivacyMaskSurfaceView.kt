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
import android.view.SurfaceControl
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * 后台隐私遮罩的主实现：一个常驻的 SurfaceView。
 *
 * ## 为什么普通 View 不行
 * 系统在 `onPause` 返回后极短时间就抓最近任务快照。普通 View 改 alpha 之后还要走
 *   等 vsync → measure/layout/draw → RenderThread 上传 buffer → 合成
 * 至少一帧，几乎必然晚于抓图。`onUserLeaveHint` 也救不了 —— 它和 onPause 是
 * 同一个 binder 消息里连续调用的，中间主线程不返回，一次 vsync 都等不到。
 *
 * ## 为什么连 lockCanvas 也不行
 * `lockCanvas` → `unlockCanvasAndPost` 确实是同步提交 buffer 的，但它提交完
 * 还得等 SurfaceFlinger **下一次合成**才会出现在抓图结果里。实测全面屏上滑回桌面
 * 仍然失效 —— 系统那条路径抓得更早。
 *
 * ## 现在的做法：只改合成参数，不产生任何新 buffer
 * `SurfaceView.getSurfaceControl()` 能拿到这层 surface 在 SurfaceFlinger 里的句柄，
 * 用 `SurfaceControl.Transaction.setAlpha()` 切可见性。事务是直接交给合成器执行的，
 * 不经过 App 出帧、不经过 buffer 上传，是这条链路上唯一还能再提前的手段。
 *
 * 具体做法：**buffer 里一直放的是遮罩内容**，平时用事务把 layer alpha 压到 0
 * （用户看到的仍然是 Flutter 界面），需要时一个事务拉回 1。
 * 拿不到 SurfaceControl 的机型自动退回「改内容」的老路径（画遮罩 / 清透明）。
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

    /** 逻辑上的「是否遮住」 */
    private var contentVisible = false

    /** 是否成功用上了 SurfaceControl 事务路径。用上之后 buffer 永远是遮罩内容 */
    private var layerMode = false

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
        // layer 不可见时这一步用户完全感知不到，下次亮遮罩直接就是新底图
        render()
    }

    /** 亮遮罩：优先用合成器事务，一步到位。 */
    fun showMask() {
        contentVisible = true
        if (layerMode) {
            // buffer 里已经是遮罩内容，只需要把 layer 拉回可见
            if (applyLayerAlpha(1f)) return
            // 事务突然不可用了（surface 重建等），退回「改内容」路径
            layerMode = false
        }
        if (applyLayerAlpha(1f)) {
            // 事务可用：buffer 补一帧遮罩内容，之后固定不再变
            layerMode = true
            render()
            return
        }
        // 事务不可用，退回老路径：把遮罩画进 surface
        render()
    }

    /** 撤遮罩：事务可用时只压 alpha，buffer 保持不动，下次亮起来是零成本。 */
    fun hideMask() {
        contentVisible = false
        if (applyLayerAlpha(0f)) {
            layerMode = true
            // 关键：buffer 必须同步成遮罩内容。否则下次 showMask 只切 alpha 时，
            // 显示的是一张从未画过的空 buffer，等于完全没遮罩。
            // 此刻 layer 不可见，这帧重绘用户完全感知不到。
            render()
            return
        }
        // 事务不可用：退回内容控制。这里必须把 layerMode 置回 false，
        // 否则 render() 会画遮罩，而 layer alpha 若残留 1 就会糊住整个界面。
        layerMode = false
        render()
    }

    /**
     * 用 SurfaceControl 事务切 layer alpha。
     *
     * 这是整条链路里唯一「不产生新 buffer、不等合成队列」的操作：
     * 事务直接由 SurfaceFlinger 应用。
     *
     * @return true 表示事务提交成功；false 表示这层拿不到 SurfaceControl，
     *         调用方需要退回「改内容」的老路径。
     */
    private fun applyLayerAlpha(alpha: Float): Boolean {
        // 这里不能声明成 SurfaceControl?：setAlpha 的形参是非空的，
        // 而 `?: return` 之后已经是非空类型了（之前写成可空直接编译失败）。
        val sc: SurfaceControl = try {
            surfaceControl
        } catch (_: Throwable) {
            null
        } ?: return false

        return try {
            SurfaceControl.Transaction()
                .setAlpha(sc, alpha)
                .apply()
            true
        } catch (_: Throwable) {
            false
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        // 先把 layer 压到不可见，再画内容 —— 否则会出现一帧遮罩闪烁
        layerMode = applyLayerAlpha(0f)
        render()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        render()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {}

    /**
     * 往 surface 里画一帧。
     *
     * 事务路径下 buffer 恒为遮罩内容（可见性交给合成器）；
     * 兜底路径下按 [contentVisible] 决定画遮罩还是清成全透明。
     *
     * `lockCanvas` 无参版本拿到的 buffer 保留上一帧内容，两条分支都必须自己铺满。
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
            if (layerMode || contentVisible) {
                drawMask(canvas)
            } else {
                canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
            }
        } catch (_: Throwable) {
            // 画失败也照常 post（可能是半帧），至少不会崩
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
