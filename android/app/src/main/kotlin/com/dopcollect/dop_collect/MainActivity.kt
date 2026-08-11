package com.dopcollect.dop_collect

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dop_collect/app"

    // FLAG_SECURE: the app shows customer names, account numbers, amounts and a
    // live banking login form (password field) inside the sync WebView. This
    // keeps all of it out of the Android recents thumbnail (persisted to disk),
    // screenshots, screen recorders and MediaProjection/casting captures.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "restart") {
                    result.success(true)
                    restartApp()
                } else {
                    result.notImplemented()
                }
            }
    }

    // Full restart: launch a fresh task, then kill this process. The relaunch is
    // a genuine COLD start, which is what makes the app pick up a downloaded
    // Shorebird patch. (Same mechanism the restart_app plugin uses, but built in
    // so there's no third-party Gradle dependency.)
    private fun restartApp() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        startActivity(intent)
        Runtime.getRuntime().exit(0)
    }
}
