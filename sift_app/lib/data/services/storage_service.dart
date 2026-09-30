import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Uploads driver documents to Firebase Storage under
/// `applications/{uid}/{docType}.jpg` and returns the download URL.
class StorageService {
  StorageService({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  Future<String> uploadDocument({
    required String uid,
    required String docType,
    required File file,
  }) async {
    final ref = _storage.ref('applications/$uid/$docType.jpg');
    await ref
        .putFile(file, SettableMetadata(contentType: 'image/jpeg'))
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_uploadTimeout);
  }

  /// Profile picture for a rider or driver → `users/{uid}/profile.jpg`.
  Future<String> uploadProfilePhoto({
    required String uid,
    required File file,
  }) async {
    final ref = _storage.ref('users/$uid/profile.jpg');
    await ref
        .putFile(file, SettableMetadata(contentType: 'image/jpeg'))
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_uploadTimeout);
  }

  /// Rider identity verification image (`id` or `selfie`) → Storage path the
  /// `verifyRiderIdentity` function reads. Returns the download URL.
  Future<String> uploadVerification({
    required String uid,
    required String kind, // 'id' | 'selfie'
    required File file,
  }) async {
    final ref = _storage.ref('verifications/$uid/$kind.jpg');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  // Cap uploads so a Storage problem (unreachable bucket, App Check, network)
  // fails fast with an error the driver can retry — instead of the SDK retrying
  // silently for ~2 min, which looks like the app is frozen ("stuck after the
  // receiver signs" on proof-of-delivery).
  static const _uploadTimeout = Duration(seconds: 30);

  /// Proof-of-delivery photo for one parcel stop → download URL.
  Future<String> uploadParcelPhoto({
    required String parcelId,
    required int stopIndex,
    required File file,
  }) async {
    final ref = _storage.ref('parcels/$parcelId/pod/${stopIndex}_photo.jpg');
    await ref
        .putFile(file, SettableMetadata(contentType: 'image/jpeg'))
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_uploadTimeout);
  }

  /// Proof-of-delivery signature (PNG bytes) for one parcel stop → download URL.
  Future<String> uploadParcelSignature({
    required String parcelId,
    required int stopIndex,
    required Uint8List bytes,
  }) async {
    final ref = _storage.ref('parcels/$parcelId/pod/${stopIndex}_sig.png');
    await ref
        .putData(bytes, SettableMetadata(contentType: 'image/png'))
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_uploadTimeout);
  }
}

final storageServiceProvider =
    Provider<StorageService>((ref) => StorageService());
