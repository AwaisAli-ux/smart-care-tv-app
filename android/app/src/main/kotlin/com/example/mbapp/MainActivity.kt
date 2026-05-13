package com.example.mbapp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.mbapp/audio"
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Force media volume to MAXIMUM on startup — never start muted
        forceMaxVolume()
        requestAudioFocus()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestAudioFocus" -> {
                        requestAudioFocus()
                        forceMaxVolume()
                        // Also schedule a deferred enforcement in case codec resets volume
                        scheduleVolumeEnforcement()
                        result.success(true)
                    }
                    "setMaxVolume" -> {
                        forceMaxVolume()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Schedules volume enforcement at 500ms, 1s, 2s, 4s after a stream starts.
     * Some IPTV streams (CNN, Cartoon Network, etc.) reset STREAM_MUSIC during
     * buffering or codec initialization — we need to re-set it after the fact.
     */
    private fun scheduleVolumeEnforcement() {
        val delays = longArrayOf(500, 1000, 2000, 4000, 8000)
        for (delay in delays) {
            handler.postDelayed({ forceMaxVolume() }, delay)
        }
    }

    /** Requests permanent audio focus for media playback. */
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

    /**
     * ALWAYS raises STREAM_MUSIC to MAXIMUM volume.
     *
     * Root cause of muted channels: many IPTV streams (CNN, Cartoon Network,
     * BBC, etc.) rely on Android's media stream volume (STREAM_MUSIC). If this
     * is 0 or very low, ExoPlayer plays the stream but there is no audible
     * output regardless of what Flutter's VideoPlayerController.setVolume(1.0)
     * does — that call only controls the player's *internal* gain, not the
     * hardware volume level.
     *
     * Fix: Always set STREAM_MUSIC to max before and after each stream starts.
     */
    private fun forceMaxVolume() {
        try {
            val am = audioManager ?: return
            val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val currentVol = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            // Only raise volume, never lower it — respect if user lowered it themselves
            // Actually for IPTV: always set to max since these are live streams.
            if (currentVol < maxVol) {
                am.setStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    maxVol,
                    0 // silent flag — no UI toast
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-acquire focus and restore volume when returning from background
        // (e.g. after a phone call, notification, or sleep)
        requestAudioFocus()
        forceMaxVolume()
    }

    /**
     * Ensure ALL TV remote key events are forwarded to Flutter.
     *
     * Some Android TV / Fire TV manufacturers (e.g. MediaTek, Amlogic) intercept
     * DPAD, ENTER, MEDIA_* keys before they reach the Flutter engine.  Overriding
     * dispatchKeyEvent and always deferring to super ensures Flutter's engine
     * (and therefore our HardwareKeyboard handler in Dart) sees every key event.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Always let Flutter’s engine handle the full dispatch chain.
        // Do NOT return true (consume) for remote keys here — that would
        // prevent Flutter from seeing them.
        return super.dispatchKeyEvent(event)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            // Also enforce when the window regains focus (TV remote wake events)
            forceMaxVolume()
            scheduleVolumeEnforcement()
        }
    }
}
