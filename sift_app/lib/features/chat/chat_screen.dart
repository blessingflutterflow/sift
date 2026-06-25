import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/chat_repository.dart';

/// Navigation args for the chat route.
class ChatArgs {
  const ChatArgs({
    required this.rideId,
    required this.currentUserId,
    required this.currentUserRole,
    required this.currentUserName,
    required this.otherUserName,
  });

  final String rideId;
  final String currentUserId;
  final String currentUserRole;
  final String currentUserName;
  final String otherUserName;
}

/// Rider ↔ driver in-app chat for a ride. The UI is Flyer's `flutter_chat_ui`
/// (backend-agnostic); we stream messages from Firestore into its controller
/// and write new ones back. Identical on iOS and Android.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.rideId,
    required this.currentUserId,
    required this.currentUserRole,
    required this.currentUserName,
    required this.otherUserName,
  });

  final String rideId;
  final String currentUserId;
  final String currentUserRole; // 'rider' | 'driver'
  final String currentUserName;
  final String otherUserName;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final InMemoryChatController _controller = InMemoryChatController();
  final Set<String> _seen = {};
  StreamSubscription<List<RideChatMessage>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(chatRepositoryProvider)
        .watch(widget.rideId)
        .listen(_onMessages);
  }

  /// Insert any messages we haven't shown yet (append-only chat) so the stream
  /// stays the single source of truth — including our own sent messages.
  void _onMessages(List<RideChatMessage> messages) {
    for (final m in messages) {
      if (_seen.contains(m.id)) continue;
      _seen.add(m.id);
      _controller.insertMessage(
        TextMessage(
          id: m.id,
          authorId: m.senderId,
          createdAt: (m.createdAt ?? DateTime.now()).toUtc(),
          text: m.text,
        ),
      );
    }
  }

  void _send(String text) {
    ref.read(chatRepositoryProvider).send(
          widget.rideId,
          text: text,
          senderId: widget.currentUserId,
          senderRole: widget.currentUserRole,
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.otherUserName.isEmpty ? 'Chat' : widget.otherUserName,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.dark),
            ),
            const Text('Trip chat',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ],
        ),
      ),
      body: Chat(
        chatController: _controller,
        currentUserId: widget.currentUserId,
        onMessageSend: _send,
        resolveUser: (UserID id) async {
          return User(
            id: id,
            name: id == widget.currentUserId
                ? (widget.currentUserName.isEmpty
                    ? 'You'
                    : widget.currentUserName)
                : (widget.otherUserName.isEmpty
                    ? 'Driver'
                    : widget.otherUserName),
          );
        },
      ),
    );
  }
}
