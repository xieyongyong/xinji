package com.xinji.payslip

import android.graphics.Bitmap
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 必须继承 FlutterFragmentActivity，不能用默认的 FlutterActivity。
 *
 * 原因：local_auth（指纹 / 面容解锁）底层用 AndroidX BiometricPrompt，
 *      BiometricPrompt 要求宿主 Activity 是 FragmentActivity。
 *      用 FlutterActivity 会在调用指纹时直接崩溃，报
 *      "Activity must be a FragmentActivity"。
 *
 * 这是本项目最容易踩、又最难自己想明白的一个坑，改 CI 配置时不要动这一行。
 */
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val PRIVACY_CHANNEL = "xinji/privacy"
    }

    // 后台隐私保护是否开启（对应设置里的「后台隐藏内容」）。默认开，和 Dart 默认值一致。
    @Volatile
    private var privacyEnabled = true

    // 当前是否在前台。FLAG_SECURE 只在后台加、回到前台立刻清。
    private var foreground = true

    // 预取的应用图标：onPause 里现读 PackageManager 会拖慢遮罩上屏。
    private var appIconDrawable: Drawable? = null

    // 遮罩 View：真正的保底是 [applyPrivacyFlag] 的 FLAG_SECURE（系统级，100%）。
    // 这一层只是「万一某些 ROM 忽略 flag」时的视觉补充，平时 alpha = 0。
    //
    // 历史教训：这里曾经并行挂过一个 ZOrderOnTop 的 SurfaceView，用 SurfaceControl
    // 事务切 layer alpha 来实现「零等待」。它的 buffer 里必须一直放着不透明遮罩内容，
    // 一旦那层 layer 的 alpha 被系统复位（surface 重建、窗口 relayout、从后台回来
    // 都会发生），不透明内容就直接盖在前台界面上 —— 用户看到的是「正在用着 App，
    // 界面突然被糊住」，等于把 App 用废了。而且它换来的后台命中率也没提升。
    private var maskView: PrivacyMaskView? = null

    // 最近一张「当前画面」的缩小模糊图。模糊之后新旧几乎看不出差别，
    // 所以哪怕用的是上一次的缓存，观感也不受影响 —— 但一定不是一块纯色板。
    private var lastSnapshot: Bitmap? = null

    // PixelCopy 是异步的，禁止并发抓，否则会白白多申请几张 Bitmap。
    private var capturing = false

    // onResume 后补抓快照的延时任务，重复 onResume 时先撤掉旧的，避免堆积。
    private val snapshotTask = Runnable { refreshSnapshot() }

    /**
     * 后台隐私的**唯一可靠手段**。分两条路，都是系统级的，都不依赖 App 渲染任何一帧。
     *
     * ## Android 13+（API 33）：`setRecentsScreenshotEnabled(false)`
     * 这是 `ActivityRecord` 上的**持久标记**：系统在把 Activity 置为 stopped 时，
     * 看这个标记决定要不要拍快照 —— 不拍的话最近任务显示「应用图标卡片」。
     * 关键好处是**不需要抢 onPause 的时机**（标记一直挂着），而且
     * **不影响截屏、录屏、投屏**（连后台都不影响）。
     *
     * ## Android 12 及以下：`FLAG_SECURE`
     * 窗口属性，系统抓图时自己判断，带 flag 的窗口直接出黑帧，
     * 代价是最近任务显示空白卡片，且后台期间无法截屏/录屏。
     * 必须**只在后台加、回前台清** —— 常开会让前台截屏也变黑。
     *
     * 两条路的共同点：都在系统层判定，上滑手势、返回键、Home、锁屏任何路径都拦得住。
     * 这一点「App 自己画遮罩」永远做不到（要等 vsync + 合成，系统那条路抓得更早，
     * 前前后后试了五种方案都被证明抢不到时机）。
     */
    private fun applyPrivacyFlag() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // 跟着开关走就行，不需要看 foreground：它只影响「本 Activity 被 stop 时拍不拍」，
            // 前台正在使用时根本没有快照行为，也就不会影响用户截屏。
            setRecentsScreenshotEnabled(!privacyEnabled)
            return
        }
        val hide = !foreground && privacyEnabled
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        if (hide) {
            window.addFlags(flag)
        } else {
            window.clearFlags(flag)
        }
    }

    // 是否还需要那层「视觉遮罩」。
    //
    // Android 13+ 用 setRecentsScreenshotEnabled(false)，系统根本不拍快照，
    // 遮罩画了也进不了任何东西 —— 反而多一条「误亮把前台糊住」的风险路径。
    // 所以 13+ 完全关掉视觉层，只留系统标记；12 及以下才需要它做 FLAG_SECURE 之外的兜底。
    private val needsVisualMask: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU

    /** 首次进入前台时把遮罩挂上，之后一直常驻，只在进出后台时切 alpha。 */
    private fun attachMaskIfNeeded() {
        if (maskView != null) return
        val root = findViewById<ViewGroup>(android.R.id.content) ?: return
        val v = PrivacyMaskView(this)
        v.bindIcon(appIconDrawable)
        v.bindSnapshot(lastSnapshot)
        v.alpha = 0f
        v.isClickable = false
        v.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        try {
            root.addView(
                v,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            maskView = v
        } catch (_: Throwable) {
            // 极端情况下（窗口已销毁）忽略，不能因为遮罩失败影响正常退到后台
        }
    }

    /**
     * 亮遮罩：只是 FLAG_SECURE 之外的一层视觉补充。
     *
     * 单独用它是不行的：改 alpha 要走「等 vsync → draw → 上传 buffer → 合成」，
     * 系统抓最近任务快照基本都早于这一帧。这一点已经用四种原生方案验证过
     * （临时 addView / 常驻 View / lockCanvas 同步 post / SurfaceControl 事务）。
     * 所以真正的保障在 [applyPrivacyFlag]。
     */
    private fun showMask() {
        if (!privacyEnabled) return
        if (isFinishing || isDestroyed) return
        var v = maskView
        if (v == null) {
            // 还没挂过（理论上不会发生，onResume 已确保挂载），补救一次
            attachMaskIfNeeded()
            v = maskView
        }
        val view = v ?: return
        view.isClickable = true
        view.alpha = 1f
        view.invalidate()
    }

    private fun hideMask() {
        val v = maskView ?: return
        v.alpha = 0f
        v.isClickable = false
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // 窗口拿到焦点 = 用户正在看这个界面，任何遮罩都必须撤掉。
        // 这是最后一层保险：只要前台被遮一下，就是不可接受的故障。
        if (hasFocus) hideMask()
    }

    /**
     * 抓一张当前画面 → 模糊 → 存成遮罩底图。
     *
     * 必须用 PixelCopy 直接读 Flutter SurfaceView 的 buffer：
     * SurfaceView 的内容不在 View.draw 里，decorView.draw() 只能画出一个洞，
     * 拿不到真实的界面像素。
     */
    private fun refreshSnapshot() {
        if (!privacyEnabled || isFinishing || isDestroyed) return
        if (capturing) return
        val sv = findFlutterSurfaceView() ?: return
        val vw = sv.width
        val vh = sv.height
        if (vw <= 0 || vh <= 0) return

        // 降到 1/6 宽再放大铺满：放大本身就是一次强低通滤波，
        // 模糊成本也降到几乎为零（小图 2~4ms）。
        val tw = (vw / 6).coerceIn(48, 360)
        val th = (tw * vh / vw).coerceAtLeast(1)
        val bmp = try {
            Bitmap.createBitmap(tw, th, Bitmap.Config.ARGB_8888)
        } catch (_: Throwable) {
            return
        }

        capturing = true
        try {
            PixelCopy.request(
                sv,
                bmp,
                { result ->
                    capturing = false
                    if (result == PixelCopy.SUCCESS && !isDestroyed) {
                        ImageBlur.blur(bmp, 6)
                        val old = lastSnapshot
                        lastSnapshot = bmp
                        maskView?.bindSnapshot(bmp)
                        old?.takeIf { it !== bmp }?.recycle()
                    } else {
                        bmp.recycle()
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (_: Throwable) {
            // 个别机型 / Surface 已失效时 PixelCopy 会抛，直接放弃这一轮，
            // 遮罩继续用上一张缓存图或渐变兜底。
            capturing = false
            bmp.recycle()
        }
    }

    /** Flutter 默认用 FlutterSurfaceView 渲染，它的子 View 里就是这个 SurfaceView。 */
    private fun findFlutterSurfaceView(): SurfaceView? {
        val root = window?.decorView as? ViewGroup ?: return null
        return findSurface(root)
    }

    private fun findSurface(v: View): SurfaceView? {
        if (v is SurfaceView && v.visibility == View.VISIBLE) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                val hit = findSurface(v.getChildAt(i))
                if (hit != null) return hit
            }
        }
        return null
    }

    /**
     * 用户主动离开 App（按 Home、上滑回桌面、从最近任务切走、启动别的应用）时先回调这里。
     *
     * 注意它**并不比 onPause 早**：两者是同一个 binder 消息（handlePauseActivity）
     * 里前后脚调用的，中间主线程不返回消息队列，一次 vsync 都等不到。
     * 所以这里只做一件有价值的事：趁 12- 的 FLAG_SECURE 还没加、Surface 仍可读，
     * 抓一张最新画面当遮罩底图。13+ 根本不需要遮罩，直接跳过。
     */
    override fun onUserLeaveHint() {
        if (!isFinishing && needsVisualMask) refreshSnapshot()
        super.onUserLeaveHint()
    }

    override fun onPause() {
        // 先打系统标记，再走暂停流程。
        // 这是整套方案里唯一真正关键的一步：它不渲染任何东西，只是给窗口/Activity
        // 做个标记，系统抓快照时读到就直接不拍（13+）或出黑帧（12-）。
        foreground = false
        applyPrivacyFlag()

        // Android 12 及以下才需要视觉遮罩兜底。
        // 13+ 不挂遮罩，也就不存在「前台被遮」的任何可能。
        if (needsVisualMask) showMask()
        super.onPause()
    }

    override fun onResume() {
        // 回前台第一件事就是恢复标记（12 及以下要清 FLAG_SECURE，否则截屏全黑）
        foreground = true
        applyPrivacyFlag()
        super.onResume()
        if (!needsVisualMask) return
        attachMaskIfNeeded()
        hideMask()
        // 空闲后补一张新快照，供下一次离开时使用。800ms 是为了让首帧和
        // 页面动画都停下来，免得抓到一张过渡中的画面。
        val decor = window?.decorView ?: return
        decor.removeCallbacks(snapshotTask)
        decor.postDelayed(snapshotTask, 800)
    }

    override fun onDestroy() {
        window?.decorView?.removeCallbacks(snapshotTask)
        lastSnapshot?.recycle()
        lastSnapshot = null
        maskView = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 提前把图标取好，onPause 里直接用
        appIconDrawable = try {
            packageManager.getApplicationIcon(packageName)
        } catch (_: Throwable) {
            null
        }
        // 主进程启动时记一笔「上次是谁怎么死的」，设置页的诊断日志会读到它。
        // native 崩溃抓不到 Dart 异常，只有系统这份记录能说清原因。
        ExitReasons.capture(applicationContext)
        // 新版启动后清理更新缓存：只留当前版本的 apk，跨版本旧包和过期 .part 全删。
        // 放后台线程，别拖慢首帧；正在下载的 .part 内部会跳过。
        Thread {
            try {
                UpdateCache.cleanOnStartup(applicationContext, AppChannel.currentVersionName(applicationContext))
            } catch (_: Throwable) {
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 后台隐私保护开关：Dart 侧启动时、以及设置页切换时把 privacyMask 推过来。
        // 遮罩本身是常驻的原生 View（见 PrivacyMaskView），这里只同步开关状态，
        // 不需要把图标光栅化成 PNG 传给 Dart —— 那边已经不画遮罩了。
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    privacyEnabled = call.argument<Boolean>("enabled") ?: true
                    // 开关改动要立刻反映到窗口 flag 上（此调用永远发生在前台）
                    applyPrivacyFlag()
                    // 关掉开关时如果正遮着，立刻撤掉，别等下一次 onResume
                    if (!privacyEnabled) hideMask()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 图片分块 / 压缩通道。长截图必须走这里：
        // Dart 侧整图解码一张 1080×12000 的图要 50MB，
        // 叠上编码缓冲就会被系统直接 kill（表现为闪退、日志空白）。
        MethodChannel(messenger, ImagingChannel.NAME).setMethodCallHandler { call, result ->
            ImagingChannel.handle(call, result)
        }

        // 文字识别通道。真正的识别在 :ocr 独立进程里跑，
        // 那边就算被 native 崩溃带走，主 App 也能活着弹「手动填」。
        MethodChannel(messenger, OcrBridge.CHANNEL).setMethodCallHandler { call, result ->
            OcrBridge.handle(call, result, applicationContext)
        }

        // App 自身信息通道：读版本号、后台下载更新、打开下载链接（退路）。
        // 这里传 this（Activity）而不是 applicationContext：Android 13+ 申请
        // 通知权限必须有一个真实 Activity 作为上下文。
        MethodChannel(messenger, AppChannel.NAME).setMethodCallHandler { call, result ->
            AppChannel.handle(call, result, this)
        }

        // 下载进度流。下载服务在后台线程跑完就往这里推，
        // 页面随时可以订阅/退订，退出页面不会中断下载。
        EventChannel(messenger, AppChannel.UPDATE_EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var off: (() -> Unit)? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events == null) return
                    off = UpdateDownloadController.listen { state ->
                        events.success(UpdateDownloadController.toMap(state))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    off?.invoke()
                    off = null
                }
            }
        )
    }
}
