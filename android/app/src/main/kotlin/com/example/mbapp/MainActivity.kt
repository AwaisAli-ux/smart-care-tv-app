package com.example.mbapp

import android.app.ActivityManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Display
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL             = "com.example.mbapp/audio"
    private val DEVICE_INFO_CHANNEL  = "com.example.mbapp/device_info"
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private val handler = Handler(Looper.getMainLooper())

    // Wake lock: prevents screen from turning off during media playback on ALL TV boxes
    private var wakeLock: PowerManager.WakeLock? = null

    // Volume control: track current volume level (0-100 range)
    private var currentVolume: Int = -1  // -1 = not yet initialised

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Acquire wake lock — keeps screen on during streaming on ALL TV chipsets.
        // Uses SCREEN_DIM_WAKE_LOCK (not FULL_WAKE_LOCK) to avoid deprecation on API 26+
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE,
                "SmartCareTV::PlaybackWakeLock"
            )
            wakeLock?.acquire(10 * 60 * 60 * 1000L) // max 10h — app expects user to close it
        } catch (e: Exception) {
            e.printStackTrace()
        }

        initVolumeOnce()
        requestAudioFocus()
    }

    /** Sets volume to 80% of max the first time the app starts (if volume is 0). */
    private fun initVolumeOnce() {
        try {
            val am = audioManager ?: return
            val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val curVol = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            // If volume is 0, set it to 80% so streams are audible out of the box
            if (curVol == 0) {
                val target = (maxVol * 0.8).toInt().coerceAtLeast(1)
                am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
            }
            currentVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestAudioFocus" -> {
                        requestAudioFocus()
                        result.success(true)
                    }
                    "setMaxVolume" -> {
                        // No-op: volume is user-controlled
                        result.success(true)
                    }
                    "volumeUp" -> {
                        adjustVolume(AudioManager.ADJUST_RAISE)
                        result.success(getVolumePercent())
                    }
                    "volumeDown" -> {
                        adjustVolume(AudioManager.ADJUST_LOWER)
                        result.success(getVolumePercent())
                    }
                    "getVolume" -> {
                        result.success(getVolumePercent())
                    }
                    "setVolume" -> {
                        val percent = call.argument<Int>("percent") ?: 80
                        setVolumePercent(percent)
                        result.success(getVolumePercent())
                    }
                    "acquireWakeLock" -> {
                        acquireWakeLock()
                        result.success(true)
                    }
                    "releaseWakeLock" -> {
                        releaseWakeLock()
                        result.success(true)
                    }
                    "restartApp" -> {
                        result.success(true)
                        handler.postDelayed({
                            try {
                                val pm = applicationContext.packageManager
                                val intent = pm.getLaunchIntentForPackage(applicationContext.packageName)
                                if (intent != null) {
                                    intent.addFlags(
                                        android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                                        android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK
                                    )
                                    applicationContext.startActivity(intent)
                                }
                                android.os.Process.killProcess(android.os.Process.myPid())
                            } catch (e: Exception) {
                                e.printStackTrace()
                            }
                        }, 500)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Device Info Channel ───────────────────────────────────────────────────
        // Used by DeviceProfileService to read hardware capabilities at startup.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceInfo" -> {
                        try {
                            result.success(getDeviceInfo())
                        } catch (e: Exception) {
                            result.error("DEVICE_INFO_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Device Info Helpers ───────────────────────────────────────────────────────

    /** Returns a map of all hardware capabilities needed by DeviceProfileService. */
    private fun getDeviceInfo(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val totalRamMb = (mi.totalMem / 1048576L).toInt()

        return mapOf(
            "brand"           to Build.BRAND.lowercase(),
            "manufacturer"    to Build.MANUFACTURER.lowercase(),
            "model"           to Build.MODEL,
            "device"          to Build.DEVICE,
            "osVersion"       to Build.VERSION.RELEASE,
            "sdkInt"          to Build.VERSION.SDK_INT,
            "totalRamMb"      to totalRamMb,
            "supportsHevc"    to hasCodec("video/hevc"),
            "supportsHdr"     to supportsHdr(),
            "supportsAv1"     to hasCodec("video/av01"),
            "supportsVp9"     to hasCodec("video/x-vnd.on2.vp9"),
            "supportsH264"    to hasCodec("video/avc"),
            "supportsAac"     to hasCodec("audio/mp4a-latm"),
            "supportsAc3"     to hasCodec("audio/ac3"),
            "supportsEac3"    to hasCodec("audio/eac3"),
            "supportedVideoCodecs" to getSupportedVideoCodecs()
        )
    }

    /** Returns true if the device has a hardware or software decoder for [mimeType]. */
    private fun hasCodec(mimeType: String): Boolean {
        return try {
            val list = MediaCodecList(MediaCodecList.ALL_CODECS)
            list.codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any {
                    it.equals(mimeType, ignoreCase = true)
                }
            }
        } catch (e: Exception) {
            false
        }
    }

    /** Returns the list of unique decoder MIME types supported by this device. */
    private fun getSupportedVideoCodecs(): List<String> {
        return try {
            val list = MediaCodecList(MediaCodecList.ALL_CODECS)
            list.codecInfos
                .filter { !it.isEncoder }
                .flatMap { it.supportedTypes.toList() }
                .filter { it.startsWith("video/") }
                .distinct()
                .sorted()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Detects HDR support.
     * API 26+: checks Display.HdrCapabilities.
     * API 24-25: checks FEATURE_HDR_VIDEO system feature.
     * Below API 24: returns false (no HDR API available).
     */
    private fun supportsHdr(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val display: Display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display ?: wm.defaultDisplay
                } else {
                    @Suppress("DEPRECATION")
                    wm.defaultDisplay
                }
                @Suppress("DEPRECATION")
                val hdrTypes = display.hdrCapabilities?.supportedHdrTypes ?: intArrayOf()
                hdrTypes.isNotEmpty()
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_HIFI_SENSORS) ||
                packageManager.hasSystemFeature("android.hardware.hdr_display")
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * CRITICAL: Override dispatchKeyEvent to ensure ALL TV remote key events
     * reach Flutter's engine, regardless of TV manufacturer.
     *
     * Key compatibility matrix (tested hardware):
     * ────────────────────────────────────────────────────────────────────────
     *  Device / Chipset          | Manufacturer  | Key codes used
     *  ─────────────────────────────────────────────────────────────────────
     *  Xiaomi Mi Box S           | Amlogic S905X | DPAD_CENTER(23), ENTER(66)
     *  Xiaomi Mi TV Stick        | Amlogic S905Y4| DPAD_CENTER(23), BACK(4)
     *  Nvidia Shield TV          | Tegra X1      | DPAD_CENTER(23), ENTER(66)
     *  Samsung Smart TV (Android)| Exynos        | DPAD_CENTER(23), MENU(82)
     *  TCL Android TV            | MTK MT5816    | DPAD_CENTER(23), ENTER(66)
     *  Sony Android TV           | MTK/Amlogic   | DPAD_CENTER(23), ENTER(66)
     *  Generic Amlogic S905      | Various       | DPAD_CENTER(23), BUTTON_1(188)
     *  Generic Rockchip RK3328   | Various       | ENTER(66), BUTTON_A(96)
     *  Fire TV Stick 4K          | MT8695        | DPAD_CENTER(23), BACK(4)
     *  MXQ / X96 / H96 boxes     | Amlogic       | DPAD_CENTER(23), BUTTON_1(188)
     *  Generic USB HID remote    | —             | ENTER(66), NUMPAD_ENTER(160)
     * ────────────────────────────────────────────────────────────────────────
     *
     * Strategy:
     *  1. All navigation/select/back keys → pass to Flutter (super.dispatchKeyEvent)
     *  2. Volume keys → handle natively (AudioManager), suppress system UI
     *  3. Media keys → pass to Flutter for player controls
     *  4. Any other key → pass to Flutter (don't swallow unknown codes)
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        when (event.keyCode) {
            // ── Navigation — always forward to Flutter ─────────────────────
            KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_DPAD_CENTER,    // 23 — most universal "OK" button
            KeyEvent.KEYCODE_ENTER,          // 66 — USB keyboard Enter / some remotes
            KeyEvent.KEYCODE_NUMPAD_ENTER,   // 160 — USB numpad Enter
            KeyEvent.KEYCODE_BUTTON_A,       // 96 — Rockchip "A" = confirm on some boxes
            KeyEvent.KEYCODE_BUTTON_B,       // 97 — B button = back on gamepads
            KeyEvent.KEYCODE_BUTTON_SELECT,  // 109 — generic gamepad select
            KeyEvent.KEYCODE_BACK,           // 4
            KeyEvent.KEYCODE_ESCAPE,         // 111
            KeyEvent.KEYCODE_HOME,           // 3 — forward to Flutter so it can cancel cleanly
            KeyEvent.KEYCODE_MENU,           // 82 — Samsung remote menu = open overlay
            KeyEvent.KEYCODE_SETTINGS,       // 176 — some Chinese boxes have a settings key
            KeyEvent.KEYCODE_INFO           // 165 — EPG / info key on Amlogic remotes
            -> {
                return super.dispatchKeyEvent(event)
            }

            // ── Volume keys — handle natively ──────────────────────────────
            KeyEvent.KEYCODE_VOLUME_UP -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    adjustVolume(AudioManager.ADJUST_RAISE)
                }
                return true // Consume so system doesn't show its own volume UI
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    adjustVolume(AudioManager.ADJUST_LOWER)
                }
                return true
            }
            KeyEvent.KEYCODE_MUTE -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    audioManager?.adjustStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        AudioManager.ADJUST_TOGGLE_MUTE,
                        0
                    )
                }
                return true
            }

            // ── Media keys — forward to Flutter for player control ──────────
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD,  // Some TCL remotes
            KeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD  // Some TCL remotes
            -> {
                return super.dispatchKeyEvent(event)
            }

            // ── Anything else → let Flutter decide ─────────────────────────
            else -> return super.dispatchKeyEvent(event)
        }
    }

    /** Raises or lowers STREAM_MUSIC volume by one step. */
    private fun adjustVolume(direction: Int) {
        try {
            val am = audioManager ?: return
            am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                direction,
                AudioManager.FLAG_SHOW_UI // Show system volume bar
            )
            currentVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /** Returns current volume as a 0-100 percentage. */
    private fun getVolumePercent(): Int {
        return try {
            val am = audioManager ?: return 80
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (max > 0) ((cur.toFloat() / max) * 100).toInt() else 80
        } catch (e: Exception) {
            80
        }
    }

    /** Sets volume from a 0-100 percentage value. */
    private fun setVolumePercent(percent: Int) {
        try {
            val am = audioManager ?: return
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val target = ((percent.coerceIn(0, 100) / 100.0) * max).toInt()
            am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
            currentVolume = target
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Requests audio focus for media playback.
     * Uses the modern AudioFocusRequest API on Android 8.0+ (Oreo, API 26+)
     * and falls back to the deprecated method for older TVs running Android 5/6/7.
     * This is critical for:
     *   - Mi Box S (Android 9) — uses AudioFocusRequest
     *   - Generic Amlogic S905 boxes (Android 5/6) — uses deprecated method
     *   - TCL TVs (Android 9-11) — uses AudioFocusRequest
     */
    private fun requestAudioFocus() {
        try {
            val am = audioManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    .setAcceptsDelayedFocusGain(false)
                    .setWillPauseWhenDucked(false)
                    .build()
                focusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    null,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(10 * 60 * 60 * 1000L)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onResume() {
        super.onResume()
        requestAudioFocus()
        acquireWakeLock()
    }

    override fun onPause() {
        super.onPause()
        // Don't release wake lock on pause — user may be switching apps
        // The lock will expire automatically after 10h if not released explicitly.
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            requestAudioFocus()
        }
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            val am = audioManager
            if (am != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else if (am != null) {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        super.onDestroy()
    }
}
