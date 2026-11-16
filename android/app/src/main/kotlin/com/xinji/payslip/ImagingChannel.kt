package com.xinji.payslip

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `xinji/imaging` 通道。
 *
 * 只暴露三个方法，都是"一次调用、同步返回小结果"：
 * - probe    : 只读尺寸
 * - tiles    : 分块解码到临时目录
 * - compress : 归档压缩
 *
 * 所有重活（解码、缩放、编码）都在这里做完，Dart 侧只拿文件路径，
 * 不接触任何位图 —— 这是闪退问题的根治手段。
 */
object ImagingChannel {
    const val NAME = "xinji/imaging"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "probe" -> {
                    val path = call.argument<String>("path")
                        ?: throw IllegalArgumentException("缺少 path")
                    result.success(SlipImaging.probe(path))
                }

                "tiles" -> {
                    val path = call.argument<String>("path")
                        ?: throw IllegalArgumentException("缺少 path")
                    val outDir = call.argument<String>("outDir")
                        ?: throw IllegalArgumentException("缺少 outDir")
                    result.success(
                        SlipImaging.tiles(
                            path = path,
                            tileHeight = call.argument<Int>("tileHeight") ?: 1400,
                            overlap = call.argument<Int>("overlap") ?: 120,
                            maxWidth = call.argument<Int>("maxWidth") ?: 1600,
                            quality = call.argument<Int>("quality") ?: 92,
                            outDir = outDir,
                            tag = call.argument<String>("tag") ?: "tile"
                        )
                    )
                }

                "compress" -> {
                    val src = call.argument<String>("src")
                        ?: throw IllegalArgumentException("缺少 src")
                    val dest = call.argument<String>("dest")
                        ?: throw IllegalArgumentException("缺少 dest")
                    result.success(
                        SlipImaging.compress(
                            src = src,
                            dest = dest,
                            maxWidth = call.argument<Int>("maxWidth") ?: 1600,
                            maxPixels = (call.argument<Int>("maxPixels")
                                ?: 12_000_000).toLong(),
                            quality = call.argument<Int>("quality") ?: 88
                        )
                    )
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // 任何原生异常都变成 Flutter 侧的异常，让它能弹提示而不是闪退
            result.error("imaging_failed", t.message ?: t.toString(), null)
        }
    }
}
