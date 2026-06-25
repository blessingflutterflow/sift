import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session.dart';

/// Reads/writes `applications/{uid}` — the driver onboarding submission the
/// admin reviews. Created as `pending`; approve/reject is server/admin only.
class ApplicationRepository {
  ApplicationRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _applications =>
      _db.collection('applications');

  Future<void> submit({
    required String uid,
    required UserRole role,
    required Map<String, dynamic> vehicle,
    required Map<String, String> documents,
  }) {
    return _applications.doc(uid).set({
      'uid': uid,
      'role': role.name,
      'status': ApprovalStatus.pending.name,
      'vehicle': vehicle,
      'documents': documents,
      'submittedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Live status of the driver's application (mirrors users/{uid}.status).
  Stream<ApprovalStatus> watchStatus(String uid) {
    return _applications.doc(uid).snapshots().map(
          (d) => ApprovalStatus.fromName(d.data()?['status'] as String?),
        );
  }

  /// One-shot status read — `none` if no application exists yet.
  Future<ApprovalStatus> fetchStatus(String uid) async {
    final doc = await _applications.doc(uid).get();
    if (!doc.exists) return ApprovalStatus.none;
    return ApprovalStatus.fromName(doc.data()?['status'] as String?);
  }

  /// Whether payout (bank) details are on file for this driver.
  Future<bool> hasPayout(String uid) async {
    final doc = await _applications.doc(uid).get();
    final p = doc.data()?['payout'] as Map<String, dynamic>?;
    return p != null && (p['accountNumber'] ?? '').toString().isNotEmpty;
  }

  Future<String?> rejectionReason(String uid) async {
    final doc = await _applications.doc(uid).get();
    return doc.data()?['rejectionReason'] as String?;
  }
}

final applicationRepositoryProvider =
    Provider<ApplicationRepository>((ref) => ApplicationRepository());
