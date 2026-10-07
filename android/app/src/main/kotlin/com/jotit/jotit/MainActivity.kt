package com.jotit.jotit

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * §8.3: `FLAG_SECURE` disables screenshots and blanks the recents thumbnail.
 *
 * **Why the value is cached here rather than asked for.** The screenshot this
 * flag exists to stop is taken while the app sits in the background — and by
 * then the process has usually been killed to reclaim memory. A flag that only
 * exists while Dart is running protects the screenshot the user takes while
 * looking at the app, and lets through the one an attacker takes while it is
 * in the recents list, which is the more valuable of the two.
 *
 * So the Dart side owns the truth (whether a PIN exists) and pushes it here;
 * this side persists it in SharedPreferences and re-applies it in `onCreate`
 * and `onResume`. `onCreate` runs before Flutter has drawn a single frame, so
 * the launch screen itself is already covered, and `onResume` covers the case
 * where something else cleared the window flags.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.jotit/screen_security"
    private val preferencesName = "com.jotit.screen_security"
    private val flagKey = "flag_secure"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The window exists after super.onCreate, and Flutter has not drawn a
        // frame yet — this is the earliest point at which the launch screen
        // can be covered. Waiting for Dart would leave it exposed.
        applyFlagSecure()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result ->
                when (call.method) {
                    "setFlagSecure" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        getSharedPreferences(preferencesName, MODE_PRIVATE)
                            .edit()
                            .putBoolean(flagKey, enabled)
                            .apply()
                        runOnUiThread {
                            applyFlagSecure()
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        applyFlagSecure()
    }

    /**
     * Idempotent, and deliberately reads the cached value rather than any
     * in-memory copy of it: the whole point of the cache is that it survives
     * the Dart isolate, and a field would not.
     */
    private fun applyFlagSecure() {
        val secure = getSharedPreferences(preferencesName, MODE_PRIVATE)
            .getBoolean(flagKey, false)
        if (secure) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}
