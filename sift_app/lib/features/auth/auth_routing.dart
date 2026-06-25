import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../data/models/session.dart';
import '../../data/repositories/application_repository.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/call_service.dart';
import 'session_controller.dart';

/// Given a freshly-authenticated [uid], load the user's profile and decide
/// where they belong — restoring the session along the way. Used by both the
/// splash (cold start) and the OTP screen (active sign-in) so returning users
/// never re-onboard.
Future<String> resolvePostAuthDestination(WidgetRef ref, String uid) async {
  final snap = await ref.read(userRepositoryProvider).fetch(uid);

  // Authenticated but no profile yet → finish onboarding.
  if (snap == null || snap.role == null) {
    ref.read(sessionProvider.notifier).setUid(uid);
    return AppRouter.roleSelect;
  }

  ref.read(sessionProvider.notifier).hydrate(
        uid: uid,
        phone: snap.phone,
        role: snap.role,
        name: snap.name,
        email: snap.email,
        status: snap.status,
      );

  // Start listening for in-app calls (rider ↔ driver) for this user.
  unawaited(ref.read(callServiceProvider).init(uid, snap.name));

  if (snap.role == UserRole.rider) return AppRouter.home;

  // Driver — route by their application status.
  final appStatus =
      await ref.read(applicationRepositoryProvider).fetchStatus(uid);
  return switch (appStatus) {
    ApprovalStatus.approved => AppRouter.driverHome,
    ApprovalStatus.pending => AppRouter.pending,
    ApprovalStatus.rejected => AppRouter.rejected,
    ApprovalStatus.none => AppRouter.driverDocuments,
  };
}
