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
    }

    // 后台隐私保护是否开启（对应设置里的「后台隐藏内容」）。默认开，和 Dart 默认值一致。
    @Volatile
    private var privacyEnabled = true

    // 当前 Activity 是否在前台。FLAG_SECURE 只在后台加，前台清掉以保留截屏/录屏能力。
    private var foreground = true

    /**
     * **Android 13+ 的拍照许可闸门。**
     *
     * `setRecentsScreenshotEnabled` 只有两个值，各有各的问题：
     * - `false`：系统一定不拍 → 最近任务永远是白卡，模糊画面永远看不到；
     * - `true` ：系统一定拍 → 遮罩那一帧没赶上就是**明文**，没有任何兜底。
     *
     * 所以这里不选死值，而是做成「默认禁止 + 画完再放行」：
     *   onResume / 开关变更 → 置 false（安全默认，最坏结果只是白卡）
     *   遮罩帧真正 raster 完成 → Dart 通过 `maskVisible` 通道置 true（才允许拍）
     *   onPause → **不动它**（动了就会把 Dart 刚打开的许可立刻关掉，等于永远白卡）
     *
     * 系统的判断发生在 Activity 进入 STOPPED 时，晚于 Flutter 的 `inactive`，
     * 所以「画完再放行」这个顺序是成立的。
     */
    @Volatile
    private var recentsScreenshotAllowed = false

    /**
     * 后台隐私的**系统级兜底**，按版本分两条路。
     *
     * ## Android 12 及以下：`FLAG_SECURE`
     * 窗口属性。`onPause` 加、`onResume` 清，系统抓图时读到 flag 出黑帧。
     * 只在后台加，所以前台截屏、录屏、投屏正常。
     *
     * ## Android 13+：`setRecentsScreenshotEnabled`，动态开关
     * 见 [recentsScreenshotAllowed]：默认禁止拍（白卡），遮罩帧画完才放行（拍到模糊）。
     * 注意这里**不能**在 `onPause` 里把它重置成 false —— 那会把 Dart 刚打开的许可
     * 立刻关掉，退化成「永远白卡」。重置只发生在 `onResume`。
     *
     * 兜底还有一层：[applyTaskDescription] 把最近任务卡片设成品牌色 + 应用图标，
     * 万一某台机器仍然不拍快照，显示出来是一张正常卡片，不是刺眼的白板。
     */
    private fun applyPrivacyFlag() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // 13+：这里故意什么都不做。拍照许可由 onResume / 通道单独管理，
            // 因为 onPause 时刻它可能刚被 Dart 打开（遮罩帧已画完），重置就是自毁。
            return
        }
        // 12 及以下：v2.7.0 的老办法，只在后台加
        val hide = !foreground && privacyEnabled
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        if (hide) {
            window.addFlags(flag)
        } else {
            window.clearFlags(flag)
        }
    }

    /** 13+ 的拍照许可开关。低版本没有这个 API，静默跳过。 */
    private fun setRecentsScreenshotAllowed(allowed: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        // 这里不能因为「值没变」就跳过：字段初始是 false，而系统的默认是 **允许拍**，
        // 启动时必须真的下发一次 false，否则头一次离开就是明文。
        recentsScreenshotAllowed = allowed
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
        foreground = false
        applyPrivacyFlag()
        super.onPause()
    }

    override fun onResume() {
        foreground = true
        // 每一轮回到前台都从「禁止拍」重新开始。
        // 这样下一次离开时，如果遮罩帧没赶上，系统给的是白卡而不是明文。
        setRecentsScreenshotAllowed(!privacyEnabled)
        applyPrivacyFlag()
        super.onResume()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 启动即从「禁止拍」开始，等遮罩真的画出来再由 Dart 放行
        setRecentsScreenshotAllowed(!privacyEnabled)
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
        d.setBounds(0, 0, size, size)
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
        // 开关状态在这里缓存，onPause 时才能正确决定加不加 flag。
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    privacyEnabled = call.argument<Boolean>("enabled") ?: true
                    // 开关变了就从「禁止拍」重新开始（关掉开关则直接允许拍）
                    setRecentsScreenshotAllowed(!privacyEnabled)
                    applyPrivacyFlag()
                    result.success(true)
                }
                // Dart 侧确认「遮罩那一帧已经 raster 完成」——此刻才允许系统拍快照。
                // 迟到的调用（Activity 已经 stopped）改标记已无效，无害。
                "maskVisible" -> {
                    if (privacyEnabled) setRecentsScreenshotAllowed(true)
                    result.success(privacyEnabled)
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
