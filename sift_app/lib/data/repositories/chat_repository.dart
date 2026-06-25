import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One chat message on a ride (stored at `rides/{rideId}/messages/{id}`).
class RideChatMessage {
  const RideChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderRole,
    this.createdAt,
  });

  final String id;
  final String text;
  final String senderId;
  final String senderRole; // 'rider' | 'driver'
  final DateTime? createdAt;

  factory RideChatMessage.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return RideChatMessage(
      id: d.id,
      text: (m['text'] ?? '').toString(),
      senderId: (m['senderId'] ?? '').toString(),
      senderRole: (m['senderRole'] ?? '').toString(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Rider ↔ driver chat for a ride. Messages are a Firestore subcollection;
/// the [Chat] UI is wired to [watch]/[send]. A Cloud Function pushes the other
/// party on each new message.
class ChatRepository {
  ChatRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _messages(String rideId) =>
      _db.collection('rides').doc(rideId).collection('messages');

  /// Messages oldest-first (chat order).
  Stream<List<RideChatMessage>> watch(String rideId) {
    return _messages(rideId)
        .orderBy('createdAt')
        .snapshots()
        .map((s) => s.docs.map(RideChatMessage.fromDoc).toList());
  }

  Future<void> send(
    String rideId, {
    required String text,
    required String senderId,
    required String senderRole,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _messages(rideId).add({
      'senderId': senderId,
      'senderRole': senderRole,
      'text': trimmed.length > 500 ? trimmed.substring(0, 500) : trimmed,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

final chatRepositoryProvider =
    Provider<ChatRepository>((ref) => ChatRepository());
