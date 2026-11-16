package com.xinji.payslip

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `xinji/ocr` 通道：Dart 侧的识别入口。
 *
 * 职责只有一件事 —— 把识别请求转发给独立进程里的 OcrService，
 * 再把结果原样交回 Dart。真正的识别逻辑一行都不在这里。
 *
 * ## 这一层存在的意义是「接住崩溃」
 * 服务进程被 native 崩溃带走时，bindService 的连接会断，
 * 系统回调 [ServiceConnection.onServiceDisconnected]。
 * 我们借此把「进程崩了」变成一条普通的错误信息返回给 Dart，
 * 界面就能弹「识别没成功，可以直接手动填」——
 * 而不是像以前那样整个 App 消失。
 */
object OcrBridge {
    const val CHANNEL = "xinji/ocr"

    private const val CRASH_HINT =
        "识别引擎意外退出了。这台设备的离线中文识别跑不起来，可以手动填这一张"

    /** 整体超时：超长截图 10 块也就 30 秒左右，3 分钟足够宽松 */
    private const val TIMEOUT_MS = 180_000L

    /** 连接超时：服务进程起不来（比如在 onCreate 里就崩）时不必干等 3 分钟 */
    private const val CONNECT_TIMEOUT_MS = 12_000L

    private val main = Handler(Looper.getMainLooper())

    private var pending: MethodChannel.Result? = null
    private var messenger: Messenger? = null
    private var paths: ArrayList<String> = arrayListOf()

    /** 是否在识别前刷掉浅灰水印（Dart 设置里可关） */
    private var deWatermark: Boolean = true

    /** 识别引擎（Dart 设置里可切） */
    private var engine: String = OcrService.ENGINE_PPOCR
    private var appContext: Context? = null

    private val timeoutTask = Runnable {
        finishWithError("识别超时了，这张图可能太长，可以裁成两张再导入")
    }

    private val connectTimeoutTask = Runnable {
        if (messenger == null) {
            finishWithError("识别服务没能启动，这台设备的离线识别可能被系统限制了")
        }
    }

    private val reply = Messenger(Handler(Looper.getMainLooper()) { msg ->
        if (msg.what == OcrService.MSG_RESULT) {
            finishWithSuccess(msg.data?.getString(OcrService.EXTRA_PAYLOAD))
            true
        } else {
            false
        }
    })

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            if (binder == null) {
                finishWithError("识别服务没能启动")
                return
            }
            val m = Messenger(binder)
            messenger = m
            main.removeCallbacks(connectTimeoutTask)
            val msg = Message.obtain(null, OcrService.MSG_RECOGNIZE)
            msg.data = Bundle().apply {
                putStringArrayList(OcrService.EXTRA_PATHS, paths)
                putBoolean(OcrService.EXTRA_CLEAN, deWatermark)
                putString(OcrService.EXTRA_ENGINE, engine)
            }
            msg.replyTo = reply
            try {
                m.send(msg)
            } catch (t: Throwable) {
                finishWithError("识别服务通信失败：${t.message}")
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // 服务进程没了（native 崩溃 / 被系统杀）
            finishWithError(CRASH_HINT)
        }

        override fun onBindingDied(name: ComponentName?) {
            finishWithError(CRASH_HINT)
        }
    }

    /** Dart 调用入口 */
    fun handle(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "recognize" -> {
                val list = call.argument<List<String>>("paths")
                if (list.isNullOrEmpty()) {
                    result.error("ocr_bad_args", "没有要识别的图片", null)
                    return
                }
                // 缺省为 true：老版本 Dart 传参不带这个字段也不能把去水印关掉
                val clean = call.argument<Boolean>("deWatermark") ?: true
                // 缺省 PP-OCR：没传就按新引擎跑
                val engineName = call.argument<String>("engine") ?: OcrService.ENGINE_PPOCR
                recognize(context, list, clean, engineName, result)
            }

            else -> result.notImplemented()
        }
    }

    private fun recognize(
        context: Context,
        list: List<String>,
        clean: Boolean,
        engineName: String,
        result: MethodChannel.Result
    ) {
        if (pending != null) {
            result.error("ocr_busy", "上一批还在识别，请稍等一下", null)
            return
        }
        pending = result
        paths = ArrayList(list)
        deWatermark = clean
        engine = engineName

        val ctx = context.applicationContext
        appContext = ctx
        val intent = Intent(ctx, OcrService::class.java)
        val bound = try {
            ctx.bindService(intent, conn, Context.BIND_AUTO_CREATE)
        } catch (t: Throwable) {
            false
        }
        if (!bound) {
            finishWithError("启动识别服务失败")
            return
        }
        main.postDelayed(timeoutTask, TIMEOUT_MS)
        main.postDelayed(connectTimeoutTask, CONNECT_TIMEOUT_MS)
    }

    private fun finishWithSuccess(payload: String?) {
        val result = takePending() ?: return
        if (payload == null) {
            result.error("ocr_empty", "识别没有返回结果", null)
        } else {
            result.success(payload)
        }
    }

    private fun finishWithError(message: String) {
        val result = takePending() ?: return
        result.error("ocr_failed", message, null)
    }

    /** 取走待回调并收拾干净（保证 Result 只回调一次，否则 Flutter 会抛异常） */
    private fun takePending(): MethodChannel.Result? {
        val result = pending ?: return null
        pending = null
        main.removeCallbacks(timeoutTask)
        main.removeCallbacks(connectTimeoutTask)
        messenger = null
        try {
            appContext?.unbindService(conn)
        } catch (_: Throwable) {
        }
        appContext = null
        return result
    }
}
