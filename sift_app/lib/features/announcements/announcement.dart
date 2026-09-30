import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';

/// An admin broadcast shown full-screen to drivers until each one dismisses it.
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.severity,
    required this.active,
    this.createdAt,
  });

  final String id;
  final String title;
  final String body;

  /// 'info' | 'warning' | 'critical' — drives the color/icon of the takeover.
  final String severity;
  final bool active;
  final DateTime? createdAt;

  factory Announcement.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    return Announcement(
      id: d.id,
      title: (m['title'] ?? 'Sift announcement').toString(),
      body: (m['body'] ?? '').toString(),
      severity: (m['severity'] ?? 'info').toString(),
      active: m['active'] != false,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Broadcasts aimed at everyone or at this user's whole role. A single whereIn
/// filter needs no composite index; `active` is filtered client-side.
final _broadcastAnnouncementsProvider =
    StreamProvider<List<Announcement>>((ref) {
  final session = ref.watch(sessionProvider);
  if (session.uid == null) return Stream.value(const []);
  final roleAudience = session.isDriver ? 'all_drivers' : 'all_riders';
  return FirebaseFirestore.instance
      .collection('announcements')
      .where('audience', whereIn: ['everyone', roleAudience])
      .snapshots()
      .map((s) => s.docs.map(Announcement.fromDoc).toList());
});

/// Announcements addressed to this specific user (audience == 'specific'). A
/// single array-contains filter — no composite index.
final _targetedAnnouncementsProvider =
    StreamProvider<List<Announcement>>((ref) {
  final uid = ref.watch(sessionProvider).uid;
  if (uid == null) return Stream.value(const []);
  return FirebaseFirestore.instance
      .collection('announcements')
      .where('targetUids', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map(Announcement.fromDoc).toList());
});

/// The set of announcement ids this driver has already dismissed (mirrored on
/// their user doc so the app can filter cheaply on every open).
final _dismissedAnnouncementsProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(sessionProvider).uid;
  if (uid == null) return Stream.value(const <String>{});
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((d) => ((d.data()?['dismissedAnnouncements'] as List?) ?? const [])
          .map((e) => e.toString())
          .toSet());
});

/// Active announcements addressed to this user (by role, everyone, or directly)
/// that they haven't dismissed yet — newest first. Merges the broadcast and
/// targeted streams and de-dupes by id.
final pendingAnnouncementsProvider = Provider<List<Announcement>>((ref) {
  final broadcast =
      ref.watch(_broadcastAnnouncementsProvider).value ?? const [];
  final targeted = ref.watch(_targetedAnnouncementsProvider).value ?? const [];
  final dismissed =
      ref.watch(_dismissedAnnouncementsProvider).value ?? const <String>{};

  final byId = <String, Announcement>{};
  for (final a in [...broadcast, ...targeted]) {
    if (a.active && !dismissed.contains(a.id)) byId[a.id] = a;
  }
  final list = byId.values.toList();
  list.sort((a, b) =>
      (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
  return list;
});

/// Records a dismissal: a per-announcement `reads/{uid}` doc (so admin can show
/// a "seen by N" count) plus the id on the user doc (so the app filters fast).
final announcementRepositoryProvider =
    Provider<AnnouncementRepository>((ref) => AnnouncementRepository(ref));

class AnnouncementRepository {
  AnnouncementRepository(this._ref);
  final Ref _ref;

  Future<void> dismiss(String id) async {
    final uid = _ref.read(sessionProvider).uid;
    if (uid == null) return;
    final db = FirebaseFirestore.instance;
    try {
      await db
          .collection('announcements')
          .doc(id)
          .collection('reads')
          .doc(uid)
          .set({'uid': uid, 'at': FieldValue.serverTimestamp()});
      await db.collection('users').doc(uid).set({
        'dismissedAnnouncements': FieldValue.arrayUnion([id]),
      }, SetOptions(merge: true));
    } catch (_) {/* best-effort; overlay hides optimistically */}
  }
}
