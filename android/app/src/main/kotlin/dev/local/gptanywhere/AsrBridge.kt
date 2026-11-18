package dev.local.gptanywhere

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

class AsrBridge(
    private val activity: FlutterActivity,
) : EventChannel.StreamHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val stderrExecutor = Executors.newSingleThreadExecutor()
    private val currentTask = AtomicReference<String?>(null)
    private val processRef = AtomicReference<Process?>(null)
    private var events: EventChannel.EventSink? = null
    private var extractEvents: EventChannel.EventSink? = null

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
                "extract" -> {
                    val args = call.arguments as Map<*, *>
                    executor.execute {
                        try {
                            extract(args)
                            activity.runOnUiThread { result.success(null) }
                        } catch (error: Exception) {
                            Log.e(TAG, "extract failed", error)
                            activity.runOnUiThread {
                                result.error("file_corrupt", "听写模型无法解压。", null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, EXTRACT_EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    extractEvents = sink
                }

                override fun onCancel(arguments: Any?) {
                    extractEvents = null
                }
            },
        )
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun start(args: Map<*, *>) {
        val taskId = args["taskId"] as String
        cancel(currentTask.get())
        currentTask.set(taskId)
        executor.execute { runProcess(taskId, args) }
    }

    private fun cancel(taskId: String?) {
        if (taskId == null || currentTask.get() != taskId) return
        currentTask.set(null)
        processRef.getAndSet(null)?.let {
            it.destroy()
            if (android.os.Build.VERSION.SDK_INT >= 26) it.destroyForcibly()
        }
    }

    private fun runProcess(taskId: String, args: Map<*, *>) {
        val engine = args["engine"] as String
        val modelPath = args["modelPath"] as String
        val language = args["language"] as String
        val wavPath = args["wavPath"] as String
        val tokensPath = args["tokensPath"] as String?
        val whisper = engine == "whisper"
        if (modelPath.substringAfterLast('/').lowercase().let {
                it.contains(".en.") || it.endsWith(".en") || it.endsWith(".en.bin")
            }
        ) {
            finish(taskId, error = "不能使用英文专用听写权重。", errorType = "languageUnsupported")
            return
        }
        val binaryName = if (whisper) "libwhisper_cli.so" else "libsherpa_offline.so"
        val binary = File(activity.applicationInfo.nativeLibraryDir, binaryName)
        if (!binary.exists()) {
            finish(taskId, error = "听写程序不在安装包里。", errorType = "modelLoadFailed")
            return
        }
        val command = when (engine) {
            "whisper" -> listOf(
                binary.absolutePath,
                "-m",
                modelPath,
                "-l",
                language,
                "-f",
                wavPath,
                "-nt",
                "-t",
                "4",
            )
            "qwen3Asr" -> {
                val convPath = args["convPath"] as String?
                val encoderPath = args["encoderPath"] as String?
                val decoderPath = args["decoderPath"] as String?
                val tokenizerPath = args["tokenizerPath"] as String?
                if (convPath.isNullOrEmpty() ||
                    encoderPath.isNullOrEmpty() ||
                    decoderPath.isNullOrEmpty() ||
                    tokenizerPath.isNullOrEmpty()
                ) {
                    finish(taskId, error = "听写模型还没有准备好。", errorType = "modelMissing")
                    return
                }
                listOf(
                    binary.absolutePath,
                    "--qwen3-asr-conv-frontend=$convPath",
                    "--qwen3-asr-encoder=$encoderPath",
                    "--qwen3-asr-decoder=$decoderPath",
                    "--qwen3-asr-tokenizer=$tokenizerPath",
                    "--qwen3-asr-max-new-tokens=512",
                    "--num-threads=4",
                    wavPath,
                )
            }
            else -> {
                if (tokensPath.isNullOrEmpty()) {
                    finish(taskId, error = "听写模型还没有准备好。", errorType = "modelMissing")
                    return
                }
                listOf(
                    binary.absolutePath,
                    "--tokens=$tokensPath",
                    "--sense-voice-model=$modelPath",
                    "--sense-voice-language=$language",
                    "--num-threads=4",
                    wavPath,
                )
            }
        }
        try {
            val process = ProcessBuilder(command).redirectErrorStream(false).start()
            processRef.set(process)
            process.outputStream.close()
            stderrExecutor.execute { process.errorStream.readBytes() }
            val text = process.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            if (currentTask.get() != taskId) return
            val exit = process.waitFor()
            if (currentTask.get() != taskId) return
            if (exit != 0) {
                finish(taskId, error = "听写程序退出码 $exit", errorType = "modelLoadFailed")
            } else {
                emit(
                    taskId,
                    mapOf(
                        "taskId" to taskId,
                        "chunk" to text,
                        "done" to true,
                        "json" to !whisper,
                    ),
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "asr process failed", error)
            finish(taskId, error = "听写没有启动。", errorType = "modelLoadFailed")
        } finally {
            processRef.set(null)
        }
    }

    private fun extract(args: Map<*, *>) {
        val archive = File(args["archive"] as String)
        val destination = File(args["destination"] as String)
        val names = (args["names"] as List<*>).map { File(it as String).name }.toSet()
        val expected = (args["expectedBytes"] as? Number)?.toLong() ?: -1L
        val allowed = listOf(activity.filesDir, activity.cacheDir).map { it.canonicalPath }
        val destPath = destination.canonicalPath
        if (allowed.none { destPath == it || destPath.startsWith("$it/") }) {
            throw SecurityException("destination")
        }
        synchronized(extractGate) {
            destination.mkdirs()
            val model = File(destination, "model.onnx")
            val tokens = File(destination, "tokens.txt")
            if (expected > 0 && model.length() == expected && tokens.length() > 0L) {
                reportExtract(model.length())
                return
            }
            if (model.exists()) model.delete()
            if (tokens.exists()) tokens.delete()
            BufferedInputStream(FileInputStream(archive), 1024 * 1024).use { input ->
                BZip2CompressorInputStream(input).use { bzip ->
                    TarArchiveInputStream(bzip).use { tar ->
                        var entry = tar.nextEntry
                        while (entry != null) {
                            val name = File(entry.name).name
                            if (!entry.isDirectory && names.contains(name) && name.isNotEmpty()) {
                                val out = File(destination, name)
                                BufferedOutputStream(FileOutputStream(out), 1024 * 1024).use { stream ->
                                    val buffer = ByteArray(256 * 1024)
                                    var written = 0L
                                    var reported = 0L
                                    while (true) {
                                        val count = tar.read(buffer)
                                        if (count < 0) break
                                        stream.write(buffer, 0, count)
                                        written += count
                                        if (name == "model.onnx" && written - reported >= 1024 * 1024) {
                                            reported = written
                                            reportExtract(written)
                                        }
                                    }
                                }
                            } else {
                                val skip = ByteArray(256 * 1024)
                                while (tar.read(skip) >= 0) {
                                    // The archive entry has to be consumed to reach the next one.
                                }
                            }
                            entry = tar.nextEntry
                        }
                    }
                }
            }
        }
    }

    private fun reportExtract(written: Long) {
        val bytes = written.toInt()
        activity.runOnUiThread {
            extractEvents?.success(mapOf("extractBytes" to bytes))
        }
    }

    private fun finish(taskId: String, error: String, errorType: String) {
        emit(
            taskId,
            mapOf(
                "taskId" to taskId,
                "done" to true,
                "error" to error,
                "errorType" to errorType,
            ),
        )
    }

    private fun emit(taskId: String, payload: Map<String, Any>) {
        activity.runOnUiThread {
            if (currentTask.get() != taskId && payload["done"] != true) return@runOnUiThread
            events?.success(payload)
        }
    }

    companion object {
        private const val METHOD = "dev.local.gptanywhere/asr"
        private const val EVENTS = "dev.local.gptanywhere/asr_events"
        private const val EXTRACT_EVENTS = "dev.local.gptanywhere/asr_extract"
        private const val TAG = "AsrBridge"
        private val extractGate = Any()
    }
}
