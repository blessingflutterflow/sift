import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/session.dart';
import '../../data/services/call_service.dart';
import '../../data/services/notification_service.dart';

/// Holds the current onboarding/session state and the transitions between
/// flow steps. Mutations are local for now; swapping in a Firestore-backed
/// repository later only touches this class, not the screens.
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  void setPhone(String phone) => state = state.copyWith(phone: phone);

  void setUid(String uid) => state = state.copyWith(uid: uid);

  /// Restore a returning user's session (auto-login) from their stored profile.
  void hydrate({
    required String uid,
    required String phone,
    required UserRole? role,
    required String name,
    required String email,
    required ApprovalStatus status,
  }) {
    state = SessionState(
      uid: uid,
      phone: phone,
      role: role,
      name: name,
      email: email,
      status: status,
    );
  }

  void setRole(UserRole role) => state = state.copyWith(role: role);

  /// Update display/contact info after a profile edit (status untouched).
  void updateContact({required String name, required String email}) =>
      state = state.copyWith(name: name, email: email);

  void setDocuments(Map<String, String> documents) =>
      state = state.copyWith(documents: documents);

  void setDocExpiry(Map<String, String> docExpiry) =>
      state = state.copyWith(docExpiry: docExpiry);

  /// Saving the profile finalizes a rider (auto-approved) but leaves a driver
  /// at `none` until they submit documents.
  void saveProfile({required String name, required String email}) {
    state = state.copyWith(
      name: name,
      email: email,
      status: state.role == UserRole.rider
          ? ApprovalStatus.approved
          : ApprovalStatus.none,
    );
  }

  /// Driver submitted licence / ID / vehicle docs → goes pending for review.
  void submitDriverApplication() {
    state = state.copyWith(
      documentsSubmitted: true,
      status: ApprovalStatus.pending,
      clearRejection: true,
    );
  }

  // --- Mocked admin actions (stand in for the web dashboard) ---
  void mockApprove() => state = state.copyWith(status: ApprovalStatus.approved);

  void mockReject(String reason) =>
      state = state.copyWith(status: ApprovalStatus.rejected, rejectionReason: reason);

  Future<void> signOut() async {
    // Stop pushes + call listeners to this device before the identity goes away.
    await ref.read(notificationServiceProvider).unregister();
    await ref.read(callServiceProvider).uninit();
    await FirebaseAuth.instance.signOut();
    state = const SessionState();
  }
}

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
