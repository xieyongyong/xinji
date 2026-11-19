package com.xinji.payslip

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
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
    }

    // 后台隐私保护是否开启（对应设置里的「后台隐藏内容」）。默认开，和 Dart 默认值一致。
    @Volatile
    private var privacyEnabled = true

    // 当前 Activity 是否在前台。FLAG_SECURE 只在后台加，前台清掉以保留截屏/录屏能力。
    private var foreground = true

    // 切后台时给窗口加 FLAG_SECURE：系统拍「最近任务」缩略图、截屏、录屏时
    // 只能拍到黑屏。这是系统级行为，不依赖 Flutter 渲染任何一帧，
    // 所以既不会出现「后台没盖住」，也不会有「回前台闪一下遮罩」。
    private fun applyPrivacyFlag() {
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        if (!foreground && privacyEnabled) {
            window.addFlags(flag)
        } else {
            window.clearFlags(flag)
        }
    }

    override fun onPause() {
        foreground = false
        applyPrivacyFlag()
        super.onPause()
    }

    override fun onResume() {
        foreground = true
        applyPrivacyFlag()
        super.onResume()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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

    // 把应用图标 Drawable 光栅化成 PNG 字节。遮罩要在进后台前就画好，
    // 所以图由 Dart 在启动时预取缓存，这里只负责产出字节。
    private fun appIconPng(): ByteArray {
        val d = packageManager.getApplicationIcon(packageName)
        val bmp: Bitmap = if (d is BitmapDrawable && d.bitmap != null) {
            d.bitmap
        } else {
            val w = d.intrinsicWidth.coerceAtLeast(1)
            val h = d.intrinsicHeight.coerceAtLeast(1)
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            d.setBounds(0, 0, w, h)
            d.draw(c)
            b
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 后台隐私保护开关：Dart 侧设置变更/启动时把 privacyMask 推过来。
        // onPause 之前就能拿到值，切后台时 applyPrivacyFlag 即可正确加/不加 flag。
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    privacyEnabled = call.argument<Boolean>("enabled") ?: true
                    applyPrivacyFlag()
                    result.success(true)
                }
                // 应用图标的 PNG 字节，供 Dart 画后台遮罩中央的 logo（闭眼态）。
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
