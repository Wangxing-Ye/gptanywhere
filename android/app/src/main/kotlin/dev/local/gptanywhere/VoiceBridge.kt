package dev.local.gptanywhere

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.math.roundToInt

class VoiceBridge :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener,
    AudioManager.OnAudioFocusChangeListener {
    private var channel: MethodChannel? = null
    private var events: EventChannel.EventSink? = null
    private var binding: ActivityPluginBinding? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val recording = AtomicBoolean(false)
    private var recorder: AudioRecord? = null
    private var pendingStart: MethodChannel.Result? = null
    private var maxMs = MAX_RECORD_MS
    private var interrupted = false
    private var focusRequest: AudioFocusRequest? = null
    private var player: MediaPlayer? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, METHOD).also {
            it.setMethodCallHandler(this)
        }
        EventChannel(binding.binaryMessenger, EVENTS).setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        events = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        recording.set(false)
        detach()
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startRecording" -> {
                maxMs = min(call.argument<Int>("maxMs") ?: MAX_RECORD_MS, MAX_RECORD_MS)
                val host = binding?.activity
                if (host == null) {
                    result.error("modelLoadFailed", "录音没有准备好。", null)
                    return
                }
                if (ActivityCompat.checkSelfPermission(host, Manifest.permission.RECORD_AUDIO) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    pendingStart = result
                    ActivityCompat.requestPermissions(
                        host,
                        arrayOf(Manifest.permission.RECORD_AUDIO),
                        REQUEST_PERMISSION,
                    )
                    return
                }
                begin(result)
            }
            "stopRecording" -> {
                recording.set(false)
                result.success(null)
            }
            "decode" -> {
                val path = call.argument<String>("path")
                val limit = call.argument<Int>("maxMs") ?: MAX_IMPORT_MS
                if (path == null) {
                    result.error("file_corrupt", "这段音频无法读取。", null)
                    return
                }
                executor.execute {
                    try {
                        val wav = decodeToWav(File(path), limit)
                        onMain { result.success(wav) }
                    } catch (_: LongAudio) {
                        onMain {
                            result.error("tooLong", "这段音频超过 60 秒，这一版还不分段。", null)
                        }
                    } catch (_: Exception) {
                        onMain { result.error("file_corrupt", "这段音频无法读取。", null) }
                    }
                }
            }
            "play" -> playWav(call.argument<ByteArray>("wav"), result)
            "stopPlayback" -> {
                stopPlayer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun playWav(bytes: ByteArray?, result: MethodChannel.Result) {
        val dir = binding?.activity?.cacheDir
        if (bytes == null || bytes.isEmpty() || dir == null) {
            result.error("file_corrupt", "这段音频无法读取。", null)
            return
        }
        executor.execute {
            try {
                val file = File(dir, "ta_chat_play.wav")
                file.writeBytes(bytes)
                onMain {
                    try {
                        stopPlayer()
                        val created = MediaPlayer()
                        created.setDataSource(file.absolutePath)
                        created.setOnCompletionListener { stopPlayer() }
                        created.prepare()
                        created.start()
                        player = created
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("file_corrupt", "这段音频无法读取。", null)
                    }
                }
            } catch (_: Exception) {
                onMain { result.error("file_corrupt", "这段音频无法读取。", null) }
            }
        }
    }

    private fun stopPlayer() {
        val current = player
        player = null
        if (current == null) return
        current.setOnCompletionListener(null)
        try {
            current.stop()
        } catch (_: Exception) {
            // The player may not have started.
        }
        current.release()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        val start = pendingStart
        pendingStart = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (start == null) return true
        if (granted) begin(start) else start.error("permissionDenied", "没有获得使用麦克风的权限。", null)
        return true
    }

    override fun onAudioFocusChange(focusChange: Int) {
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS ||
            focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        ) {
            interrupted = true
            recording.set(false)
        }
    }

    private fun begin(result: MethodChannel.Result) {
        val host = binding?.activity
        if (host == null) {
            result.error("modelLoadFailed", "录音没有准备好。", null)
            return
        }
        if (!requestFocus(host.getSystemService(AudioManager::class.java))) {
            result.error("audioInterrupted", "录音被打断。", null)
            return
        }
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            result.error("file_corrupt", "麦克风无法打开。", null)
            return
        }
        val record = AudioRecord(
            android.media.MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            minBuffer * 2,
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            result.error("file_corrupt", "麦克风无法打开。", null)
            return
        }
        recorder = record
        interrupted = false
        recording.set(true)
        record.startRecording()
        result.success(null)
        executor.execute { capture(record, minBuffer) }
    }

    private fun capture(record: AudioRecord, minBuffer: Int) {
        val pcm = ByteArrayOutputStream()
        val buffer = ByteArray(minBuffer)
        val started = SystemClock.elapsedRealtime()
        var reachedLimit = false
        try {
            while (recording.get()) {
                val count = record.read(buffer, 0, buffer.size)
                if (count > 0) pcm.write(buffer, 0, count)
                val elapsed = (SystemClock.elapsedRealtime() - started).toInt()
                emit(mapOf("elapsedMs" to elapsed))
                if (elapsed >= maxMs) {
                    reachedLimit = true
                    recording.set(false)
                }
            }
        } finally {
            record.stop()
            record.release()
            recorder = null
            abandonFocus()
            val wav = wavBytes(pcm.toByteArray(), SAMPLE_RATE)
            emit(
                mapOf(
                    "done" to true,
                    "wav" to wav,
                    "interrupted" to interrupted,
                    "reachedLimit" to reachedLimit,
                ),
            )
        }
    }

    private fun requestFocus(manager: AudioManager): Boolean {
        return if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(this)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                this,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val host = binding?.activity ?: return
        val manager = host.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            focusRequest?.let { manager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(this)
        }
        focusRequest = null
    }

    private fun emit(payload: Map<String, Any>) {
        onMain { events?.success(payload) }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun detach() {
        stopPlayer()
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    companion object {
        private const val METHOD = "dev.local.gptanywhere/voice"
        private const val EVENTS = "dev.local.gptanywhere/voice_events"
        private const val REQUEST_PERMISSION = 4813
        private const val SAMPLE_RATE = 16000
        private const val MAX_RECORD_MS = 30000
        private const val MAX_IMPORT_MS = 60000
    }
}

private class LongAudio : Exception()

private fun decodeToWav(file: File, maxMs: Int): ByteArray {
    if (file.name.endsWith(".wav", ignoreCase = true)) {
        val parsed = readPcmWav(file)
        if (parsed != null) {
            if (parsed.durationMs > maxMs) throw LongAudio()
            return wavBytes(resampleMono(parsed.pcm, parsed.sampleRate, parsed.channels), 16000)
        }
    }
    val extractor = MediaExtractor()
    extractor.setDataSource(file.absolutePath)
    var track = -1
    var format: MediaFormat? = null
    for (index in 0 until extractor.trackCount) {
        val candidate = extractor.getTrackFormat(index)
        val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("audio/")) {
            track = index
            format = candidate
            break
        }
    }
    if (track < 0 || format == null) {
        extractor.release()
        throw IllegalStateException("no audio")
    }
    val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
        format.getLong(MediaFormat.KEY_DURATION)
    } else {
        0L
    }
    if (durationUs > maxMs * 1000L) {
        extractor.release()
        throw LongAudio()
    }
    extractor.selectTrack(track)
    val mime = format.getString(MediaFormat.KEY_MIME)!!
    val codec = MediaCodec.createDecoderByType(mime)
    codec.configure(format, null, null, 0)
    codec.start()
    val info = MediaCodec.BufferInfo()
    val pcm = ByteArrayOutputStream()
    var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    var inputDone = false
    try {
        while (true) {
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val input = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(input, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val outIndex = codec.dequeueOutputBuffer(info, 10_000)
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val out = codec.outputFormat
                    sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
                outIndex >= 0 -> {
                    val output = codec.getOutputBuffer(outIndex)!!
                    val chunk = ByteArray(info.size)
                    output.position(info.offset)
                    output.limit(info.offset + info.size)
                    output.get(chunk)
                    pcm.write(chunk)
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    } finally {
        codec.stop()
        codec.release()
        extractor.release()
    }
    return wavBytes(resampleMono(pcm.toByteArray(), sampleRate, channels), 16000)
}

private class ParsedWav(
    val pcm: ByteArray,
    val sampleRate: Int,
    val channels: Int,
    val durationMs: Int,
)

private fun readPcmWav(file: File): ParsedWav? {
    val bytes = file.readBytes()
    if (bytes.size < 44) return null
    if (String(bytes, 0, 4) != "RIFF" || String(bytes, 8, 4) != "WAVE") return null
    val view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    var offset = 12
    var audioFormat = 1
    var channels = 1
    var sampleRate = 16000
    var data: ByteArray? = null
    while (offset + 8 <= bytes.size) {
        val id = String(bytes, offset, 4)
        val size = view.getInt(offset + 4)
        val start = offset + 8
        if (start + size > bytes.size) return null
        if (id == "fmt " && size >= 16) {
            audioFormat = view.getShort(start).toInt()
            channels = view.getShort(start + 2).toInt()
            sampleRate = view.getInt(start + 4)
        } else if (id == "data") {
            data = bytes.copyOfRange(start, start + size)
        }
        offset = start + size + if (size % 2 != 0) 1 else 0
    }
    if (audioFormat != 1 || data == null || channels <= 0) return null
    val durationMs = data.size * 1000 / (sampleRate * channels * 2).coerceAtLeast(1)
    return ParsedWav(data, sampleRate, channels, durationMs)
}

private fun resampleMono(pcm: ByteArray, sampleRate: Int, channels: Int): ByteArray {
    if (sampleRate <= 0 || channels <= 0 || pcm.size < 2) return ByteArray(0)
    val frameCount = pcm.size / (2 * channels)
    val input = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN)
    val mono = ShortArray(frameCount)
    for (frame in 0 until frameCount) {
        var sum = 0
        for (channel in 0 until channels) {
            sum += input.short.toInt()
        }
        mono[frame] = (sum / channels).toShort()
    }
    if (sampleRate == 16000) {
        val out = ByteArray(mono.size * 2)
        ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(mono)
        return out
    }
    val outCount = (mono.size.toLong() * 16000 / sampleRate).toInt().coerceAtLeast(1)
    val out = ByteArray(outCount * 2)
    val shorts = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
    for (index in 0 until outCount) {
        val position = index.toDouble() * sampleRate / 16000.0
        val left = position.toInt().coerceIn(0, mono.lastIndex)
        val right = (left + 1).coerceAtMost(mono.lastIndex)
        val fraction = position - left
        val mixed = mono[left] * (1 - fraction) + mono[right] * fraction
        shorts.put(index, mixed.roundToInt().toShort())
    }
    return out
}

private fun wavBytes(pcm: ByteArray, sampleRate: Int): ByteArray {
    val header = ByteArray(44)
    val view = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
    header[0] = 'R'.code.toByte()
    header[1] = 'I'.code.toByte()
    header[2] = 'F'.code.toByte()
    header[3] = 'F'.code.toByte()
    view.putInt(4, 36 + pcm.size)
    header[8] = 'W'.code.toByte()
    header[9] = 'A'.code.toByte()
    header[10] = 'V'.code.toByte()
    header[11] = 'E'.code.toByte()
    header[12] = 'f'.code.toByte()
    header[13] = 'm'.code.toByte()
    header[14] = 't'.code.toByte()
    header[15] = ' '.code.toByte()
    view.putInt(16, 16)
    view.putShort(20, 1)
    view.putShort(22, 1)
    view.putInt(24, sampleRate)
    view.putInt(28, sampleRate * 2)
    view.putShort(32, 2)
    view.putShort(34, 16)
    header[36] = 'd'.code.toByte()
    header[37] = 'a'.code.toByte()
    header[38] = 't'.code.toByte()
    header[39] = 'a'.code.toByte()
    view.putInt(40, pcm.size)
    return header + pcm
}
