package com.apctv.questcast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class ProjectionService : Service() {
    private var projection: MediaProjection? = null
    private var encoder: MediaCodec? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var socket: DatagramSocket? = null
    private var encoderThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    @Volatile private var audioCaptureActive = false
    @Volatile private var audioCaptureFailed = false
    private val running = AtomicBoolean(false)
    private val starting = AtomicBoolean(false)
    private val startupExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "questcast-startup")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || running.get() || !starting.compareAndSet(false, true)) return START_NOT_STICKY
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val resultData = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        } ?: return stopForError()
        val host = intent.getStringExtra(EXTRA_HOST) ?: return stopForError()
        val port = intent.getIntExtra(EXTRA_PORT, DEFAULT_PORT)
        val includeAudio = intent.getBooleanExtra(EXTRA_INCLUDE_AUDIO, false)
        publishStatus("Starting encoder for $host:$port")

        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projection = manager.getMediaProjection(resultCode, resultData).also { mediaProjection ->
            mediaProjection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() = stopSelf()
            }, Handler(Looper.getMainLooper()))
        }

        startupExecutor.execute {
            runCatching { startEncoder(InetAddress.getByName(host), port, includeAudio) }
                .onSuccess { starting.set(false) }
                .onFailure { error ->
                    starting.set(false)
                    Log.e(TAG, "Could not start casting", error)
                    publishStatus("Cast failed: ${error.javaClass.simpleName}: ${error.message ?: "unknown error"}")
                    stopSelf()
                }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        starting.set(false)
        startupExecutor.shutdownNow()
        encoderThread?.interrupt()
        audioThread?.interrupt()
        audioRecord?.runCatching { stop() }
        audioRecord?.release()
        virtualDisplay?.release()
        encoder?.runCatching { stop() }
        encoder?.release()
        projection?.stop()
        socket?.close()
        super.onDestroy()
    }

    private fun startEncoder(address: InetAddress, port: Int, includeAudio: Boolean) {
        socket = DatagramSocket().apply { connect(address, port) }

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_SECONDS)
        }

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also { codec ->
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val inputSurface = codec.createInputSurface()
            codec.start()
            virtualDisplay = projection?.createVirtualDisplay(
                "QuestCast",
                WIDTH,
                HEIGHT,
                resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface,
                null,
                null
            )
        }

        running.set(true)
        if (includeAudio) {
            runCatching { startAudioCapture() }
                .onFailure { error ->
                    audioCaptureFailed = true
                    Log.w(TAG, "Playback audio is unavailable", error)
                    publishStatus("Audio unavailable: ${error.javaClass.simpleName}")
                }
        }
        publishStatus("Encoder started; waiting for video frames")
        encoderThread = Thread({
            runCatching { drainEncoder() }
                .onFailure { error ->
                    Log.e(TAG, "Streaming stopped", error)
                    publishStatus("Stream failed: ${error.javaClass.simpleName}: ${error.message ?: "unknown error"}")
                    stopSelf()
                }
        }, "questcast-encoder").apply { start() }
    }

    private fun startAudioCapture() {
        val mediaProjection = projection ?: error("MediaProjection is unavailable")
        val captureConfiguration = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(AUDIO_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val minimumBuffer = AudioRecord.getMinBufferSize(
            AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        check(minimumBuffer > 0) { "No compatible playback capture format" }

        audioRecord = AudioRecord.Builder()
            .setAudioFormat(audioFormat)
            .setBufferSizeInBytes(maxOf(minimumBuffer, AUDIO_CHUNK_BYTES * 4))
            .setAudioPlaybackCaptureConfig(captureConfiguration)
            .build()
            .also { record ->
                check(record.state == AudioRecord.STATE_INITIALIZED) { "Playback capture did not initialise" }
                record.startRecording()
            }

        audioCaptureActive = true
        audioThread = Thread({ captureAudio() }, "questcast-audio").apply { start() }
    }

    private fun captureAudio() {
        val record = audioRecord ?: return
        val chunk = ByteArray(AUDIO_CHUNK_BYTES)
        try {
            while (running.get() && !Thread.currentThread().isInterrupted) {
                val bytesRead = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                if (bytesRead > 0) {
                    AudioUdpPacketizer.send(
                        socket ?: return,
                        chunk.copyOf(bytesRead),
                        System.nanoTime() / 1_000L
                    )
                } else if (bytesRead < 0) {
                    error("AudioRecord read failed ($bytesRead)")
                }
            }
        } catch (error: Throwable) {
            if (running.get()) {
                audioCaptureActive = false
                audioCaptureFailed = true
                Log.w(TAG, "Playback audio stopped", error)
                publishStatus("Audio unavailable: ${error.javaClass.simpleName}")
            }
        }
    }

    private fun drainEncoder() {
        val codec = encoder ?: return
        val info = MediaCodec.BufferInfo()
        while (running.get() && !Thread.currentThread().isInterrupted) {
            when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> sendCodecConfiguration(codec.outputFormat)
                else -> if (index >= 0) {
                    val output = codec.getOutputBuffer(index)
                    if (output != null && info.size > 0) {
                        output.position(info.offset)
                        output.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size)
                        output.get(bytes)
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        val isKeyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        UdpPacketizer.send(socket ?: return, bytes, info.presentationTimeUs, isConfig, isKeyFrame)
                    }
                    codec.releaseOutputBuffer(index, false)
                }
            }
        }
    }

    private fun sendCodecConfiguration(format: MediaFormat) {
        val combined = ArrayList<Byte>()
        for (name in listOf("csd-0", "csd-1")) {
            val data = format.getByteBuffer(name) ?: continue
            val bytes = ByteArray(data.remaining())
            data.get(bytes)
            if (!startsWithAnnexB(bytes)) combined.addAll(START_CODE.toList())
            combined.addAll(bytes.toList())
        }
        if (combined.isNotEmpty()) {
            UdpPacketizer.send(socket ?: return, combined.toByteArray(), 0, isConfig = true, isKeyFrame = true)
            publishStatus(if (audioCaptureActive && !audioCaptureFailed) {
                "Streaming video and audio to Apple TV"
            } else {
                "Streaming video to Apple TV"
            })
        }
    }

    private fun startsWithAnnexB(bytes: ByteArray): Boolean =
        bytes.size >= 4 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte() &&
            (bytes[2] == 1.toByte() || (bytes[2] == 0.toByte() && bytes[3] == 1.toByte()))

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.capture_notification_channel), NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun buildNotification(): Notification = Notification.Builder(this, CHANNEL_ID)
        .setContentTitle("QuestCast is active")
        .setContentText("Streaming the headset view to Apple TV")
        .setSmallIcon(android.R.drawable.presence_video_online)
        .setOngoing(true)
        .build()

    private fun stopForError(): Int {
        publishStatus("Cast failed: missing capture permission or receiver address")
        stopSelf()
        return START_NOT_STICKY
    }

    private fun publishStatus(message: String) {
        Log.i(TAG, message)
        sendBroadcast(
            Intent(ACTION_STATUS)
                .setPackage(packageName)
                .putExtra(EXTRA_STATUS, message)
        )
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_STATUS = "status"
        const val EXTRA_INCLUDE_AUDIO = "includeAudio"
        const val ACTION_STATUS = "com.apctv.questcast.STATUS"

        private const val WIDTH = 1920
        private const val HEIGHT = 1080
        private const val FRAME_RATE = 60
        private const val BIT_RATE = 16_000_000
        private const val I_FRAME_INTERVAL_SECONDS = 1
        private const val DEFAULT_PORT = 49152
        private const val CHANNEL_ID = "questcast-capture"
        private const val NOTIFICATION_ID = 41
        private const val AUDIO_SAMPLE_RATE = 48_000
        private const val AUDIO_CHANNELS = 2
        private const val AUDIO_BYTES_PER_SAMPLE = 2
        private const val AUDIO_CHUNK_MILLISECONDS = 10
        private const val AUDIO_CHUNK_BYTES = AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * AUDIO_BYTES_PER_SAMPLE * AUDIO_CHUNK_MILLISECONDS / 1_000
        private const val TAG = "QuestCast"
        private val START_CODE = byteArrayOf(0, 0, 0, 1)
    }
}

private object AudioUdpPacketizer {
    private const val HEADER_SIZE = 24
    private const val MAX_DATAGRAM_SIZE = 1200
    private const val MAX_PAYLOAD = MAX_DATAGRAM_SIZE - HEADER_SIZE
    private var chunkId = 0

    @Synchronized
    fun send(socket: DatagramSocket, pcm: ByteArray, presentationTimeUs: Long) {
        if (pcm.isEmpty()) return
        val id = chunkId++
        val fragmentCount = (pcm.size + MAX_PAYLOAD - 1) / MAX_PAYLOAD
        for (fragmentIndex in 0 until fragmentCount) {
            val offset = fragmentIndex * MAX_PAYLOAD
            val payloadSize = minOf(MAX_PAYLOAD, pcm.size - offset)
            val bytes = ByteBuffer.allocate(HEADER_SIZE + payloadSize).order(ByteOrder.BIG_ENDIAN).apply {
                put(byteArrayOf('Q'.code.toByte(), 'C'.code.toByte(), 'T'.code.toByte(), 'A'.code.toByte()))
                put(1.toByte())
                put(0.toByte())
                putShort(HEADER_SIZE.toShort())
                putInt(id)
                putShort(fragmentIndex.toShort())
                putShort(fragmentCount.toShort())
                putLong(presentationTimeUs)
                put(pcm, offset, payloadSize)
            }.array()
            socket.send(DatagramPacket(bytes, bytes.size))
        }
    }
}

private object UdpPacketizer {
    private const val HEADER_SIZE = 24
    private const val MAX_DATAGRAM_SIZE = 1200
    private const val MAX_PAYLOAD = MAX_DATAGRAM_SIZE - HEADER_SIZE
    private const val FLAG_CONFIG = 0x01
    private const val FLAG_KEYFRAME = 0x02
    private var frameId = 0

    @Synchronized
    fun send(
        socket: DatagramSocket,
        accessUnit: ByteArray,
        presentationTimeUs: Long,
        isConfig: Boolean,
        isKeyFrame: Boolean
    ) {
        if (accessUnit.isEmpty()) return
        val id = frameId++
        val fragmentCount = (accessUnit.size + MAX_PAYLOAD - 1) / MAX_PAYLOAD
        if (fragmentCount > 0xFFFF) return
        val flags = (if (isConfig) FLAG_CONFIG else 0) or (if (isKeyFrame) FLAG_KEYFRAME else 0)

        for (fragmentIndex in 0 until fragmentCount) {
            val offset = fragmentIndex * MAX_PAYLOAD
            val payloadSize = minOf(MAX_PAYLOAD, accessUnit.size - offset)
            val bytes = ByteBuffer.allocate(HEADER_SIZE + payloadSize).order(ByteOrder.BIG_ENDIAN).apply {
                put(byteArrayOf('Q'.code.toByte(), 'C'.code.toByte(), 'T'.code.toByte(), 'V'.code.toByte()))
                put(1.toByte())
                put(flags.toByte())
                putShort(HEADER_SIZE.toShort())
                putInt(id)
                putShort(fragmentIndex.toShort())
                putShort(fragmentCount.toShort())
                putLong(presentationTimeUs)
                put(accessUnit, offset, payloadSize)
            }.array()
            socket.send(DatagramPacket(bytes, bytes.size))
        }
    }
}
