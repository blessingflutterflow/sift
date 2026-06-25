import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/services/storage_service.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../auth/session_controller.dart';

/// Driver document upload. Tapping a row picks a photo (camera/gallery) and
/// uploads it to Firebase Storage; the download URL is stored on the session
/// and submitted with the application. In mock mode it just marks as uploaded.
class DriverDocumentsScreen extends ConsumerStatefulWidget {
  const DriverDocumentsScreen({super.key});

  @override
  ConsumerState<DriverDocumentsScreen> createState() =>
      _DriverDocumentsScreenState();
}

class _Doc {
  const _Doc(this.key, this.label, this.icon);
  final String key;
  final String label;
  final IconData icon;
}

class _DriverDocumentsScreenState
    extends ConsumerState<DriverDocumentsScreen> {
  static const _docs = [
    _Doc('licence', "Driver's licence", Icons.badge_outlined),
    _Doc('id', 'National ID or passport', Icons.contact_page_outlined),
    _Doc('vehicle_reg', 'Vehicle registration', Icons.description_outlined),
    _Doc('photo', 'Profile photo', Icons.account_circle_outlined),
  ];

  final Map<String, String> _uploaded = {}; // key -> download URL
  final Set<String> _uploading = {};
  final _picker = ImagePicker();

  bool get _allUploaded => _uploaded.length == _docs.length;

  Future<void> _pick(_Doc doc) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFE6E6E8),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;

    // Mock mode: just mark it as done without picking/uploading.
    if (!AppConfig.useBackend) {
      setState(() => _uploaded[doc.key] = 'mock');
      return;
    }

    final picked =
        await _picker.pickImage(source: source, imageQuality: 70, maxWidth: 1600);
    if (picked == null) return;

    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;

    setState(() => _uploading.add(doc.key));
    try {
      final url = await ref.read(storageServiceProvider).uploadDocument(
            uid: uid,
            docType: doc.key,
            file: File(picked.path),
          );
      if (mounted) setState(() => _uploaded[doc.key] = url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload failed. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading.remove(doc.key));
    }
  }

  void _continue() {
    ref.read(sessionProvider.notifier).setDocuments(Map.of(_uploaded));
    context.go(AppRouter.vehicleDetails);
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                children: [
                  const Text(
                    'Upload your documents',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.dark,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'We review these before you can start driving. '
                    'Make sure they are clear and not expired.',
                    style: TextStyle(
                        fontSize: 15, color: AppColors.muted, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  for (final doc in _docs) _docRow(doc),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: 'Continue',
                enabled: _allUploaded,
                onPressed: _allUploaded ? _continue : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _docRow(_Doc doc) {
    final done = _uploaded.containsKey(doc.key);
    final busy = _uploading.contains(doc.key);
    return GestureDetector(
      onTap: busy ? null : () => _pick(doc),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: done ? AppColors.selectedFill : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: done ? AppColors.selectedBorder : AppColors.line,
            width: done ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(doc.icon,
                size: 26, color: done ? AppColors.green : AppColors.muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(doc.label,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.dark)),
                  Text(
                    busy
                        ? 'Uploading…'
                        : (done ? 'Uploaded' : 'Tap to upload'),
                    style: TextStyle(
                        fontSize: 13,
                        color: done ? AppColors.green : AppColors.muted),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: AppColors.green),
              )
            else
              Icon(
                done ? Icons.check_circle : Icons.upload_file_outlined,
                color: done ? AppColors.green : AppColors.muted,
              ),
          ],
        ),
      ),
    );
  }
}
