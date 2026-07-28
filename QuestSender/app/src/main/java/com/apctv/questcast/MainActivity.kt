package com.apctv.questcast

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private val nsdManager by lazy { getSystemService(Context.NSD_SERVICE) as NsdManager }
    private val projectionManager by lazy {
        getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    }

    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var statusDot: View
    private lateinit var discoveryProgress: ProgressBar
    private lateinit var receiverList: LinearLayout
    private lateinit var stopButton: Button
    private var selectedReceiver: NsdServiceInfo? = null

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getStringExtra(ProjectionService.EXTRA_STATUS)?.let(::setStatus)
        }
    }

    private val capturePermission = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val receiver = selectedReceiver
        val data = result.data
        if (result.resultCode != Activity.RESULT_OK || data == null || receiver?.host == null) {
            setReceiverButtonsEnabled(true)
            setStatus("Capture was not started")
            return@registerForActivityResult
        }

        val serviceIntent = Intent(this, ProjectionService::class.java).apply {
            putExtra(ProjectionService.EXTRA_RESULT_CODE, result.resultCode)
            putExtra(ProjectionService.EXTRA_RESULT_DATA, data)
            putExtra(ProjectionService.EXTRA_HOST, receiver.host.hostAddress)
            putExtra(ProjectionService.EXTRA_PORT, receiver.port)
        }
        ContextCompat.startForegroundService(this, serviceIntent)
        setStatus("Starting cast…")
    }

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = setStatus("Looking for Apple TV…")

        override fun onServiceFound(service: NsdServiceInfo) {
            if (service.serviceType != SERVICE_TYPE) return
            @Suppress("DEPRECATION")
            nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    runOnUiThread { addReceiver(serviceInfo) }
                }
            })
        }

        override fun onServiceLost(service: NsdServiceInfo) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            setStatus("Discovery failed ($errorCode)")
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.rgb(3, 5, 16)

        val root = FrameLayout(this).apply {
            background = ContextCompat.getDrawable(this@MainActivity, R.drawable.questcast_background)
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(56), dp(30), dp(56), dp(38))
        }

        content.addView(TextView(this).apply {
            text = "QUESTCAST"
            textSize = 15f
            letterSpacing = 0.28f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.argb(180, 255, 255, 255))
            gravity = Gravity.CENTER
        }, matchWrap())

        content.addView(ImageView(this).apply {
            setImageResource(R.drawable.questcast_headset)
            scaleType = ImageView.ScaleType.FIT_CENTER
            contentDescription = null
        }, LinearLayout.LayoutParams(dp(640), dp(270)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dp(4)
        })

        content.addView(TextView(this).apply {
            text = "Cast your headset view"
            textSize = 34f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }, matchWrap())

        content.addView(TextView(this).apply {
            text = "Low-latency casting to Apple TV over your local network"
            textSize = 17f
            setTextColor(Color.rgb(181, 190, 211))
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(7)
        })

        val statusPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(22), dp(18), dp(22), dp(18))
            background = ContextCompat.getDrawable(this@MainActivity, R.drawable.status_panel)
        }
        statusDot = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(245, 185, 66))
            }
        }
        statusPanel.addView(statusDot, LinearLayout.LayoutParams(dp(12), dp(12)).apply {
            marginEnd = dp(16)
        })

        val statusCopy = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        statusTitle = TextView(this).apply {
            text = "Starting QuestCast"
            textSize = 18f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.WHITE)
        }
        statusDetail = TextView(this).apply {
            text = "Preparing local network discovery…"
            textSize = 14f
            setTextColor(Color.rgb(161, 172, 196))
            setPadding(0, dp(3), 0, 0)
        }
        statusCopy.addView(statusTitle, matchWrap())
        statusCopy.addView(statusDetail, matchWrap())
        statusPanel.addView(statusCopy, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        discoveryProgress = ProgressBar(this).apply {
            isIndeterminate = true
            indeterminateTintList = ColorStateList.valueOf(Color.rgb(105, 210, 255))
        }
        statusPanel.addView(discoveryProgress, LinearLayout.LayoutParams(dp(28), dp(28)).apply {
            marginStart = dp(16)
        })
        content.addView(statusPanel, LinearLayout.LayoutParams(dp(660), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(28)
        })

        receiverList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        content.addView(receiverList, LinearLayout.LayoutParams(dp(660), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(16)
        })

        stopButton = Button(this).apply {
            text = "Stop casting"
            textSize = 16f
            isAllCaps = false
            isFocusable = true
            setTextColor(Color.WHITE)
            background = ContextCompat.getDrawable(this@MainActivity, R.drawable.stop_button_background)
            visibility = View.GONE
            setOnClickListener {
                stopService(Intent(this@MainActivity, ProjectionService::class.java))
                setReceiverButtonsEnabled(true)
                setStatus("Cast stopped")
            }
        }
        content.addView(stopButton, LinearLayout.LayoutParams(dp(240), dp(54)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dp(16)
        })

        content.addView(TextView(this).apply {
            text = "Keep QuestCast open on your Apple TV while connecting."
            textSize = 13f
            setTextColor(Color.argb(135, 255, 255, 255))
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(22)
        })

        scroll.addView(content, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(scroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(root)

        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    override fun onDestroy() {
        runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            statusReceiver,
            IntentFilter(ProjectionService.ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun onStop() {
        runCatching { unregisterReceiver(statusReceiver) }
        super.onStop()
    }

    private fun addReceiver(receiver: NsdServiceInfo) {
        if ((0 until receiverList.childCount).any {
                receiverList.getChildAt(it).tag == "${receiver.host}:${receiver.port}"
            }) return

        val button = Button(this).apply {
            text = "Cast to ${receiver.serviceName}"
            textSize = 17f
            isAllCaps = false
            isFocusable = true
            setTextColor(Color.WHITE)
            background = ContextCompat.getDrawable(this@MainActivity, R.drawable.cast_button_background)
            tag = "${receiver.host}:${receiver.port}"
            setOnClickListener {
                selectedReceiver = receiver
                setReceiverButtonsEnabled(false)
                setStatus("Approve screen capture in the headset")
                capturePermission.launch(projectionManager.createScreenCaptureIntent())
            }
        }
        receiverList.addView(button, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(62)).apply {
            bottomMargin = dp(10)
        })
        setStatus("Apple TV found")
    }

    private fun setStatus(message: String) = runOnUiThread {
        if (!::statusTitle.isInitialized) return@runOnUiThread

        val presentation = when {
            message == "Apple TV found" -> StatusPresentation(
                "QuestCast TV found",
                "Select the destination below to begin.",
                STATUS_READY,
                false,
                false
            )
            message.startsWith("Looking") || message.startsWith("Starting discovery") -> StatusPresentation(
                "Looking for QuestCast TV",
                "Make sure the receiver is open on your Apple TV.",
                STATUS_WAITING,
                true,
                false
            )
            message.startsWith("Approve") -> StatusPresentation(
                "Screen-capture permission required",
                "Choose Start now in the system prompt.",
                STATUS_WAITING,
                false,
                false
            )
            message.startsWith("Starting") || message.startsWith("Encoder started") -> StatusPresentation(
                "Connecting to Apple TV",
                "Preparing the low-latency video stream…",
                STATUS_WAITING,
                true,
                true
            )
            message == "Streaming video to Apple TV" -> StatusPresentation(
                "Casting to Apple TV",
                "Your headset view is live.",
                STATUS_LIVE,
                false,
                true
            )
            message == "Cast stopped" -> StatusPresentation(
                "Casting stopped",
                "Select QuestCast TV to cast again.",
                STATUS_READY,
                false,
                false
            )
            message.startsWith("Cast failed") || message.startsWith("Stream failed") || message.startsWith("Discovery failed") -> StatusPresentation(
                "Something went wrong",
                message,
                STATUS_ERROR,
                false,
                false
            )
            message == "Capture was not started" -> StatusPresentation(
                "Casting cancelled",
                "Select QuestCast TV whenever you’re ready.",
                STATUS_READY,
                false,
                false
            )
            else -> StatusPresentation("QuestCast", message, STATUS_WAITING, false, false)
        }

        statusTitle.text = presentation.title
        statusDetail.text = presentation.detail
        discoveryProgress.visibility = if (presentation.showProgress) View.VISIBLE else View.GONE
        stopButton.visibility = if (presentation.showStop) View.VISIBLE else View.GONE
        setStatusDotColour(presentation.colour)

        if (message.startsWith("Cast failed") || message.startsWith("Stream failed") ||
            message.startsWith("Discovery failed") || message == "Capture was not started" ||
            message == "Cast stopped"
        ) {
            setReceiverButtonsEnabled(true)
        }
    }

    private fun setReceiverButtonsEnabled(enabled: Boolean) {
        if (!::receiverList.isInitialized) return
        for (index in 0 until receiverList.childCount) {
            receiverList.getChildAt(index).isEnabled = enabled
            receiverList.getChildAt(index).alpha = if (enabled) 1f else 0.55f
        }
    }

    private fun setStatusDotColour(colour: Int) {
        statusDot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(colour)
        }
    }

    private fun matchWrap() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    )

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun IntRange.any(predicate: (Int) -> Boolean): Boolean {
        for (value in this) if (predicate(value)) return true
        return false
    }

    private data class StatusPresentation(
        val title: String,
        val detail: String,
        val colour: Int,
        val showProgress: Boolean,
        val showStop: Boolean
    )

    companion object {
        private const val SERVICE_TYPE = "_questcast._udp."
        private val STATUS_WAITING = Color.rgb(245, 185, 66)
        private val STATUS_READY = Color.rgb(96, 220, 160)
        private val STATUS_LIVE = Color.rgb(84, 232, 132)
        private val STATUS_ERROR = Color.rgb(255, 105, 120)
    }
}
