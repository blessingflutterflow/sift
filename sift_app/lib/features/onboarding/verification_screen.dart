import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/otp_service.dart';
import '../auth/session_controller.dart';

/// Phone verification — Screen 3, refined for real mobile use.
///
/// Intent: the user enters their phone number and picks how they want to
/// receive the verification code, then continues. The system keyboard
/// appears when the field is tapped (no fake on-screen keypad).
class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({super.key});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

enum _CodeChannel { sms, whatsapp }

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  final _controller = TextEditingController();
  _CodeChannel _channel = _CodeChannel.sms;

  // Default to United Kingdom; the compact picker opens the full list.
  String _flag = '🇬🇧';
  String _dialCode = '44';
  bool _sending = false;

  bool get _canContinue => _controller.text.trim().length >= 6;

  Future<void> _onContinue() async {
    // Build clean E.164: digits only, drop the national trunk-prefix 0
    // (e.g. SA "067…" → "+2767…", not "+27067…").
    final national =
        _controller.text.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');
    final phone = '+$_dialCode$national';
    ref.read(sessionProvider.notifier).setPhone(phone);

    if (!AppConfig.useBackend) {
      context.go(AppRouter.otp);
      return;
    }

    setState(() => _sending = true);
    try {
      await ref.read(otpServiceProvider).sendOtp(phone);
      if (mounted) context.go(AppRouter.otp);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send the code. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openCountryPicker() {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      onSelect: (Country country) {
        setState(() {
          _flag = country.flagEmoji;
          _dialCode = country.phoneCode;
        });
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // Lets the Continue button lift above the keyboard when it appears.
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "We'll send a code for verification",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.dark,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _phoneRow(),
                    const SizedBox(height: 24),
                    _choice(
                      icon: Icons.sms_outlined,
                      title: 'Get a code via SMS',
                      subtitle: 'Standard text messaging rates may apply.',
                      selected: _channel == _CodeChannel.sms,
                      onTap: () => setState(() => _channel = _CodeChannel.sms),
                    ),
                    const Divider(height: 1, color: AppColors.line),
                    _choice(
                      icon: Icons.chat_bubble_outline,
                      title: 'Get a code via WhatsApp',
                      subtitle:
                          'We will not send you anything else without your consent.',
                      selected: _channel == _CodeChannel.whatsapp,
                      onTap: () =>
                          setState(() => _channel = _CodeChannel.whatsapp),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'We will not send anything without your consent.',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // CTA pinned at the bottom, lifts above the keyboard.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: _continueButton(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phoneRow() {
    return Row(
      children: [
        // Compact country selector — flag + dial code only. Tapping opens the
        // full searchable country list, keeping the number field as wide as
        // possible.
        GestureDetector(
          onTap: _openCountryPicker,
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_flag, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 4),
                Text('+$_dialCode',
                    style: const TextStyle(fontSize: 16, color: AppColors.dark)),
                const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Number field — real input, system keyboard on tap.
        Expanded(
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
              LengthLimitingTextInputFormatter(15),
            ],
            style: const TextStyle(fontSize: 18, color: AppColors.dark),
            decoration: InputDecoration(
              hintText: 'Phone number',
              hintStyle: const TextStyle(color: AppColors.muted),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              filled: true,
              fillColor: Colors.white,
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.cancel,
                          size: 20, color: Color(0xFFA7AAB2)),
                      onPressed: () => _controller.clear(),
                    ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.line, width: 1.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.green, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _choice({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            Icon(icon, size: 26, color: const Color(0xFF7B7E86)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: AppColors.dark)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _Radio(selected: selected),
          ],
        ),
      ),
    );
  }

  Widget _continueButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: (_canContinue && !_sending) ? _onContinue : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          disabledBackgroundColor: AppColors.green.withValues(alpha: 0.4),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        child: _sending
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white),
              )
            : const Text('Continue',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppColors.green : const Color(0xFFB8BAC3),
          width: selected ? 8 : 2,
        ),
      ),
    );
  }
}
