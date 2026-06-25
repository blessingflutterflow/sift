import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:zego_uikit_signaling_plugin/zego_uikit_signaling_plugin.dart';

import '../../core/config.dart';

/// In-app voice calling via ZEGOCLOUD (VoIP over data — no phone number).
///
/// The call identity is the user's Firebase uid, so the rider can call the
/// driver (and vice-versa) using the ids already on the ride doc. Init once
/// after sign-in so the SDK listens for incoming calls; uninit on sign-out.
class CallService {
  bool _inited = false;

  Future<void> init(String userId, String userName) async {
    // Native VoIP isn't available on web — calling stays an Android/iOS feature.
    if (kIsWeb || _inited || userId.isEmpty) return;
    _inited = true;
    await ZegoUIKitPrebuiltCallInvitationService().init(
      appID: AppConfig.zegoAppID,
      appSign: AppConfig.zegoAppSign,
      userID: userId,
      userName: userName.isEmpty ? 'Sift user' : userName,
      plugins: [ZegoUIKitSignalingPlugin()],
    );
  }

  Future<void> uninit() async {
    if (!_inited) return;
    _inited = false;
    await ZegoUIKitPrebuiltCallInvitationService().uninit();
  }
}

final callServiceProvider = Provider<CallService>((ref) => CallService());
