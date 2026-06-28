import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../ride_request/services/places_service.dart';

class PickedAddress {
  const PickedAddress(this.location, this.address);
  final LatLng location;
  final String address;
}

/// Lightweight Places search sheet — pick an address (e.g. the parcel pickup).
Future<PickedAddress?> showAddressSearch(
  BuildContext context,
  WidgetRef ref, {
  String title = 'Pickup address',
}) {
  return showModalBottomSheet<PickedAddress>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AddressSearch(ref: ref, title: title),
  );
}

class _AddressSearch extends StatefulWidget {
  const _AddressSearch({required this.ref, required this.title});
  final WidgetRef ref;
  final String title;

  @override
  State<_AddressSearch> createState() => _AddressSearchState();
}

class _AddressSearchState extends State<_AddressSearch> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<PlacePrediction> _preds = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
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
    Navigator.pop(
      context,
      PickedAddress(
        loc,
        [p.primary, p.secondary].where((s) => s.isNotEmpty).join(', '),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: _onQuery,
            decoration: InputDecoration(
              hintText: 'Search address',
              prefixIcon: const Icon(Icons.search),
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
          const SizedBox(height: 8),
          ..._preds.take(5).map((p) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined, color: AppColors.muted),
                title:
                    Text(p.primary, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: p.secondary.isEmpty
                    ? null
                    : Text(p.secondary,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _pick(p),
              )),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
