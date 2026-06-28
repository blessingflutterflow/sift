import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/parcel.dart';
import '../ride_request/services/places_service.dart';

/// Add or edit a single drop-off: address (Places search), recipient, size,
/// optional note. Returns the [ParcelStop] or null if cancelled.
Future<ParcelStop?> showStopEditor(
  BuildContext context,
  WidgetRef ref, {
  ParcelStop? existing,
}) {
  return showModalBottomSheet<ParcelStop>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _StopEditor(ref: ref, existing: existing),
  );
}

class _StopEditor extends StatefulWidget {
  const _StopEditor({required this.ref, this.existing});
  final WidgetRef ref;
  final ParcelStop? existing;

  @override
  State<_StopEditor> createState() => _StopEditorState();
}

class _StopEditorState extends State<_StopEditor> {
  final _addressCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  Timer? _debounce;
  List<PlacePrediction> _preds = [];
  LatLng? _location;
  String _address = '';
  ParcelSize _size = ParcelSize.small;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _location = e.location;
      _address = e.address;
      _addressCtrl.text = e.address;
      _nameCtrl.text = e.recipientName;
      _phoneCtrl.text = e.recipientPhone;
      _noteCtrl.text = e.note;
      _size = ParcelSize.fromName(e.size);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _addressCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final preds = await widget.ref.read(placesServiceProvider).autocomplete(q);
      if (mounted) setState(() => _preds = preds);
    });
  }

  Future<void> _pick(PlacePrediction p) async {
    final loc = await widget.ref.read(placesServiceProvider).placeLatLng(p.placeId);
    if (loc == null || !mounted) return;
    setState(() {
      _location = loc;
      _address = [p.primary, p.secondary].where((s) => s.isNotEmpty).join(', ');
      _addressCtrl.text = _address;
      _preds = [];
    });
    FocusScope.of(context).unfocus();
  }

  bool get _valid =>
      _location != null &&
      _nameCtrl.text.trim().isNotEmpty &&
      _phoneCtrl.text.trim().isNotEmpty;

  void _save() {
    if (!_valid) return;
    Navigator.pop(
      context,
      ParcelStop(
        location: _location!,
        address: _address,
        recipientName: _nameCtrl.text.trim(),
        recipientPhone: _phoneCtrl.text.trim(),
        size: _size.value,
        note: _noteCtrl.text.trim(),
      ),
    );
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
            Center(
              child: Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6E6E8),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            Text(widget.existing == null ? 'Add a drop-off' : 'Edit drop-off',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),

            _field(_addressCtrl, 'Drop-off address', onChanged: _onQuery),
            if (_preds.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: _preds
                      .take(4)
                      .map((p) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined,
                                color: AppColors.muted),
                            title: Text(p.primary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: p.secondary.isEmpty
                                ? null
                                : Text(p.secondary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                            onTap: () => _pick(p),
                          ))
                      .toList(),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _field(_nameCtrl, 'Recipient name')),
                const SizedBox(width: 10),
                Expanded(
                    child: _field(_phoneCtrl, 'Phone',
                        keyboard: TextInputType.phone)),
              ],
            ),
            const SizedBox(height: 14),
            const Text('Parcel size',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.muted)),
            const SizedBox(height: 8),
            Column(
              children: ParcelSize.values.map((s) {
                final on = _size == s;
                return GestureDetector(
                  onTap: () => setState(() => _size = s),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: on ? AppColors.selectedFill : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: on ? AppColors.selectedBorder : AppColors.line,
                          width: on ? 1.5 : 1),
                    ),
                    child: Row(
                      children: [
                        Icon(
                            on
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 20,
                            color: on ? AppColors.green : AppColors.muted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.label,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              Text(s.hint,
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.muted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
            _field(_noteCtrl, 'Note for the driver (optional)'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _valid ? _save : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  disabledBackgroundColor: AppColors.green.withValues(alpha: .4),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27)),
                ),
                child: Text(widget.existing == null ? 'Add drop-off' : 'Save',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint,
      {ValueChanged<String>? onChanged, TextInputType? keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      onChanged: (v) {
        if (onChanged != null) onChanged(v);
        setState(() {});
      },
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: AppColors.field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.green, width: 2),
        ),
      ),
    );
  }
}
