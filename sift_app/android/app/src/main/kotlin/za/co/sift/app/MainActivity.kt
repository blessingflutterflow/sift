package za.co.sift.app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so
// the biometric prompt can attach to the host fragment activity.
class MainActivity : FlutterFragmentActivity()
