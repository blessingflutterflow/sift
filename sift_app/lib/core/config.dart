/// App-wide build flags.
///
/// [useBackend] gates the live Firebase/Twilio path. It stays `false` until the
/// Cloud Functions (Twilio OTP) are deployed, so the app runs fully in mock
/// mode for UI testing. Flip to `true` after `firebase deploy --only functions`.
class AppConfig {
  AppConfig._();

  static const bool useBackend = true;

  /// This build's version — compared against `config/pricing.minVersion` at
  /// startup for the force-update gate. Keep in sync with pubspec.yaml.
  static const String appVersion = '1.0.0';

  // Fare model (ZAR): base + per-km, multiplied per ride tier. PREVIEW ONLY —
  // the server recomputes the authoritative fare from config/pricing.
  static const double fareBase = 30.0;
  static const double farePerKm = 5.0;

  // ZEGOCLOUD in-app voice calling (rider ↔ driver). No phone number / no
  // telephony paperwork — calls run over data via the ZEGOCLOUD SDK.
  static const int zegoAppID = 935284315;
  static const String zegoAppSign =
      '65389ca237b8f8fd491854fd2e6d95a6b657fbab2af43630c67b505388837687';
}
