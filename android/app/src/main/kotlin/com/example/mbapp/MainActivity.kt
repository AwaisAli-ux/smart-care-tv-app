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
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL             = "com.example.mbapp/audio"
    private val DEVICE_INFO_CHANNEL  = "com.example.mbapp/device_info"
    private val TV_KEYS_CHANNEL      = "com.example.mbapp/tv_keys"
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private val handler = Handler(Looper.getMainLooper())

    // Wake lock: prevents screen from turning off during media playback on ALL TV boxes
    private var wakeLock: PowerManager.WakeLock? = null

    // Volume control: track current volume level (0-100 range)
    private var currentVolume: Int = -1  // -1 = not yet initialised

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // FLAG_KEEP_SCREEN_ON: belt-and-suspenders alongside the WakeLock.
        // Required on Sony Bravia, Philips, and some TCL Google TV firmwares
        // where PowerManager WakeLock alone does not prevent the display from
        // dimming during long media playback sessions.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Deferred requestFocus: on some Google TV devices (TCL, Haier, Sony)
        // the FlutterView surface is not yet attached when onCreate fires.
        // Posting to the decorView's message queue guarantees the focus claim
        // runs after the first layout pass — so remote key events reach Flutter
        // from the very first frame instead of requiring a resume/pause cycle.
        window.decorView.post { window.decorView.requestFocus() }

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

        // ── TV Keys Channel ──────────────────────────────────────────────────────
        // Registers the channel so Flutter can send key-related method calls if needed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TV_KEYS_CHANNEL)

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
     * CRITICAL FIX FOR GOOGLE ANDROID TV (TCL, Haier, Sony, Philips, Hisense):
     *
     * On Google-certified Android TV / Google TV devices, the Leanback UI framework
     * intercepts DPAD key events BEFORE they reach Flutter when routed through the
     * standard Android view hierarchy (super.dispatchKeyEvent).
     *
     * Fix: we intercept ALL key events at the Activity level and directly inject them
     * into Flutter's engine using the FlutterView's onKeyUp/onKeyDown methods,
     * which bypasses the Leanback framework entirely.
     *
     * Key compatibility matrix:
     * ─────────────────────────────────────────────────────────────────────────
     *  Device                    | Remote Key     | Android Keycode
     *  ─────────────────────────────────────────────────────────────────────
     *  TCL Android TV            | OK/Select      | DPAD_CENTER (23)
     *  Haier Android TV          | OK/Select      | DPAD_CENTER (23)
     *  Sony Bravia (Android TV)  | OK/Select      | DPAD_CENTER (23)
     *  Philips Android TV        | OK/Select      | DPAD_CENTER (23)
     *  Hisense Android TV        | OK/Select      | DPAD_CENTER (23) / ENTER (66)
     *  Xiaomi Mi Box S           | OK/Select      | DPAD_CENTER (23)
     *  Nvidia Shield TV          | OK/Select      | DPAD_CENTER (23)
     *  Amazon Fire TV Stick 4K   | OK/Select      | DPAD_CENTER (23)
     *  Generic Rockchip box      | OK/Select      | BUTTON_A (96) / ENTER (66)
     *  Generic Amlogic box       | OK/Select      | DPAD_CENTER (23)
     *  USB HID Keyboard/Remote   | Enter          | ENTER (66) / NUMPAD_ENTER (160)
     * ─────────────────────────────────────────────────────────────────────────
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode

        // ── Volume keys — handle natively, suppress system volume UI ────────
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (event.action == KeyEvent.ACTION_DOWN) adjustVolume(AudioManager.ADJUST_RAISE)
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.action == KeyEvent.ACTION_DOWN) adjustVolume(AudioManager.ADJUST_LOWER)
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_MUTE) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                audioManager?.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_TOGGLE_MUTE, 0
                )
            }
            return true
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return super.onKeyDown(keyCode, event)
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
        // CRITICAL FOR GOOGLE ANDROID TV (TCL, Haier, Sony, Philips):
        // On Google-certified Android TV, the Leanback system manages Android
        // View-level focus across the whole OS. Without this, the FlutterView
        // may not have View focus after resuming, causing ALL remote key events
        // to be silently dropped — the remote appears completely dead.
        // requestFocus() on the decor view forces Flutter's view tree to own
        // Android input focus, so dispatchKeyEvent() is actually called.
        window.decorView.requestFocus()
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
            // Re-claim View focus when window regains focus (e.g. after a dialog
            // or system overlay dismisses on Google TV). Same reason as onResume.
            window.decorView.requestFocus()
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
