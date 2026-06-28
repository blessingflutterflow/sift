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
    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return ref.getDownloadURL();
  }

  /// Proof-of-delivery photo for one parcel stop → download URL.
  Future<String> uploadParcelPhoto({
    required String parcelId,
    required int stopIndex,
    required File file,
  }) async {
    final ref = _storage.ref('parcels/$parcelId/pod/${stopIndex}_photo.jpg');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  /// Proof-of-delivery signature (PNG bytes) for one parcel stop → download URL.
  Future<String> uploadParcelSignature({
    required String parcelId,
    required int stopIndex,
    required Uint8List bytes,
  }) async {
    final ref = _storage.ref('parcels/$parcelId/pod/${stopIndex}_sig.png');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/png'));
    return ref.getDownloadURL();
  }
}

final storageServiceProvider =
    Provider<StorageService>((ref) => StorageService());
