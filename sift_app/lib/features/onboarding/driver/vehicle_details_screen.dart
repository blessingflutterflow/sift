import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/repositories/application_repository.dart';
import '../../../data/services/storage_service.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../auth/session_controller.dart';

/// Vehicle details. Submitting moves the driver into the pending-review gate.
class VehicleDetailsScreen extends ConsumerStatefulWidget {
  const VehicleDetailsScreen({super.key});

  @override
  ConsumerState<VehicleDetailsScreen> createState() =>
      _VehicleDetailsScreenState();
}

class _VehicleDetailsScreenState extends ConsumerState<VehicleDetailsScreen> {
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _year = TextEditingController();
  final _plate = TextEditingController();
  final _color = TextEditingController();

  final _picker = ImagePicker();
  File? _carFront;
  bool _uploading = false;

  bool get _valid =>
      _make.text.trim().isNotEmpty &&
      _model.text.trim().isNotEmpty &&
      _year.text.trim().length == 4 &&
      _plate.text.trim().isNotEmpty &&
      _color.text.trim().isNotEmpty &&
      _carFront != null;

  @override
  void initState() {
    super.initState();
    for (final c in [_make, _model, _year, _plate, _color]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_make, _model, _year, _plate, _color]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCarFront() async {
    final picked = await _picker.pickImage(
        source: ImageSource.camera, imageQuality: 70, maxWidth: 1600);
    if (picked != null && mounted) setState(() => _carFront = File(picked.path));
  }

  Future<void> _submit() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final notifier = ref.read(sessionProvider.notifier);
    final s = ref.read(sessionProvider);
    try {
      var documents = Map<String, String>.from(s.documents);
      // Upload the car's front photo alongside the KYC docs.
      if (AppConfig.useBackend && s.uid != null && _carFront != null) {
        final url = await ref.read(storageServiceProvider).uploadDocument(
              uid: s.uid!,
              docType: 'car_front',
              file: _carFront!,
            );
        documents = {...documents, 'car_front': url};
      }

      notifier.submitDriverApplication();
      if (AppConfig.useBackend && s.uid != null && s.role != null) {
        await ref.read(applicationRepositoryProvider).submit(
          uid: s.uid!,
          role: s.role!,
          vehicle: {
            'make': _make.text.trim(),
            'model': _model.text.trim(),
            'year': _year.text.trim(),
            'plate': _plate.text.trim(),
            'color': _color.text.trim(),
          },
          documents: documents,
          docExpiry: s.docExpiry,
        );
      }
      if (mounted) context.go(AppRouter.pending);
    } catch (_) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not submit. Check your connection and try again.'),
          backgroundColor: Color(0xFFE0524D),
        ));
      }
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                children: [
                  const Text(
                    'Your vehicle',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.dark,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _field(_make, 'Make', 'Toyota'),
                  _field(_model, 'Model', 'Prius'),
                  _field(_year, 'Year', '2021',
                      type: TextInputType.number, maxLength: 4),
                  _field(_plate, 'Number plate', 'AB21 CDE',
                      caps: true),
                  _field(_color, 'Colour', 'Silver'),
                  _carFrontPicker(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: _uploading ? 'Submitting…' : 'Submit application',
                enabled: _valid && !_uploading,
                onPressed: (_valid && !_uploading) ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _carFrontPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Front photo of the car',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.dark)),
          ),
          GestureDetector(
            onTap: _pickCarFront,
            child: Container(
              height: 170,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(12),
                image: _carFront != null
                    ? DecorationImage(
                        image: FileImage(_carFront!), fit: BoxFit.cover)
                    : null,
              ),
              child: _carFront != null
                  ? Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                              color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.edit,
                              size: 16, color: Colors.white),
                        ),
                      ),
                    )
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.directions_car_outlined,
                            size: 34, color: AppColors.muted),
                        SizedBox(height: 6),
                        Text('Tap to take a photo of the car front',
                            style: TextStyle(color: AppColors.muted)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    TextInputType type = TextInputType.text,
    int? maxLength,
    bool caps = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.dark)),
          ),
          TextField(
            controller: controller,
            keyboardType: type,
            maxLength: maxLength,
            textCapitalization:
                caps ? TextCapitalization.characters : TextCapitalization.words,
            style: const TextStyle(fontSize: 16, color: AppColors.dark),
            decoration: InputDecoration(
              counterText: '',
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
          ),
        ],
      ),
    );
  }
}
