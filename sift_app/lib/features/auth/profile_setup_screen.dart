import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/config.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/storage_service.dart';
import '../../shared/widgets/primary_button.dart';
import 'session_controller.dart';

/// Basic profile. Saving sends a rider straight to Home (auto-approved) and a
/// driver into document upload.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() =>
      _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _picker = ImagePicker();
  File? _photo;
  bool _busy = false;

  /// Full name must be at least two words (name + surname), a valid-looking
  /// email, and a profile photo — all three are required to continue.
  bool get _hasFullName {
    final parts =
        _name.text.trim().split(RegExp(r'\s+')).where((p) => p.length >= 2);
    return parts.length >= 2;
  }

  bool get _valid =>
      _hasFullName && _email.text.contains('@') && _photo != null;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _email.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 75, maxWidth: 800);
    if (picked != null && mounted) setState(() => _photo = File(picked.path));
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final session = ref.read(sessionProvider.notifier);
    session.saveProfile(name: _name.text.trim(), email: _email.text.trim());
    final s = ref.read(sessionProvider);

    // Save the profile via the server callable — reliable (Admin SDK, no client
    // offline hang), so the name/role always lands and the user never shows as
    // "Unnamed" in admin. Falls back to a direct write, and is time-capped so a
    // slow network can NEVER trap the user on this screen; we always move on.
    if (AppConfig.useBackend && s.uid != null && s.role != null) {
      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west1')
            .httpsCallable('saveProfile')
            .call<Map<dynamic, dynamic>>({
              'name': s.name,
              'email': s.email,
              'phone': s.phone,
              'role': s.role!.name,
            })
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        debugPrint('saveProfile callable failed, falling back: $e');
        try {
          await ref
              .read(userRepositoryProvider)
              .upsertProfile(
                uid: s.uid!,
                phone: s.phone,
                role: s.role!,
                name: s.name,
                email: s.email,
                status: s.status,
              )
              .timeout(const Duration(seconds: 10));
        } catch (e2) {
          debugPrint('profile fallback write failed, continuing: $e2');
        }
      }

      // Profile photo (best-effort) → users/{uid}.photoUrl.
      if (_photo != null) {
        try {
          final url = await ref
              .read(storageServiceProvider)
              .uploadProfilePhoto(uid: s.uid!, file: _photo!);
          await FirebaseFirestore.instance
              .collection('users')
              .doc(s.uid!)
              .set({'photoUrl': url}, SetOptions(merge: true)).timeout(
                  const Duration(seconds: 12));
        } catch (e) {
          debugPrint('profile photo upload failed, continuing: $e');
        }
      }
    }

    if (mounted) {
      // Riders go straight to identity verification before they can ride.
      context.go(s.isDriver
          ? AppRouter.driverDocuments
          : AppRouter.riderVerification);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      'Set up your profile',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.dark,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Center(child: _avatar()),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        _photo == null
                            ? 'Tap to add a profile photo (required)'
                            : 'Tap to change photo',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _photo == null
                              ? const Color(0xFFE0524D)
                              : AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _label('Full name'),
                    _field(_name, 'Jane Doe', TextInputType.name),
                    if (_name.text.trim().isNotEmpty && !_hasFullName)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text('Please enter your name and surname.',
                            style: TextStyle(
                                fontSize: 12.5, color: Color(0xFFE0524D))),
                      ),
                    const SizedBox(height: 18),
                    _label('Email'),
                    _field(_email, 'jane@example.com',
                        TextInputType.emailAddress),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: _busy ? 'Saving…' : 'Continue',
                enabled: _valid && !_busy,
                onPressed: (_valid && !_busy) ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar() {
    return GestureDetector(
      onTap: _pickPhoto,
      child: Stack(
        children: [
          Container(
            width: 96,
            height: 96,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.field,
              shape: BoxShape.circle,
              image: _photo != null
                  ? DecorationImage(
                      image: FileImage(_photo!), fit: BoxFit.cover)
                  : null,
            ),
            child: _photo != null
                ? null
                : const Icon(Icons.person, size: 44, color: AppColors.muted),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.green,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.camera_alt, size: 15, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.dark)),
      );

  Widget _field(
      TextEditingController controller, String hint, TextInputType type) {
    return TextField(
      controller: controller,
      keyboardType: type,
      style: const TextStyle(fontSize: 16, color: AppColors.dark),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.muted),
        filled: true,
        fillColor: AppColors.field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.green, width: 2),
        ),
      ),
    );
  }
}
