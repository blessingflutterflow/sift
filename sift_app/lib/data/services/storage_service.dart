import 'dart:io';

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
}

final storageServiceProvider =
    Provider<StorageService>((ref) => StorageService());
