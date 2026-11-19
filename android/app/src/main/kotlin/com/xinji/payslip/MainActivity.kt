package com.xinji.payslip

import android.graphics.drawable.Drawable
import android.os.Bundle
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

    // 预取的应用图标：onPause 里现读 PackageManager 会拖慢遮罩上屏，
    // 而遮罩必须赶在系统抓「最近任务」快照之前进窗口。
    private var appIconDrawable: Drawable? = null

    // 当前挂着的遮罩。非空表示正在遮（onPause 加上、onResume 移除）。
    private var maskView: PrivacyMaskView? = null

    /**
     * 在 FlutterView 之上盖一层原生遮罩。
     *
     * 必须同步、直接在 UI 线程 addView：这是唯一能赶在系统拍照前生效的路径。
     * 不透明度和绘制成本都要压到最低（见 [PrivacyMaskView] 的说明）。
     */
    private fun showPrivacyMask() {
        if (!privacyEnabled) return
        if (isFinishing || isDestroyed) return
        if (maskView != null) return
        val root = findViewById<ViewGroup>(android.R.id.content) ?: return
        val v = PrivacyMaskView(this)
        v.bindIcon(appIconDrawable)
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

    private fun hidePrivacyMask() {
        val v = maskView ?: return
        maskView = null
        (v.parent as? ViewGroup)?.removeView(v)
    }

    override fun onPause() {
        // 放在 super 之前：super 会通知 Fragment/Flutter 走一整套暂停流程，
        // 先 addView 能把这几十毫秒省下来，留给系统拍照的窗口更早被堵住。
        showPrivacyMask()
        super.onPause()
    }

    override fun onResume() {
        hidePrivacyMask()
        super.onResume()
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
        // 遮罩本身是原生 View（见 PrivacyMaskView），在 onPause 里同步挂上，
        // 不再需要把图标光栅化成 PNG 传给 Dart —— 那边已经不画遮罩了。
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    privacyEnabled = call.argument<Boolean>("enabled") ?: true
                    // 关掉开关时如果正遮着，立刻撤掉，别等下一次 onResume
                    if (!privacyEnabled) hidePrivacyMask()
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
