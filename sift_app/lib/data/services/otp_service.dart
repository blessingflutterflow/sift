import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Talks to the Cloud Functions that wrap Twilio Verify, then establishes a
/// Firebase session from the returned custom token.
///
/// Region must match the deployed functions (europe-west1).
class OtpService {
  OtpService({FirebaseFunctions? functions, FirebaseAuth? auth})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  /// Triggers an SMS code to [phone] (E.164, e.g. "+447700900123").
  Future<void> sendOtp(String phone) async {
    await _functions.httpsCallable('sendOtp').call(<String, dynamic>{
      'phone': phone,
    });
  }

  /// Verifies [code]; on success signs the user into Firebase and returns uid.
  /// Throws [FirebaseFunctionsException] (e.g. code 'unauthenticated') on a bad
  /// or expired code.
  Future<String> verifyOtp(String phone, String code) async {
    final result = await _functions.httpsCallable('verifyOtp').call(
      <String, dynamic>{'phone': phone, 'code': code},
    );
    final token = (result.data as Map)['token'] as String;
    final cred = await _auth.signInWithCustomToken(token);
    return cred.user!.uid;
  }

  String? get currentUid => _auth.currentUser?.uid;

  Future<void> signOut() => _auth.signOut();
}

final otpServiceProvider = Provider<OtpService>((ref) => OtpService());
