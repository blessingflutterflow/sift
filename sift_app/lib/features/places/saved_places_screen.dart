import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/places_repository.dart';
import '../auth/session_controller.dart';
import '../ride_request/services/places_service.dart';

/// Manage saved places: pinned Home/Work slots + custom places, each picked
/// via live Places search.
class SavedPlacesScreen extends ConsumerStatefulWidget {
  const SavedPlacesScreen({super.key});

  @override
  ConsumerState<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

class _SavedPlacesScreenState extends ConsumerState<SavedPlacesScreen> {
  Future<void> _pickPlace({String? slot, String? presetLabel}) async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;

    final picked = await showModalBottomSheet<_PickedPlace>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PlaceSearchSheet(presetLabel: presetLabel),
    );
    if (picked == null || !mounted) return;

    await ref.read(placesRepositoryProvider).save(
          uid,
          label: presetLabel ?? picked.primary,
          address: picked.secondary,
          latLng: picked.latLng,
          slot: slot,
        );
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(sessionProvider).uid;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Saved places',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<SavedPlace>>(
              stream: ref.read(placesRepositoryProvider).watch(uid),
              builder: (context, snap) {
                final places = snap.data ?? const <SavedPlace>[];
                final home =
                    places.where((p) => p.slot == 'home').firstOrNull;
                final work =
                    places.where((p) => p.slot == 'work').firstOrNull;
                final customs =
                    places.where((p) => p.slot == null).toList();

                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    _slotTile(
                      icon: Icons.home_outlined,
                      title: 'Home',
                      place: home,
                      onSet: () =>
                          _pickPlace(slot: 'home', presetLabel: 'Home'),
                      uid: uid,
                    ),
                    _slotTile(
                      icon: Icons.work_outline,
                      title: 'Work',
                      place: work,
                      onSet: () =>
                          _pickPlace(slot: 'work', presetLabel: 'Work'),
                      uid: uid,
                    ),
                    const SizedBox(height: 8),
                    for (final p in customs)
                      _slotTile(
                        icon: Icons.star_border,
                        title: p.label,
                        place: p,
                        onSet: null,
                        uid: uid,
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () => _pickPlace(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.green,
                          side: const BorderSide(
                              color: AppColors.selectedBorder, width: 1.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26)),
                        ),
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: const Text('Add place',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _slotTile({
    required IconData icon,
    required String title,
    required SavedPlace? place,
    required VoidCallback? onSet,
    required String uid,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: ListTile(
        onTap: place == null ? onSet : null,
        leading: Icon(icon, size: 26, color: AppColors.dark),
        title: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        subtitle: Text(
          place == null ? 'Tap to set' : place.address,
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: place == null
            ? const Icon(Icons.add, color: AppColors.green)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onSet != null)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined,
                          size: 20, color: AppColors.muted),
                      onPressed: onSet,
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: AppColors.muted),
                    onPressed: () => ref
                        .read(placesRepositoryProvider)
                        .remove(uid, place.id),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PickedPlace {
  const _PickedPlace(this.primary, this.secondary, this.latLng);
  final String primary;
  final String secondary;
  final LatLng latLng;
}

/// Bottom-sheet Places search → resolves the chosen prediction to coords.
class _PlaceSearchSheet extends ConsumerStatefulWidget {
  const _PlaceSearchSheet({this.presetLabel});
  final String? presetLabel;

  @override
  ConsumerState<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends ConsumerState<_PlaceSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PlacePrediction> _predictions = [];
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    _debounce?.cancel();
    final q = _controller.text;
    if (q.trim().length < 2) {
      setState(() => _predictions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final preds = await ref.read(placesServiceProvider).autocomplete(q);
      if (mounted) setState(() => _predictions = preds);
    });
  }

  Future<void> _choose(PlacePrediction p) async {
    setState(() => _resolving = true);
    final latLng =
        await ref.read(placesServiceProvider).placeLatLng(p.placeId);
    if (!mounted) return;
    if (latLng == null) {
      setState(() => _resolving = false);
      return;
    }
    Navigator.pop(context, _PickedPlace(p.primary, p.secondary, latLng));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 14),
            Text(
              widget.presetLabel == null
                  ? 'Add place'
                  : 'Set ${widget.presetLabel}',
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search address or place',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppColors.field,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_resolving) const LinearProgressIndicator(color: AppColors.green),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _predictions.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: AppColors.line),
                itemBuilder: (context, i) {
                  final p = _predictions[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.location_on_outlined,
                        color: Color(0xFF7A7C86)),
                    title: Text(p.primary,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(p.secondary,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: _resolving ? null : () => _choose(p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
