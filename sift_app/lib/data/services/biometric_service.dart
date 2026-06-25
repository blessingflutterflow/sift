import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device biometric unlock (fingerprint / Face ID).
///
/// Opt-in: the user enables "App lock" from the account menu. When enabled and
/// the device supports it, returning (already signed-in) users must pass a
/// biometric check at launch before reaching the app — see the splash screen.
class BiometricService {
  BiometricService();

  static const String _enabledKey = 'biometric_lock_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

  /// Hardware present and at least one biometric (or device credential) usable.
  Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  /// Whether a returning user should be challenged at launch.
  Future<bool> shouldLock() async {
    if (!await isEnabled()) return false;
    return isAvailable();
  }

  /// Prompt the device biometric sheet. Returns true only on success.
  Future<bool> authenticate({
    String reason = 'Unlock Sift to continue',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          // Allow the device PIN/pattern as a fallback so a user is never
          // locked out if a fingerprint fails to read.
          biometricOnly: false,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

final biometricServiceProvider =
    Provider<BiometricService>((ref) => BiometricService());
