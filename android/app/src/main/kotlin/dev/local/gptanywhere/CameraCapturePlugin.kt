package dev.local.gptanywhere

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Returns the captured file from the camera activity itself.
 * image_picker waits for a media-scanner callback that does not arrive on
 * this Android 9 phone, so the Flutter future never completes.
 */
class CameraCapturePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var output: File? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "takePicture") {
            result.notImplemented()
            return
        }
        val host = activity
        if (host == null) {
            result.error("camera_unavailable", "相机没有准备好。", null)
            return
        }
        if (pending != null) {
            result.error("already_active", "相机已经打开。", null)
            return
        }
        pending = result
        if (ActivityCompat.checkSelfPermission(host, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                host,
                arrayOf(Manifest.permission.CAMERA),
                REQUEST_PERMISSION,
            )
            return
        }
        launch(host)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        val host = activity
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (host != null && granted) {
            launch(host)
        } else {
            fail("camera_access_denied", "没有获得使用相机的权限。")
        }
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAMERA) return false
        val file = output
        output = null
        if (resultCode != Activity.RESULT_OK || file == null) {
            file?.delete()
            succeed(null)
            return true
        }
        val cacheDir = activity?.cacheDir
        executor.execute {
            try {
                var attempts = 0
                while (file.length() == 0L && attempts < 10) {
                    Thread.sleep(100)
                    attempts += 1
                }
                if (!file.exists() || file.length() == 0L) {
                    file.delete()
                    onMain { succeed(null) }
                    return@execute
                }
                val scaled = scale(file, cacheDir)
                file.delete()
                onMain { succeed(scaled.absolutePath) }
            } catch (_: Throwable) {
                file.delete()
                onMain { fail("file_corrupt", "这张图片无法读取。") }
            }
        }
        return true
    }

    private fun launch(host: Activity) {
        val directory = File(host.cacheDir, "camera").apply { mkdirs() }
        val file = File(directory, "${UUID.randomUUID()}.jpg")
        try {
            if (!file.createNewFile() && !file.exists()) {
                fail("file_corrupt", "这张图片无法读取。")
                return
            }
        } catch (_: IOException) {
            fail("file_corrupt", "这张图片无法读取。")
            return
        }
        output = file
        val uri = FileProvider.getUriForFile(host, "${host.packageName}.photofiles", file)
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
        intent.putExtra(MediaStore.EXTRA_OUTPUT, uri)
        intent.clipData = ClipData.newRawUri("camera", uri)
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        grantToCameraApps(host, intent, uri)
        try {
            host.startActivityForResult(intent, REQUEST_CAMERA)
        } catch (_: ActivityNotFoundException) {
            file.delete()
            output = null
            fail("no_available_camera", "没有可用的相机。")
        }
    }

    private fun grantToCameraApps(host: Activity, intent: Intent, uri: Uri) {
        val matches = host.packageManager.queryIntentActivities(
            intent,
            PackageManager.MATCH_DEFAULT_ONLY,
        )
        for (info in matches) {
            host.grantUriPermission(
                info.activityInfo.packageName,
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            main.post(block)
        }
    }

    private fun succeed(path: String?) {
        val result = pending
        pending = null
        result?.success(path)
    }

    private fun fail(code: String, message: String) {
        val result = pending
        pending = null
        result?.error(code, message, null)
    }

    private fun detachActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
    }

    private fun scale(source: File, cacheDir: File?): File {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalStateException("undecodable")
        }
        var sample = 1
        while (bounds.outWidth / sample > MAX_SIDE * 2 ||
            bounds.outHeight / sample > MAX_SIDE * 2
        ) {
            sample *= 2
        }
        val decoded = BitmapFactory.decodeFile(
            source.absolutePath,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw IllegalStateException("decode")
        val upright = orient(source, decoded)
        val longest = max(upright.width, upright.height).toFloat()
        val factor = min(1f, MAX_SIDE / longest)
        val width = max(1, (upright.width * factor).roundToInt())
        val height = max(1, (upright.height * factor).roundToInt())
        val scaled = if (width == upright.width && height == upright.height) {
            upright
        } else {
            Bitmap.createScaledBitmap(upright, width, height, true).also {
                if (it != upright) upright.recycle()
            }
        }
        val directory = File(cacheDir ?: source.parentFile, "camera").apply { mkdirs() }
        val destination = File(directory, "scaled-${source.name}")
        FileOutputStream(destination).use { stream ->
            if (!scaled.compress(Bitmap.CompressFormat.JPEG, QUALITY, stream)) {
                throw IllegalStateException("compress")
            }
        }
        scaled.recycle()
        return destination
    }

    private fun orient(source: File, bitmap: Bitmap): Bitmap {
        val degrees = when (
            ExifInterface(source.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        ) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return bitmap
        }
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true).also {
            if (it != bitmap) bitmap.recycle()
        }
    }

    companion object {
        private const val CHANNEL = "dev.local.gptanywhere/camera"
        private const val REQUEST_CAMERA = 4811
        private const val REQUEST_PERMISSION = 4812
        private const val MAX_SIDE = 1600
        private const val QUALITY = 85
    }
}
