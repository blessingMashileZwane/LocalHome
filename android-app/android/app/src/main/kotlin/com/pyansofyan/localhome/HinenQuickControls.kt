package com.pyansofyan.localhome

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

internal data class HinenQuickConfig(
    val name: String,
    val address: String,
    val bridgeUrl: String,
)

internal data class HinenDps(
    val battery: Int?,
    val ac: Boolean?,
    val dc: Boolean?,
    val light: Int?,
    val packs: Int?,
    val temperatureC: Int?,
    val standbySeconds: Int?,
) {
    val capacityWh: Int?
        get() = packs?.let { 2560 + it * 2560 }

    val remainingWh: Int?
        get() {
            val percent = battery ?: return null
            val capacity = capacityWh ?: return null
            return capacity * percent / 100
        }

    val lightLabel: String
        get() = when (light) {
            0 -> "Off"
            1 -> "Low"
            2 -> "Medium"
            3 -> "High"
            4 -> "SOS"
            else -> "—"
        }

    val summary: String
        get() {
            val parts = mutableListOf<String>()
            battery?.let { parts.add("$it%") }
            capacityWh?.let { parts.add("$it Wh") }
            temperatureC?.let { parts.add("$it°C") }
            return parts.joinToString(" · ").ifEmpty { "No data" }
        }
}

internal data class HinenCamera(
    val id: String,
    val name: String,
    val address: String,
)

internal object HinenQuickApi {
    private const val BASE_WH = 2560
    private const val PACK_WH = 2560

    fun readCameras(context: Context): List<HinenCamera> {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.camera_profiles", null) ?: return emptyList()
        val array = try {
            JSONArray(raw)
        } catch (_: Exception) {
            return emptyList()
        }
        val cameras = mutableListOf<HinenCamera>()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val id = item.optString("id").ifBlank { item.optString("address") }
            val name = item.optString("name").ifBlank { "Camera" }
            val address = item.optString("address")
            cameras.add(HinenCamera(id, name, address))
        }
        return cameras
    }

    fun readConfig(context: Context): HinenQuickConfig? {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.hinen_profiles", null) ?: return null
        val array = try {
            JSONArray(raw)
        } catch (_: Exception) {
            return null
        }
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val bridge = item.optString("bridgeUrl").trim()
            val address = item.optString("address").trim()
            if (bridge.isEmpty() || address.isEmpty()) continue
            return HinenQuickConfig(
                name = item.optString("name", "PS300").ifBlank { "PS300" },
                address = address,
                bridgeUrl = bridge,
            )
        }
        return null
    }

    fun status(config: HinenQuickConfig): HinenDps? {
        val response = post(config, "/api/hinen/status", JSONObject().put("ip", config.address))
        return parseDps(response)
    }

    fun write(config: HinenQuickConfig, dp: Int, value: Any): HinenDps? {
        val response = post(
            config,
            "/api/hinen/write",
            JSONObject()
                .put("ip", config.address)
                .put("dp", dp)
                .put("value", value),
        )
        return parseDps(response)
    }

    private fun post(config: HinenQuickConfig, path: String, body: JSONObject): JSONObject? {
        val base = config.bridgeUrl.trim().trimEnd('/')
        val connection = (URL("$base$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 6000
            readTimeout = 12000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        return try {
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            val text = connection.inputStream.bufferedReader().use { it.readText() }
            JSONObject(text)
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun parseDps(response: JSONObject?): HinenDps? {
        val dps = response?.optJSONObject("dps") ?: return null
        fun intDp(id: Int): Int? =
            if (dps.has(id.toString())) dps.optInt(id.toString()) else null
        fun boolDp(id: Int): Boolean? =
            if (dps.has(id.toString())) dps.optBoolean(id.toString()) else null
        val tempF = intDp(105)
        return HinenDps(
            battery = intDp(1),
            ac = boolDp(6),
            dc = boolDp(7),
            light = intDp(113),
            packs = intDp(116),
            temperatureC = tempF?.let { ((it - 32) * 5 / 9.0).toInt() },
            standbySeconds = intDp(26),
        )
    }
}

internal object HinenQuickNotifications {
    const val CHANNEL_ID = "hinen_controls"
    const val NOTIFICATION_ID = 0x484E

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "PS300 controls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "LocalHome PS300 notification card"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    fun post(context: Context) {
        ensureChannel(context)
        Thread {
            val config = HinenQuickApi.readConfig(context)
            val dps = config?.let { HinenQuickApi.status(it) }
            val cameras = HinenQuickApi.readCameras(context)
            val cameraText = "${cameras.size} camera${if (cameras.size == 1) "" else "s"}"
            val summary = listOfNotNull(dps?.summary, cameraText).joinToString(" · ")
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_localhome)
                .setContentTitle("LocalHome · ${config?.name ?: "PS300"}")
                .setContentText(summary)
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        buildString {
                            append(summary)
                            if (dps?.ac != null) append("\nAC: ${if (dps.ac) "On" else "Off"}")
                            if (dps?.dc != null) append("  ·  DC: ${if (dps.dc) "On" else "Off"}")
                            if (dps?.light != null) append("  ·  Light: ${dps.lightLabel}")
                            if (cameras.isNotEmpty()) {
                                append("\nCameras: ")
                                append(cameras.joinToString(", ") { it.name })
                            }
                        },
                    ),
                )
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(openApp(context, 100))
            if (dps?.ac != null) {
                builder.addAction(
                    android.R.drawable.ic_menu_manage,
                    if (dps.ac) "AC On" else "AC Off",
                    toggleIntent(context, "ac", 101),
                )
            }
            if (dps?.dc != null) {
                builder.addAction(
                    android.R.drawable.ic_menu_manage,
                    if (dps.dc) "DC On" else "DC Off",
                    toggleIntent(context, "dc", 102),
                )
            }
            builder.addAction(
                android.R.drawable.ic_menu_camera,
                "$cameraText",
                openApp(context, 104),
            )
            if (dps?.light != null) {
                builder.addAction(
                    android.R.drawable.ic_menu_compass,
                    "Light: ${dps.lightLabel}",
                    sheetIntent(context, 103),
                )
            }
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, builder.build())
        }.start()
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    private fun openApp(context: Context, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun toggleIntent(context: Context, kind: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, HinenQuickActionReceiver::class.java).apply {
            action = HinenQuickActionReceiver.ACTION_TOGGLE
            putExtra("kind", kind)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun sheetIntent(context: Context, requestCode: Int): PendingIntent {
        val intent = Intent(context, HinenQuickSheetActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("kind", "all")
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class HinenQuickActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_TOGGLE = "com.pyansofyan.localhome.HINEN_TOGGLE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TOGGLE) return
        val kind = intent.getStringExtra("kind") ?: return
        val pending = goAsync()
        Thread {
            try {
                val config = HinenQuickApi.readConfig(context) ?: return@Thread
                val dps = HinenQuickApi.status(config) ?: return@Thread
                when (kind) {
                    "ac" -> dps.ac?.let {
                        HinenQuickApi.write(config, 6, !it)
                    }
                    "dc" -> dps.dc?.let {
                        HinenQuickApi.write(config, 7, !it)
                    }
                }
                HinenQuickNotifications.post(context)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

class HinenQuickTileService : TileService() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        val intent = Intent(this, HinenQuickSheetActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("kind", "all")
        }
        if (Build.VERSION.SDK_INT >= 34) {
            val pending = PendingIntent.getActivity(
                this,
                200,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun updateTile() {
        Thread {
            val config = HinenQuickApi.readConfig(this)
            val dps = config?.let { HinenQuickApi.status(it) }
            val cameras = HinenQuickApi.readCameras(this)
            val cameraText = "${cameras.size} camera${if (cameras.size == 1) "" else "s"}"
            mainHandler.post {
                val tile = qsTile ?: return@post
                tile.label = "LocalHome"
                tile.state = if (dps?.ac == true || dps?.dc == true || (dps?.light ?: 0) > 0) {
                    Tile.STATE_ACTIVE
                } else {
                    Tile.STATE_INACTIVE
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = listOfNotNull(cameraText, dps?.summary)
                        .joinToString(" · ")
                        .ifEmpty { "Not configured" }
                }
                tile.updateTile()
            }
        }.start()
    }
}

class HinenQuickSheetActivity : Activity() {
    private var config: HinenQuickConfig? = null
    private var dps: HinenDps? = null
    private val background = Executors.newSingleThreadExecutor()
    private lateinit var statusText: TextView
    private lateinit var acSwitch: Switch
    private lateinit var dcSwitch: Switch
    private lateinit var lightButtons: LinearLayout
    private lateinit var progress: ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setGravity(Gravity.BOTTOM)
        window.setLayout(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0.45f)
        setContentView(buildView())
        config = HinenQuickApi.readConfig(this)
        if (config == null) {
            statusText.text = "Configure the host bridge in LocalHome first."
            progress.visibility = View.GONE
        } else {
            refresh()
        }
    }

    private fun buildView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            background = GradientDrawable().apply {
                setColor(Color.rgb(8, 17, 15))
                cornerRadii = floatArrayOf(
                    dp(26).toFloat(), dp(26).toFloat(),
                    dp(26).toFloat(), dp(26).toFloat(),
                    0f, 0f, 0f, 0f,
                )
            }
        }
        val title = TextView(this).apply {
            text = "LocalHome"
            setTextColor(Color.rgb(240, 248, 245))
            textSize = 22f
            setPadding(0, 0, 0, 2)
        }
        val subtitle = TextView(this).apply {
            text = "Cameras + PS300 energy"
            setTextColor(Color.rgb(143, 180, 168))
            textSize = 12f
            setPadding(0, 0, 0, dp(10))
        }
        statusText = TextView(this).apply {
            text = "Loading station…"
            setTextColor(Color.rgb(143, 180, 168))
            textSize = 13f
            setPadding(0, dp(2), 0, 0)
        }
        progress = ProgressBar(this).apply { visibility = View.VISIBLE }
        acSwitch = Switch(this).apply {
            text = "AC output"
            setTextColor(Color.rgb(222, 233, 228))
            setOnCheckedChangeListener { _, checked ->
                if (dps?.ac != checked) write(6, checked, "AC output")
            }
        }
        dcSwitch = Switch(this).apply {
            text = "DC output"
            setTextColor(Color.rgb(222, 233, 228))
            setOnCheckedChangeListener { _, checked ->
                if (dps?.dc != checked) write(7, checked, "DC output")
            }
        }
        lightButtons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, 0)
            for ((index, label) in listOf("Off", "Low", "Medium", "High", "SOS").withIndex()) {
                addView(Button(this@HinenQuickSheetActivity).apply {
                    text = label
                    textSize = 11f
                    setOnClickListener { write(113, index, "Light $label") }
                })
            }
        }
        val energyBlock = block().apply {
            addView(sectionLabel("Energy"))
            addView(statusText)
            addView(progress)
            addView(acSwitch)
            addView(dcSwitch)
            addView(TextView(this@HinenQuickSheetActivity).apply {
                text = "Light"
                setTextColor(Color.rgb(143, 180, 168))
                textSize = 13f
                setPadding(0, dp(8), 0, 0)
            })
            addView(lightButtons)
        }
        val camerasBlock = block().apply {
            addView(sectionLabel("Cameras"))
            val cameras = HinenQuickApi.readCameras(this@HinenQuickSheetActivity)
            if (cameras.isEmpty()) {
                addView(TextView(this@HinenQuickSheetActivity).apply {
                    text = "No camera profiles configured."
                    setTextColor(Color.rgb(143, 180, 168))
                    textSize = 12f
                    setPadding(0, dp(6), 0, 0)
                })
            } else {
                for (camera in cameras) {
                    addView(cameraBlock(camera))
                }
            }
            addView(TextView(this@HinenQuickSheetActivity).apply {
                text = "V380 cameras expose RTSP/ONVIF only; no per-camera Wh. " +
                    "The PS300 energy above is shared."
                setTextColor(Color.rgb(143, 180, 168))
                textSize = 10f
                setPadding(0, dp(8), 0, 0)
            })
        }
        val open = Button(this).apply {
            text = "Open LocalHome"
            setOnClickListener {
                startActivity(
                    Intent(this@HinenQuickSheetActivity, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                )
                finish()
            }
        }
        root.addView(title)
        root.addView(subtitle)
        root.addView(energyBlock)
        root.addView(camerasBlock)
        root.addView(open)
        return ScrollView(this).apply { addView(root) }
    }

    private fun block(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(10), dp(14), dp(14))
        background = GradientDrawable().apply {
            setColor(Color.rgb(16, 29, 25))
            cornerRadius = dp(18).toFloat()
            setStroke(dp(1), Color.rgb(41, 69, 60))
        }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(12) }
    }

    private fun cameraBlock(camera: HinenCamera): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(11), dp(12), dp(11))
            background = GradientDrawable().apply {
                setColor(Color.rgb(10, 21, 18))
                cornerRadius = dp(14).toFloat()
                setStroke(dp(1), Color.rgb(41, 69, 60))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(8) }
            isClickable = true
            isFocusable = true
            setOnClickListener {
                startActivity(
                    Intent(this@HinenQuickSheetActivity, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        putExtra("localhome_camera_id", camera.id)
                    },
                )
                finish()
            }
        }
        val icon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_camera)
            setColorFilter(Color.rgb(146, 230, 181))
        }
        val labels = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f,
            )
        }
        labels.addView(TextView(this).apply {
            text = camera.name
            setTextColor(Color.rgb(222, 233, 228))
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        labels.addView(TextView(this).apply {
            text = camera.address
            setTextColor(Color.rgb(143, 180, 168))
            textSize = 10f
        })
        val arrow = TextView(this).apply {
            text = "›"
            setTextColor(Color.rgb(146, 230, 181))
            textSize = 22f
        }
        card.addView(icon)
        card.addView(labels)
        card.addView(arrow)
        return card
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun sectionLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        setTextColor(Color.rgb(146, 230, 181))
        textSize = 11f
        setPadding(0, 0, 0, dp(4))
    }

    private fun refresh() {
        val current = config ?: return
        progress.visibility = View.VISIBLE
        background.execute {
            val next = HinenQuickApi.status(current)
            runOnUiThread {
                progress.visibility = View.GONE
                dps = next
                if (next == null) {
                    statusText.text = "Could not read the host bridge."
                    return@runOnUiThread
                }
                statusText.text = buildString {
                    append(next.summary)
                    next.ac?.let { append("\nAC: ${if (it) "On" else "Off"}") }
                    next.dc?.let { append("  ·  DC: ${if (it) "On" else "Off"}") }
                    append("  ·  Light: ${next.lightLabel}")
                }
                acSwitch.isChecked = next.ac == true
                dcSwitch.isChecked = next.dc == true
            }
        }
    }

    private fun write(dp: Int, value: Any, label: String) {
        val current = config ?: return
        progress.visibility = View.VISIBLE
        background.execute {
            val next = HinenQuickApi.write(current, dp, value)
            runOnUiThread {
                progress.visibility = View.GONE
                if (next == null) {
                    statusText.text = "$label write failed."
                    return@runOnUiThread
                }
                dps = next
                statusText.text = next.summary
                acSwitch.isChecked = next.ac == true
                dcSwitch.isChecked = next.dc == true
                HinenQuickNotifications.post(this)
            }
        }
    }

    override fun onDestroy() {
        background.shutdownNow()
        super.onDestroy()
    }
}
