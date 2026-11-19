package com.xinji.payslip

import android.app.ActivityManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

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

        /** 最近任务卡片的主色（系统不拍快照时显示的那张卡）。不能用 const：toInt() 不是常量表达式 */
        private val TASK_COLOR = 0xFF23262B.toInt()

        /**
         * `onPause` 时遮罩还没就绪，最多再等几次、每次隔多久。
         * 2 × 30ms，加上 `onPause` 本身的时刻，总余量约 60ms。
         */
        private const val RELEASE_RETRIES = 2
        private const val RELEASE_RETRY_MS = 30L
    }

    // 后台隐私保护是否开启（对应设置里的「后台隐藏内容」）。默认开，和 Dart 默认值一致。
    @Volatile
    private var privacyEnabled = true

    // 本轮「遮罩是否已经画好」。
    //
    // 只在 `onResume` 里清零、在 `onPause` 里检查一次。消息本身**不触发任何放行**，
    // 只是把这个布尔翻成 true —— 于是「消息什么时候到」不再影响结果，
    // 真正的放行动作固定在 `onPause`，由原生自己掌握时机。
    //
    // 上一版这里叫 `foreground`，用来做「迟到消息」的守卫，但它有个致命误判：
    // 全面屏手势缓慢返回时，`inactive` 早于 `onPause`，遮罩放行信号正好在这个缝里
    // 到达 —— 那一刻 Activity 还是 RESUMED（foreground == true），守卫把它当成
    // 上一轮的死信丢掉，于是 `onPause` 时许可仍是 false，系统只能给白卡。
    // 手势越慢缝越大，表现为「每次返回都是白卡」。
    private var maskReady = false

    // 遮罩代数。Dart 侧每次新建遮罩 State 都带一个自增序号下来，
    // 原生只接受比它大的序号 —— 上一轮的死信序号必然 ≤ 已处理的，直接丢弃。
    // 这是比 `foreground` 布尔更精确的代际判定：它认的是「哪一次遮罩」，
    // 而不是「此刻在不在前台」。
    private var lastMaskSeq = 0

    /**
     * 后台隐私的**系统级兜底**，按版本分两条路。
     *
     * ## Android 12 及以下：`FLAG_SECURE` **常驻**
     * 以前是「onPause 加、onResume 清」，但加/清本身就有时序窗口（清早了可能
     * 撞上系统抓图），而且 `addFlags` / `clearFlags` 会触发窗口属性刷新（relayout）。
     * 低版本没有 13+ 那个精确旋钮，为一个截屏能力去赌时序不值得，所以直接锁死：
     * 开关打开期间 flag 一直挂着，最坏结果是最近任务里一张白卡。
     * 代价是低版本用户**无法截屏/录屏/投屏** —— 明确的取舍，安全优先。
     *
     * ## Android 13+：`setRecentsScreenshotEnabled`，动态闸门
     * 见 [setRecentsScreenshotAllowed]。这条路径不做任何窗口 flag 操作，
     * 避免和那个旋钮打架（会变白卡）。
     *
     * 兜底还有一层：[applyTaskDescription] 把最近任务卡片设成品牌色 + 应用图标，
     * 万一某台机器仍然不拍快照，显示出来是一张正常卡片，不是刺眼的白板。
     */
    private fun applySecureFlag() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        // 只在开关打开时挂：用户主动关掉就必须清，否则他永远截不了屏。
        if (privacyEnabled) {
            window.addFlags(flag)
        } else {
            window.clearFlags(flag)
        }
    }

    /**
     * **Android 13+ 的拍照许可闸门。** 低版本没有这个 API，静默跳过。
     *
     * `setRecentsScreenshotEnabled` 只有两个值，各有各的问题：
     * - `false`：系统一定不拍 → 最近任务永远是白卡，模糊画面永远看不到；
     * - `true` ：系统一定拍 → 遮罩那一帧没赶上就是**明文**，没有任何兜底。
     *
     * 所以这里不选死值，而是做成「默认禁止 + 遮罩就绪后放行」，但**放行点固定在
     * `onPause`**，不是「收到 Dart 消息的那一刻」：
     *   `onResume` 第一行 / 开关变更 → false（安全默认，最坏结果只是白卡）
     *   遮罩帧画完 → Dart 通过 `maskReady` 通道把 [maskReady] 置 true（只置状态）
     *   `onPause` → `if (maskReady)` 才置 true（此刻才真正允许系统拍）
     *
     * ## 为什么不能「收到消息就放行」
     * 那是上一版的写法，被一次实测否掉了：全面屏手势**缓慢**返回时，
     * `inactive` 早于 `onPause`，遮罩画完后发出的放行信号到达原生时，
     * Activity 仍然是 RESUMED —— 守卫把它判成「上一轮的迟到消息」丢弃，
     * 随后 `onPause` 时许可仍是 false，系统只能拍白卡。手势越慢缝越大。
     * 把动作挪到 `onPause` 之后，这个缝就不存在了：消息只需要「到过」，
     * 什么时候到都行。
     *
     * ## 迟到的放行怎么防
     * 靠 Dart 侧 `if (!mounted) return`（遮罩被撤掉时 State 已 dispose，
     * pending 的 async 自己就退出了）+ 消息里的单调序号 [lastMaskSeq]。
     * 序号认的是「哪一次遮罩」，比「此刻在不在前台」精确得多。
     */
    private fun setRecentsScreenshotAllowed(allowed: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        // 这里不能因为「值没变」就跳过：系统的默认值是 **允许拍**，
        // 启动时必须真的下发一次 false，否则头一次离开就是明文。
        try {
            setRecentsScreenshotEnabled(allowed)
        } catch (_: Throwable) {
            // 个别 ROM 限制该 API，失败就退回「不拍」（安全侧）
        }
    }

    /**
     * 最近任务卡片的外观兜底（Android 13+ 用）。
     *
     * 只在「系统真的一帧都没拍」时才会显示出来。设成深色底 + 应用图标 + 名称，
     * 比系统默认那张空白卡片自然得多，也不会泄露任何内容。
     */
    private fun applyTaskDescription() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            setTaskDescription(
                ActivityManager.TaskDescription("薪迹", appIconBitmap(), TASK_COLOR),
            )
        } catch (_: Throwable) {
            // 个别 ROM 对 TaskDescription 有限制，失败不影响任何功能
        }
    }

    override fun onPause() {
        // 真正离开前台的时刻 —— **放行就发生在这里**，且只发生一次。
        //
        // 为什么不在收到 Dart 消息时放行：`inactive` 早于 `onPause`，手势慢的时候
        // 放行信号会在 Activity 还是 RESUMED 时就到达，无法和「上一轮的死信」区分。
        // 放到这里，消息只需「到过」，到达时机不再影响结果。
        //
        // 没就绪就保持禁止：系统不拍 → 白卡。白卡 > 明文，这是唯一底线。
        releaseWhenReady(RELEASE_RETRIES)
        // 12- 的 FLAG_SECURE 是常驻的，这里不需要做任何事：
        // 少一次窗口属性变更，就少一个时序风险。
        super.onPause()
    }

    /**
     * 遮罩已就绪就放行；还没就绪就隔一小会儿再问一次（最多 [retries] 次）。
     *
     * 为什么需要「再问」：点返回键快速退出时，`onPause` 几乎和 Flutter 的
     * `inactive` 同时到，遮罩那两帧还没画完、[maskReady] 仍是 false。
     * 直接放弃就是白卡；等一个短间隔，通常够 Dart 把最后那一帧提交上来。
     * 系统抓快照发生在 Activity 进入 STOPPED 时，比 `onPause` 晚几十到几百毫秒，
     * 所以这点余量是有效的。
     *
     * 安全性：**只在 [maskReady] 为真时放行**。而 [maskReady] 会被 `onResume`
     * 清掉，所以万一用户在重试期间又回到前台，这里自然不会放行。
     */
    private fun releaseWhenReady(retries: Int) {
        if (!privacyEnabled) return
        if (maskReady) {
            setRecentsScreenshotAllowed(true)
            return
        }
        if (retries <= 0) return // 到点仍未就绪 → 保持禁止 → 白卡
        try {
            window.decorView.postDelayed({
                if (!isDestroyed) releaseWhenReady(retries - 1)
            }, RELEASE_RETRY_MS)
        } catch (_: Throwable) {
            // 窗口已销毁：保持禁止即可
        }
    }

    override fun onResume() {
        // **第一行、同步**：每一轮回到前台，立刻把「拍照许可」摁回禁止，
        // 并把本轮的就绪标记清掉 —— 上一轮打开的许可绝不能带进新的一轮，
        // 否则用户秒切走时，系统会在这个窗口期直接拍到没有遮罩的明文。
        setRecentsScreenshotAllowed(!privacyEnabled)
        maskReady = false
        super.onResume()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 启动即从「禁止拍」开始，等遮罩真的画出来再由 Dart 放行。
        // 12- 的 FLAG_SECURE 在这里一次性挂上，之后不再增删（常驻）。
        setRecentsScreenshotAllowed(!privacyEnabled)
        applySecureFlag()
        applyTaskDescription()
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

    // 把应用图标 Drawable 光栅化成 Bitmap。遮罩要在进后台前就画好，
    // 所以图由 Dart 在启动时预取缓存，这里只负责产出字节。
    private fun appIconBitmap(): Bitmap {
        val d = packageManager.getApplicationIcon(packageName)
        if (d is BitmapDrawable && d.bitmap != null) {
            // 不能直接返回 Drawable 里那张 Bitmap：它的所有权不在我们手上，
            // 后续 recycle 会连带把系统缓存里的图标回收掉。
            return d.bitmap.copy(Bitmap.Config.ARGB_8888, false)
        }
        // 自适应图标（Android 8+ 的默认形式，本项目就是）的 intrinsicWidth /
        // intrinsicHeight 返回的是 **-1**，不是实际像素尺寸。
        // 旧代码 `intrinsicWidth.coerceAtLeast(1)` 会得到 1×1 的位图 ——
        // 传到 Dart 再放大到 62dp，就是一块空白，表现就是「遮罩上的图标没了」。
        // 所以这里必须按屏幕密度给一个固定画布。
        val size = (resources.displayMetrics.density * 128).toInt().coerceAtLeast(96)
        val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        if (d is android.graphics.drawable.AdaptiveIconDrawable) {
            // 自适应图标在 108dp 网格里只画中间 72dp 的安全区，直接 setBounds
            // 会白白留一圈内边距 —— 放到遮罩的圆盘里会显得小一号。
            // 放大 1.5 倍（108/72）再居中，超出画布的部分由 Canvas 自动裁掉。
            val over = (size * 1.5f).toInt()
            val off = -(over - size) / 2
            d.setBounds(off, off, off + over, off + over)
        } else {
            d.setBounds(0, 0, size, size)
        }
        d.draw(c)
        return b
    }

    private fun appIconPng(): ByteArray {
        val out = ByteArrayOutputStream()
        appIconBitmap().compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 后台隐私保护开关：Dart 侧启动时、以及设置页切换时把 privacyMask 推过来。
        // 开关状态缓存在 privacyEnabled，供 12- 的常驻 FLAG_SECURE 和 13+ 的闸门读取。
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    privacyEnabled = call.argument<Boolean>("enabled") ?: true
                    // 开关变了就从「禁止拍」重新开始（关掉开关则直接允许拍）
                    setRecentsScreenshotAllowed(!privacyEnabled)
                    // 开关是一次状态重置，把本轮的就绪标记一并清掉，
                    // 免得旧状态带进下一次离开。
                    maskReady = false
                    applySecureFlag()
                    result.success(true)
                }
                // Dart 侧确认「遮罩那一帧已经画完」——**只置状态，不做任何动作**。
                // 真正的放行在 `onPause` 里，见 setRecentsScreenshotAllowed 的说明。
                //
                // 带 `seq` 是为了丢弃上一轮的迟到消息：Dart 每次新建遮罩 State
                // 都会带一个自增序号，这里只认比 [lastMaskSeq] 大的。
                // 比 `foreground` 布尔精确 —— 它认「哪一次遮罩」，不是「此刻在不在前台」。
                "maskReady" -> {
                    val seq = call.argument<Int>("seq") ?: 0
                    if (seq > lastMaskSeq) {
                        lastMaskSeq = seq
                        maskReady = true
                        result.success(true)
                    } else {
                        result.success(false) // 上一轮的死信，丢弃
                    }
                }
                // 应用图标的 PNG 字节，供 Dart 画后台遮罩中央的 logo。
                "appIcon" -> {
                    try {
                        result.success(appIconPng())
                    } catch (t: Throwable) {
                        result.error("app_icon_failed", t.message, null)
                    }
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
