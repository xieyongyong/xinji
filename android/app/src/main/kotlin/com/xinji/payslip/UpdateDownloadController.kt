package com.xinji.payslip

import java.util.concurrent.CopyOnWriteArrayList

/**
 * 下载状态的进程内广播站。
 *
 * 下载服务在后台线程跑，Flutter 页面通过 EventChannel 订阅这里的状态。
 * 两者不直接互相持有：页面退到后台、被回收都没关系，服务照常下载，
 * 页面回来时 [listen] 会立刻收到当前状态。
 */
object UpdateDownloadController {
    const val IDLE = "idle"
    const val DOWNLOADING = "downloading"
    const val DONE = "done"
    const val FAILED = "failed"
    const val CANCELLED = "cancelled"

    data class State(
        val status: String = IDLE,
        val progress: Int = 0,
        val received: Long = 0,
        val total: Long = 0,
        val version: String = "",
        val path: String? = null,
        val error: String? = null,
    )

    @Volatile
    private var currentState: State = State()

    val state: State get() = currentState

    private val listeners = CopyOnWriteArrayList<(State) -> Unit>()

    /** 注册监听并立刻推送一次当前状态；返回的闭包用于反注册 */
    fun listen(listener: (State) -> Unit): () -> Unit {
        listeners.add(listener)
        try {
            listener(currentState)
        } catch (_: Throwable) {
        }
        return { listeners.remove(listener) }
    }

    fun publish(state: State) {
        currentState = state
        for (l in listeners) {
            try {
                l(state)
            } catch (_: Throwable) {
                // 一个页面 disposed 了不能影响下载本身
            }
        }
    }

    fun toMap(s: State): Map<String, Any?> = mapOf(
        "status" to s.status,
        "progress" to s.progress,
        "received" to s.received,
        "total" to s.total,
        "version" to s.version,
        "path" to s.path,
        "error" to s.error,
    )
}
