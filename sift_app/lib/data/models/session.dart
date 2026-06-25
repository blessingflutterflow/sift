/// Roles a person can sign up as in the app. (Admin lives on the web.)
enum UserRole { rider, driver }

/// Approval lifecycle — the same contract the admin reads/writes.
/// Riders are auto-approved; drivers go pending until the admin decides.
enum ApprovalStatus {
  none,
  pending,
  approved,
  rejected;

  /// Parse the stored Firestore string back to an enum (defaults to none).
  static ApprovalStatus fromName(String? name) {
    return ApprovalStatus.values.firstWhere(
      (s) => s.name == name,
      orElse: () => ApprovalStatus.none,
    );
  }
}

/// In-memory session/onboarding state. UI-only for now (no backend);
/// a Firestore-backed repository will replace the mutations later.
class SessionState {
  const SessionState({
    this.uid,
    this.phone = '',
    this.role,
    this.name = '',
    this.email = '',
    this.status = ApprovalStatus.none,
    this.documentsSubmitted = false,
    this.documents = const {},
    this.rejectionReason,
  });

  final String? uid;
  final String phone;
  final UserRole? role;
  final String name;
  final String email;
  final ApprovalStatus status;
  final bool documentsSubmitted;

  /// Uploaded driver document download URLs, keyed by document type.
  final Map<String, String> documents;
  final String? rejectionReason;

  /// A rider is usable once they have a profile; a driver only once approved.
  bool get isAuthenticated {
    if (role == null || name.isEmpty) return false;
    if (role == UserRole.rider) return true;
    return status == ApprovalStatus.approved;
  }

  bool get isDriver => role == UserRole.driver;

  SessionState copyWith({
    String? uid,
    String? phone,
    UserRole? role,
    String? name,
    String? email,
    ApprovalStatus? status,
    bool? documentsSubmitted,
    Map<String, String>? documents,
    String? rejectionReason,
    bool clearRejection = false,
  }) {
    return SessionState(
      uid: uid ?? this.uid,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      name: name ?? this.name,
      email: email ?? this.email,
      status: status ?? this.status,
      documentsSubmitted: documentsSubmitted ?? this.documentsSubmitted,
      documents: documents ?? this.documents,
      rejectionReason:
          clearRejection ? null : (rejectionReason ?? this.rejectionReason),
    );
  }
}
