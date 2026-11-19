package com.xinji.payslip

import android.graphics.Bitmap
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
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

    // 预取的应用图标：onPause 里现读 PackageManager 会拖慢遮罩上屏。
    private var appIconDrawable: Drawable? = null

    // 遮罩只有一个实现：常驻的普通 View，平时 alpha = 0。
    //
    // 这里曾经并行挂过一个 ZOrderOnTop 的 SurfaceView，用 SurfaceControl 事务切
    // layer alpha 来实现「零等待」。它的 buffer 里必须一直放着不透明遮罩内容，
    // 一旦那层 layer 的 alpha 被系统复位（surface 重建、窗口 relayout、从后台回来
    // 都会发生），不透明内容就直接盖在前台界面上 —— 用户看到的是「正在用着 App，
    // 界面突然被糊住」，等于把 App 用废了。而它换来的后台命中率也没提升
    // （全面屏上滑回桌面依旧不生效），收益为负，整段已移除。
    private var maskView: PrivacyMaskView? = null

    // 最近一张「当前画面」的缩小模糊图。模糊之后新旧几乎看不出差别，
    // 所以哪怕用的是上一次的缓存，观感也不受影响 —— 但一定不是一块纯色板。
    private var lastSnapshot: Bitmap? = null

    // PixelCopy 是异步的，禁止并发抓，否则会白白多申请几张 Bitmap。
    private var capturing = false

    // onResume 后补抓快照的延时任务，重复 onResume 时先撤掉旧的，避免堆积。
    private val snapshotTask = Runnable { refreshSnapshot() }

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
     * 亮遮罩：只切 alpha。
     *
     * 说清楚能力边界：改 alpha 要走「等 vsync → draw → 上传 buffer → 合成」，
     * 系统抓最近任务快照基本都早于这一帧，所以**它不保证一定拍得到**。
     * 之前试过的四条更激进的路（临时 addView / 常驻 View / lockCanvas 同步 post /
     * SurfaceControl 事务切 layer alpha）要么同样失效，要么在前台把界面糊住，
     * 都已回退。现在选择的是「宁可偶尔漏拍，也绝不影响正常使用」。
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
     * 所以这里只是「顺手把遮罩亮起来」，真正的机会和限制都写在 [showMask] 的注释里。
     */
    override fun onUserLeaveHint() {
        if (!isFinishing) {
            showMask()
            refreshSnapshot()
        }
        super.onUserLeaveHint()
    }

    override fun onPause() {
        // 兜底：锁屏、按返回退出等场景不触发 onUserLeaveHint。
        // 此时贴的可能是上一张缓存图，糊掉之后看不出新旧，不影响观感。
        showMask()
        refreshSnapshot()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
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
