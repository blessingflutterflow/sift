package za.co.sift.app

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so
// the biometric prompt can attach to the host fragment activity.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the floating "online" bubble bring the app back to the front when
        // tapped. Apps holding SYSTEM_ALERT_WINDOW are exempt from Android's
        // background-activity-start restriction, so this works from the overlay.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sift/app")
            .setMethodCallHandler { call, result ->
                if (call.method == "bringToFront") {
                    val intent = Intent(this, MainActivity::class.java).apply {
                        addFlags(
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_NEW_TASK
                        )
                    }
                    startActivity(intent)
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
    }
}
