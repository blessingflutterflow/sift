import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session.dart';

/// Reads/writes `users/{uid}` — profile, role and approval status.
class UserRepository {
  UserRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');

  /// Create or update the signed-in user's profile. Status is set by the
  /// caller (rider → approved, driver → none until documents submitted).
  Future<void> upsertProfile({
    required String uid,
    required String phone,
    required UserRole role,
    required String name,
    required String email,
    required ApprovalStatus status,
  }) {
    return _users.doc(uid).set({
      'phone': phone,
      'role': role.name,
      'name': name,
      'email': email,
      'status': status.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<SessionSnapshot?> fetch(String uid) async {
    final doc = await _users.doc(uid).get();
    final data = doc.data();
    if (data == null) return null;
    return SessionSnapshot.fromMap(data);
  }

  /// Live approval status, so the app can react when the admin approves.
  Stream<ApprovalStatus> watchStatus(String uid) {
    return _users.doc(uid).snapshots().map(
          (d) => ApprovalStatus.fromName(d.data()?['status'] as String?),
        );
  }

  /// Live rider identity-verification status (unverified/pending/approved/
  /// rejected) — the verification + review screens react to this.
  Stream<String> watchVerification(String uid) {
    return _users.doc(uid).snapshots().map(
          (d) => (d.data()?['verificationStatus'] as String?) ?? 'unverified',
        );
  }
}

/// Lightweight read model for a user document.
class SessionSnapshot {
  const SessionSnapshot({
    required this.phone,
    required this.role,
    required this.name,
    required this.email,
    required this.status,
    required this.verificationStatus,
  });

  final String phone;
  final UserRole? role;
  final String name;
  final String email;
  final ApprovalStatus status;

  /// Rider identity verification: unverified | pending | approved | rejected.
  final String verificationStatus;

  factory SessionSnapshot.fromMap(Map<String, dynamic> map) {
    final roleName = map['role'] as String?;
    UserRole? role;
    for (final r in UserRole.values) {
      if (r.name == roleName) role = r;
    }
    return SessionSnapshot(
      phone: (map['phone'] as String?) ?? '',
      role: role,
      name: (map['name'] as String?) ?? '',
      email: (map['email'] as String?) ?? '',
      status: ApprovalStatus.fromName(map['status'] as String?),
      verificationStatus:
          (map['verificationStatus'] as String?) ?? 'unverified',
    );
  }
}

final userRepositoryProvider =
    Provider<UserRepository>((ref) => UserRepository());
