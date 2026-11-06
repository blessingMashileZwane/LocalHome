package com.pyansofyan.localhome

import android.Manifest
import android.annotation.SuppressLint
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private const val METHOD_CHANNEL = "localhome/mic"
private const val EVENT_CHANNEL = "localhome/mic_pcm16"
private const val HINEN_UI_CHANNEL = "localhome/hinen_ui"
private const val PERMISSION_REQUEST = 70401
private const val HINEN_PERMISSION_REQUEST = 70402

private const val SAMPLE_RATE_HZ = 8000
private const val CHUNK_SAMPLES = 160 // 20 ms of mono PCM16

/// Captures mono PCM16 at 8 kHz and forwards fixed 20 ms chunks to Dart.
/// Events are posted to the main thread because EventSink is not thread-safe.
class MicrophoneCapture {
    private var audioRecord: AudioRecord? = null
    private var worker: Thread? = null
    private val running = AtomicBoolean(false)
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun start(sink: EventChannel.EventSink): Boolean {
        this.sink = sink
        if (running.get()) return true
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE_HZ,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false
        val record = try {
            @SuppressLint("MissingPermission") // Dart checks permission first.
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE_HZ,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer * 2, CHUNK_SAMPLES * 8),
            )
        } catch (_: SecurityException) {
            return false
        } catch (_: UnsupportedOperationException) {
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        audioRecord = record
        running.set(true)
        worker = thread(name = "mic-capture") {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val chunkBytes = CHUNK_SAMPLES * 2
            val buffer = ByteArray(chunkBytes)
            try {
                record.startRecording()
                while (running.get()) {
                    val read = record.read(buffer, 0, buffer.size)
                    if (read <= 0) break
                    val chunk = ByteArray(read)
                    System.arraycopy(buffer, 0, chunk, 0, read)
                    mainHandler.post {
                        val target = sink
                        if (target != null && running.get()) {
                            target.success(chunk)
                        }
                    }
                }
            } finally {
                try {
                    record.stop()
                } catch (_: IllegalStateException) {
                    // Already stopped.
                }
                record.release()
            }
        }
        return true
    }

    fun stop() {
        running.set(false)
        val thread = worker
        worker = null
        thread?.join(500)
        audioRecord = null
        mainHandler.post { sink = null }
    }
}

class MainActivity : FlutterActivity() {
    private var capture: MicrophoneCapture? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingHinenPermissionResult: MethodChannel.Result? = null
    private var deepLinkChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        capture = MicrophoneCapture()
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestMicPermission(result)
                "hasPermission" -> result.success(hasMicPermission())
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, HINEN_UI_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableCard" -> requestHinenCard(result)
                "disableCard" -> {
                    HinenQuickNotifications.cancel(this)
                    result.success(true)
                }
                "addTile" -> addHinenTile(result)
                else -> result.notImplemented()
            }
        }
        deepLinkChannel = MethodChannel(messenger, "localhome/deeplink")
        Handler(Looper.getMainLooper()).postDelayed(
            { dispatchDeepLink(intent) },
            700,
        )
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events == null) return
                    val source = capture
                    if (source == null) {
                        events.error("capture", "Capture engine is not ready.", null)
                        return
                    }
                    if (!hasMicPermission()) {
                        events.error("permission", "Microphone permission is not granted.", null)
                        return
                    }
                    if (!source.start(events)) {
                        events.error("capture", "Could not start microphone capture.", null)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    capture?.stop()
                }
            },
        )
    }

    private fun hasMicPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission(result: MethodChannel.Result) {
        if (hasMicPermission()) {
            result.success(true)
            return
        }
        val pending = pendingPermissionResult
        if (pending != null) {
            result.error("busy", "A permission request is already active.", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST,
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchDeepLink(intent)
    }

    private fun dispatchDeepLink(intent: Intent?) {
        val cameraId = intent?.getStringExtra("localhome_camera_id") ?: return
        intent.removeExtra("localhome_camera_id")
        deepLinkChannel?.invokeMethod("openCamera", cameraId)
    }

    private fun requestHinenCard(result: MethodChannel.Result) {        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            val pending = pendingHinenPermissionResult
            if (pending != null) {
                result.error("busy", "A notification permission request is active.", null)
                return
            }
            pendingHinenPermissionResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                HINEN_PERMISSION_REQUEST,
            )
            return
        }
        HinenQuickNotifications.post(this)
        result.success(true)
    }

    private fun addHinenTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.error("unsupported", "Adding tiles requires Android 13 or newer.", null)
            return
        }
        val service = ComponentName(this, HinenQuickTileService::class.java)
        val icon = Icon.createWithResource(this, R.drawable.ic_localhome_tile)
        getSystemService(StatusBarManager::class.java).requestAddTileService(
            service,
            "LocalHome",
            icon,
            Executors.newSingleThreadExecutor(),
        ) { _ -> }
        result.success(true)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == HINEN_PERMISSION_REQUEST) {
            val result = pendingHinenPermissionResult
            pendingHinenPermissionResult = null
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) HinenQuickNotifications.post(this)
            result?.success(granted)
            return
        }
        if (requestCode != PERMISSION_REQUEST) return
        val result = pendingPermissionResult
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        result?.success(granted)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        capture?.stop()
        capture = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
