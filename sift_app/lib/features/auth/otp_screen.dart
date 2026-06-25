import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/otp_service.dart';
import '../../shared/widgets/primary_button.dart';
import 'auth_routing.dart';
import 'session_controller.dart';

/// OTP code entry — 6 digits with a resend countdown. UI-only: any 6-digit
/// code is accepted, then the user picks a role.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _timer;
  int _secondsLeft = 30;

  static const _length = 6;
  bool _verifying = false;

  bool get _complete => _controller.text.length == _length;

  Future<void> _onVerify() async {
    if (!AppConfig.useBackend) {
      context.go(AppRouter.roleSelect);
      return;
    }

    setState(() => _verifying = true);
    try {
      final phone = ref.read(sessionProvider).phone;
      final uid =
          await ref.read(otpServiceProvider).verifyOtp(phone, _controller.text);
      // Returning users go straight to their home; new users to role select.
      final dest = await resolvePostAuthDestination(ref, uid);
      if (mounted) context.go(dest);
    } on FirebaseFunctionsException catch (e) {
      final msg = switch (e.code) {
        'unauthenticated' => 'That code is incorrect.',
        'deadline-exceeded' => 'Your code expired — tap Resend for a new one.',
        _ => 'Could not verify the code. Try again.',
      };
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _startCountdown();
  }

  void _startCountdown() {
    setState(() => _secondsLeft = 30);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft == 0) {
        t.cancel();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = ref.watch(sessionProvider).phone;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Enter the code we sent',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.dark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      phone.isEmpty
                          ? 'We texted a 6-digit code to your phone.'
                          : 'We texted a 6-digit code to $phone.',
                      style: const TextStyle(
                          fontSize: 15, color: AppColors.muted, height: 1.4),
                    ),
                    const SizedBox(height: 28),
                    _codeField(),
                    const SizedBox(height: 24),
                    _resend(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: _verifying ? 'Verifying…' : 'Verify',
                enabled: _complete && !_verifying,
                onPressed: (_complete && !_verifying) ? _onVerify : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeField() {
    return Stack(
      children: [
        // The 6 visible boxes.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(_length, (i) => _box(i)),
        ),
        // Transparent capture field over the boxes.
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              keyboardType: TextInputType.number,
              showCursor: false,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(_length),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _box(int index) {
    final text = _controller.text;
    final filled = index < text.length;
    final active = index == text.length;
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 48,
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? AppColors.selectedFill : AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? AppColors.green
                : (filled ? AppColors.selectedBorder : Colors.transparent),
            width: 2,
          ),
        ),
        child: Text(
          filled ? text[index] : '',
          style: const TextStyle(
              fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.dark),
        ),
      ),
    );
  }

  Widget _resend() {
    if (_secondsLeft > 0) {
      return Text(
        'Resend code in 0:${_secondsLeft.toString().padLeft(2, '0')}',
        style: const TextStyle(fontSize: 15, color: AppColors.muted),
      );
    }
    return GestureDetector(
      onTap: _startCountdown,
      child: const Text(
        'Resend code',
        style: TextStyle(
            fontSize: 15, color: AppColors.green, fontWeight: FontWeight.w700),
      ),
    );
  }
}
