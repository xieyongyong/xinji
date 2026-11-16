package com.xinji.payslip

import android.os.Bundle
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 主进程启动时记一笔「上次是谁怎么死的」，设置页的诊断日志会读到它。
        // native 崩溃抓不到 Dart 异常，只有系统这份记录能说清原因。
        ExitReasons.capture(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

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
