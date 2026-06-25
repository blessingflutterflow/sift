import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class PlacePrediction {
  const PlacePrediction(
      {required this.placeId, required this.primary, required this.secondary});
  final String placeId;
  final String primary;
  final String secondary;
}

/// Places search via Cloud Functions (`placesAutocomplete`/`placeDetails`) —
/// ZA-biased, and the Maps key never ships in the APK.
class PlacesService {
  PlacesService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFunctions _functions;

  Future<List<PlacePrediction>> autocomplete(String input) async {
    if (input.trim().length < 2) return [];
    try {
      final res = await _functions
          .httpsCallable('placesAutocomplete')
          .call<Map<dynamic, dynamic>>({'input': input});
      final preds = (res.data['predictions'] as List?) ?? [];
      return preds.whereType<Map>().map((p) {
        return PlacePrediction(
          placeId: (p['placeId'] ?? '').toString(),
          primary: (p['primary'] ?? '').toString(),
          secondary: (p['secondary'] ?? '').toString(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<LatLng?> placeLatLng(String placeId) async {
    try {
      final res = await _functions
          .httpsCallable('placeDetails')
          .call<Map<dynamic, dynamic>>({'placeId': placeId});
      final lat = res.data['lat'] as num?;
      final lng = res.data['lng'] as num?;
      if (lat == null || lng == null) return null;
      return LatLng(lat.toDouble(), lng.toDouble());
    } catch (_) {
      return null;
    }
  }
}

final placesServiceProvider = Provider<PlacesService>((ref) => PlacesService());
