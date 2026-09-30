import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One support message between a user and the Sift support team.
/// Stored at `support_threads/{uid}/messages/{id}`.
class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.text,
    required this.senderRole, // 'user' | 'admin'
    this.createdAt,
  });

  final String id;
  final String text;
  final String senderRole;
  final DateTime? createdAt;

  bool get fromUser => senderRole == 'user';

  factory SupportMessage.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return SupportMessage(
      id: d.id,
      text: (m['text'] ?? '').toString(),
      senderRole: (m['senderRole'] ?? 'user').toString(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Client side of the in-app support chat. One thread per user; the admin
/// dashboard reads/replies on the other end.
class SupportRepository {
  SupportRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _thread(String uid) =>
      _db.collection('support_threads').doc(uid);

  CollectionReference<Map<String, dynamic>> _messages(String uid) =>
      _thread(uid).collection('messages');

  Stream<List<SupportMessage>> watch(String uid) => _messages(uid)
      .orderBy('createdAt')
      .snapshots()
      .map((s) => s.docs.map(SupportMessage.fromDoc).toList());

  Future<void> send({
    required String uid,
    required String text,
    required String userName,
    required String userRole,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _messages(uid).add({
      'text': trimmed,
      'senderId': uid,
      'senderRole': 'user',
      'createdAt': FieldValue.serverTimestamp(),
    });
    // Thread summary so the admin list can show who's waiting.
    await _thread(uid).set({
      'uid': uid,
      'userName': userName,
      'userRole': userRole,
      'lastMessage': trimmed,
      'lastAt': FieldValue.serverTimestamp(),
      'unreadForAdmin': true,
      'unreadForUser': false,
    }, SetOptions(merge: true));
  }

  /// Clear the user's unread flag when they open the chat.
  Future<void> markReadByUser(String uid) =>
      _thread(uid).set({'unreadForUser': false}, SetOptions(merge: true));
}

final supportRepositoryProvider =
    Provider<SupportRepository>((ref) => SupportRepository());
