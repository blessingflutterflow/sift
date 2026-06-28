import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/storage_service.dart';
import '../../shared/widgets/primary_button.dart';
import 'session_controller.dart';

/// Rider identity check (anti-fraud): capture an ID photo + a live selfie, then
/// AWS Rekognition confirms they're the same person. Auto-approves on a strong
/// match, sends borderline cases to admin review.
class RiderVerificationScreen extends ConsumerStatefulWidget {
  const RiderVerificationScreen({super.key});

  @override
  ConsumerState<RiderVerificationScreen> createState() =>
      _RiderVerificationScreenState();
}

class _RiderVerificationScreenState
    extends ConsumerState<RiderVerificationScreen> {
  final _picker = ImagePicker();
  File? _idPhoto;
  File? _selfie;
  bool _submitting = false;
  String? _error;

  Future<void> _pickId() async {
    final x = await _picker.pickImage(
        source: ImageSource.camera, imageQuality: 80, maxWidth: 1600);
    if (x != null && mounted) setState(() => _idPhoto = File(x.path));
  }

  Future<void> _pickSelfie() async {
    final x = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 80,
      maxWidth: 1600,
    );
    if (x != null && mounted) setState(() => _selfie = File(x.path));
  }

  Future<void> _submit() async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null || _idPhoto == null || _selfie == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final storage = ref.read(storageServiceProvider);
      await storage.uploadVerification(uid: uid, kind: 'id', file: _idPhoto!);
      await storage.uploadVerification(
          uid: uid, kind: 'selfie', file: _selfie!);
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('verifyRiderIdentity')
          .call<Map<dynamic, dynamic>>();
      // Result is reflected via the live verificationStatus stream below.
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ??
            'Could not verify. Retake your photos in good light.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(sessionProvider).uid;
    return Scaffold(
      backgroundColor: Colors.white,
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<String>(
              stream: ref.read(userRepositoryProvider).watchVerification(uid),
              builder: (context, snap) {
                final status = snap.data ?? 'unverified';
                if (status == 'approved') {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) context.go(AppRouter.home);
                  });
                  return const Center(
                      child: CircularProgressIndicator(color: AppColors.green));
                }
                if (status == 'pending') return _underReview();
                return _capture(rejected: status == 'rejected');
              },
            ),
    );
  }

  Widget _underReview() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.hourglass_top, size: 64, color: AppColors.green),
            const SizedBox(height: 20),
            const Text('Verification under review',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            const Text(
              'Thanks! We need a quick manual check on your photos. This is '
              'usually fast — you can keep this screen open.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.5),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () async {
                await ref.read(sessionProvider.notifier).signOut();
                if (mounted) context.go(AppRouter.verification);
              },
              child: const Text('Sign out',
                  style: TextStyle(color: AppColors.muted)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _capture({required bool rejected}) {
    final ready = _idPhoto != null && _selfie != null;
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              children: [
                const Text('Verify your identity',
                    style: TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text(
                  'For everyone\'s safety, we check that you match your ID '
                  'before your first trip. Your photos are kept private.',
                  style: TextStyle(color: AppColors.muted, height: 1.5),
                ),
                if (rejected) ...[
                  const SizedBox(height: 14),
                  _banner(
                      'That didn\'t match. Retake a clear ID photo and selfie in good light.',
                      const Color(0xFFE0524D)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  _banner(_error!, const Color(0xFFE0524D)),
                ],
                const SizedBox(height: 24),
                _captureTile(
                  label: 'Photo of your ID',
                  hint: 'ID card, passport or licence — face clearly visible',
                  icon: Icons.badge_outlined,
                  file: _idPhoto,
                  onTap: _pickId,
                ),
                const SizedBox(height: 14),
                _captureTile(
                  label: 'Selfie',
                  hint: 'Look straight at the camera in good light',
                  icon: Icons.face_outlined,
                  file: _selfie,
                  onTap: _pickSelfie,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: PrimaryButton(
              label: _submitting ? 'Verifying…' : 'Submit for verification',
              enabled: ready && !_submitting,
              onPressed: (ready && !_submitting) ? _submit : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _captureTile({
    required String label,
    required String hint,
    required IconData icon,
    required File? file,
    required VoidCallback onTap,
  }) {
    final done = file != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: done ? AppColors.selectedFill : AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: done ? AppColors.selectedBorder : AppColors.line),
        ),
        child: Row(
          children: [
            if (done)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(file,
                    width: 56, height: 56, fit: BoxFit.cover),
              )
            else
              Icon(icon, size: 32, color: AppColors.muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(done ? 'Tap to retake' : hint,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.muted)),
                ],
              ),
            ),
            Icon(done ? Icons.check_circle : Icons.camera_alt_outlined,
                color: done ? AppColors.green : AppColors.muted),
          ],
        ),
      ),
    );
  }
}
