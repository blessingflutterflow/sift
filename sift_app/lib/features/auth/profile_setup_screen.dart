import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/user_repository.dart';
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
  bool _photoAdded = false;

  bool get _valid =>
      _name.text.trim().length >= 2 && _email.text.contains('@');

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

  Future<void> _submit() async {
    final session = ref.read(sessionProvider.notifier);
    session.saveProfile(name: _name.text.trim(), email: _email.text.trim());
    final s = ref.read(sessionProvider);

    if (AppConfig.useBackend && s.uid != null && s.role != null) {
      await ref.read(userRepositoryProvider).upsertProfile(
            uid: s.uid!,
            phone: s.phone,
            role: s.role!,
            name: s.name,
            email: s.email,
            status: s.status,
          );
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
                    const SizedBox(height: 28),
                    _label('Full name'),
                    _field(_name, 'Jane Doe', TextInputType.name),
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
                label: 'Continue',
                enabled: _valid,
                onPressed: _valid ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar() {
    return GestureDetector(
      onTap: () => setState(() => _photoAdded = !_photoAdded),
      child: Stack(
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: _photoAdded ? AppColors.selectedFill : AppColors.field,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _photoAdded ? Icons.check : Icons.person,
              size: 44,
              color: _photoAdded ? AppColors.green : AppColors.muted,
            ),
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
