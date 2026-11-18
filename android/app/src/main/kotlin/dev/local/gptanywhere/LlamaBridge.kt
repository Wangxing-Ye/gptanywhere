package dev.local.gptanywhere

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

class LlamaBridge(
    private val activity: FlutterActivity,
) : EventChannel.StreamHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val stderrExecutor = Executors.newSingleThreadExecutor()
    private val currentTask = AtomicReference<String?>(null)
    private val processRef = AtomicReference<Process?>(null)
    private var events: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    start(call.arguments as Map<*, *>)
                    result.success(null)
                }
                "cancel" -> {
                    cancel(call.argument<String>("taskId"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun start(args: Map<*, *>) {
        val taskId = args["taskId"] as String
        val modelPath = args["modelPath"] as String
        val systemPrompt = args["systemPrompt"] as String
        val prompt = args["prompt"] as String
        val maxTokens = (args["maxTokens"] as Number).toInt()
        val thinking = args["thinking"] as? Boolean ?: false
        val visionPath = args["visionPath"] as? String
        val imageMaxTokens = (args["imageMaxTokens"] as? Number)?.toInt() ?: 0
        val imagePaths = (args["imagePaths"] as? List<*>)
            ?.mapNotNull { it as? String }
            .orEmpty()
        cancel(currentTask.get())
        currentTask.set(taskId)
        executor.execute {
            runProcess(
                taskId,
                modelPath,
                systemPrompt,
                prompt,
                maxTokens,
                thinking,
                visionPath,
                imagePaths,
                imageMaxTokens,
            )
        }
    }

    private fun stopProcess(process: Process) {
        process.destroy()
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            process.destroyForcibly()
        }
    }

    private fun cancel(taskId: String?) {
        if (taskId == null || currentTask.get() != taskId) return
        currentTask.set(null)
        processRef.getAndSet(null)?.let(::stopProcess)
    }

    private fun runProcess(
        taskId: String,
        modelPath: String,
        systemPrompt: String,
        prompt: String,
        maxTokens: Int,
        thinking: Boolean,
        visionPath: String?,
        imagePaths: List<String>,
        imageMaxTokens: Int,
    ) {
        val binary = File(activity.applicationInfo.nativeLibraryDir, "libllama_cli.so")
        if (!binary.exists()) {
            emit(
                taskId,
                mapOf(
                    "taskId" to taskId,
                    "done" to true,
                    "error" to "翻译程序不在安装包里。",
                    "errorType" to "modelLoadFailed",
                ),
            )
            return
        }
        val command = mutableListOf(
            binary.absolutePath,
            "-m", modelPath,
            "-c", "2048",
            "-n", maxTokens.toString(),
            "--temp", "0.2",
            "--reasoning", if (thinking) "on" else "off",
            "-t", "4",
            "--single-turn",
            "--simple-io",
            "--log-disable",
            "--no-perf",
            "-sys", systemPrompt,
            "-p", prompt,
        )
        if (!visionPath.isNullOrEmpty() && imagePaths.isNotEmpty()) {
            command.add("--mmproj")
            command.add(visionPath)
            if (imageMaxTokens > 0) {
                command.add("--image-max-tokens")
                command.add(imageMaxTokens.toString())
            }
            for (path in imagePaths) {
                command.add("--image")
                command.add(path)
            }
        }
        try {
            val process = ProcessBuilder(command)
                .redirectErrorStream(false)
                .start()
            processRef.set(process)
            process.outputStream.close()
            stderrExecutor.execute {
                process.errorStream.bufferedReader().useLines { lines ->
                    lines.forEach { Log.i(TAG, it) }
                }
            }
            val reader = process.inputStream.bufferedReader(Charsets.UTF_8)
            val buffer = CharArray(512)
            while (currentTask.get() == taskId) {
                val count = reader.read(buffer)
                if (count < 0) break
                emit(taskId, mapOf("taskId" to taskId, "chunk" to String(buffer, 0, count)))
            }
            if (currentTask.get() != taskId) {
                stopProcess(process)
                return
            }
            val exit = process.waitFor()
            if (currentTask.get() != taskId) return
            if (exit != 0) {
                emit(
                    taskId,
                    mapOf(
                        "taskId" to taskId,
                        "done" to true,
                        "error" to "翻译程序退出码 $exit",
                        "errorType" to "modelLoadFailed",
                    ),
                )
            } else {
                emit(taskId, mapOf("taskId" to taskId, "done" to true))
            }
        } catch (error: Exception) {
            Log.e(TAG, "llama process failed", error)
            emit(
                taskId,
                mapOf(
                    "taskId" to taskId,
                    "done" to true,
                    "error" to (error.message ?: "翻译没有启动。"),
                    "errorType" to "modelLoadFailed",
                ),
            )
        } finally {
            processRef.set(null)
        }
    }

    private fun emit(taskId: String, payload: Map<String, Any>) {
        activity.runOnUiThread {
            if (currentTask.get() != taskId && payload["done"] != true) return@runOnUiThread
            events?.success(payload)
        }
    }

    companion object {
        private const val METHOD = "dev.local.gptanywhere/llama"
        private const val EVENTS = "dev.local.gptanywhere/llama_events"
        private const val TAG = "LlamaBridge"
    }
}
