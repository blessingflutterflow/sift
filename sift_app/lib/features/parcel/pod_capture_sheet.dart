import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';

import '../../core/theme/app_colors.dart';
import '../../data/services/storage_service.dart';

class PodResult {
  const PodResult(this.photoUrl, this.signatureUrl, this.receivedBy);
  final String photoUrl;
  final String signatureUrl;
  final String receivedBy;
}

/// Capture proof of delivery for one drop-off: a photo + the recipient's
/// signature + who received it. Uploads to Storage and returns the URLs.
Future<PodResult?> capturePod(
  BuildContext context,
  WidgetRef ref, {
  required String parcelId,
  required int stopIndex,
  required String defaultName,
}) {
  return showModalBottomSheet<PodResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _PodCapture(
      ref: ref,
      parcelId: parcelId,
      stopIndex: stopIndex,
      defaultName: defaultName,
    ),
  );
}

class _PodCapture extends StatefulWidget {
  const _PodCapture({
    required this.ref,
    required this.parcelId,
    required this.stopIndex,
    required this.defaultName,
  });
  final WidgetRef ref;
  final String parcelId;
  final int stopIndex;
  final String defaultName;

  @override
  State<_PodCapture> createState() => _PodCaptureState();
}

class _PodCaptureState extends State<_PodCapture> {
  final _picker = ImagePicker();
  final _sig = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );
  late final TextEditingController _name =
      TextEditingController(text: widget.defaultName);
  File? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _sig.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final picked = await _picker.pickImage(
        source: ImageSource.camera, imageQuality: 70, maxWidth: 1600);
    if (picked != null && mounted) setState(() => _photo = File(picked.path));
  }

  bool get _valid => _photo != null && _sig.isNotEmpty;

  Future<void> _confirm() async {
    if (!_valid || _busy) return;
    setState(() => _busy = true);
    try {
      final storage = widget.ref.read(storageServiceProvider);
      final sigBytes = await _sig.toPngBytes();
      final photoUrl = await storage.uploadParcelPhoto(
        parcelId: widget.parcelId,
        stopIndex: widget.stopIndex,
        file: _photo!,
      );
      final sigUrl = await storage.uploadParcelSignature(
        parcelId: widget.parcelId,
        stopIndex: widget.stopIndex,
        bytes: sigBytes!,
      );
      if (mounted) {
        Navigator.pop(
            context, PodResult(photoUrl, sigUrl, _name.text.trim()));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save proof of delivery. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Proof of delivery',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),

            // Photo
            GestureDetector(
              onTap: _takePhoto,
              child: Container(
                height: 150,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.field,
                  borderRadius: BorderRadius.circular(12),
                  image: _photo != null
                      ? DecorationImage(
                          image: FileImage(_photo!), fit: BoxFit.cover)
                      : null,
                ),
                child: _photo != null
                    ? null
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt_outlined,
                              size: 32, color: AppColors.muted),
                          SizedBox(height: 6),
                          Text('Tap to take a delivery photo',
                              style: TextStyle(color: AppColors.muted)),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 14),

            // Signature
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Recipient signature',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.muted)),
                TextButton(
                  onPressed: () => setState(() => _sig.clear()),
                  child: const Text('Clear'),
                ),
              ],
            ),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Signature(
                controller: _sig,
                height: 160,
                backgroundColor: const Color(0xFFF7F7F8),
              ),
            ),
            const SizedBox(height: 14),

            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Received by',
                filled: true,
                fillColor: AppColors.field,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.green, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: (_valid && !_busy) ? _confirm : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  disabledBackgroundColor: AppColors.green.withValues(alpha: .4),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : const Text('Confirm delivery',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
