import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/repositories/application_repository.dart';
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

  bool get _valid =>
      _make.text.trim().isNotEmpty &&
      _model.text.trim().isNotEmpty &&
      _year.text.trim().length == 4 &&
      _plate.text.trim().isNotEmpty;

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

  Future<void> _submit() async {
    final notifier = ref.read(sessionProvider.notifier);
    notifier.submitDriverApplication();
    final s = ref.read(sessionProvider);

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
        documents: s.documents,
      );
    }

    if (mounted) context.go(AppRouter.pending);
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
                  _field(_color, 'Colour (optional)', 'Silver'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: 'Submit application',
                enabled: _valid,
                onPressed: _valid ? _submit : null,
              ),
            ),
          ],
        ),
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
