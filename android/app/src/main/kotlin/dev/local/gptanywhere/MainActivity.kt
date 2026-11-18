package dev.local.gptanywhere

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var llamaBridge: LlamaBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = LlamaBridge(this)
        bridge.register(flutterEngine)
        llamaBridge = bridge
        val asr = AsrBridge(this)
        asr.register(flutterEngine)
        flutterEngine.plugins.add(CameraCapturePlugin())
        flutterEngine.plugins.add(VoiceBridge())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE).setMethodCallHandler { call, result ->
            when (call.method) {
                "totalMemoryBytes" -> {
                    val info = android.app.ActivityManager.MemoryInfo()
                    val manager = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                    manager.getMemoryInfo(info)
                    result.success(info.totalMem)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val DEVICE = "dev.local.gptanywhere/device"
    }
}
