package com.example.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen(isAlarmLaunch(intent))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showOverLockScreen(isAlarmLaunch(intent))
    }

    override fun onStop() {
        super.onStop()
        showOverLockScreen(false)
    }

    // flutter_local_notifications opens the app with this action; the only
    // local notification we post is the emergency alarm (full-screen intent).
    private fun isAlarmLaunch(intent: Intent?) = intent?.action == "SELECT_NOTIFICATION"

    // Wake the screen and show over the lock screen like an incoming call, but
    // only for the alarm: doing it on every launch would let anyone use the
    // app on a locked phone.
    private fun showOverLockScreen(show: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(show)
            setTurnScreenOn(show)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (show) window.addFlags(flags) else window.clearFlags(flags)
        }
    }
}
