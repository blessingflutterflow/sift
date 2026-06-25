import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Lifecycle of a ride, shared by rider + driver apps via Firestore. The
/// [value] strings must match the Cloud Functions exactly.
enum RideStatus {
  scheduled('scheduled'),
  requested('requested'),
  accepted('accepted'),
  arriving('arriving'),
  arrived('arrived'),
  inProgress('in_progress'),
  completed('completed'),
  cancelled('cancelled'),
  expired('expired');

  const RideStatus(this.value);
  final String value;

  static RideStatus fromName(String? n) => RideStatus.values.firstWhere(
        (s) => s.value == n,
        orElse: () => RideStatus.requested,
      );
}

class Ride {
  const Ride({
    required this.id,
    required this.riderId,
    required this.riderName,
    required this.riderPhone,
    required this.pickup,
    required this.pickupAddress,
    required this.destination,
    required this.destinationLabel,
    required this.tierId,
    required this.tierName,
    required this.fare,
    required this.distanceKm,
    required this.status,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.driverVehicle,
    this.driverPhoto,
    this.driverRating,
    this.driverRatingCount,
    this.createdAt,
    this.scheduledFor,
    this.quotedFare,
    this.finalFare,
    this.waitFee,
    this.commission,
    this.driverEarning,
    this.paymentMethod = 'cash',
    this.paymentStatus = 'unpaid',
    this.offeredTo,
    this.offerExpiresAt,
    this.driverPos,
    this.driverHeading,
    this.driverSpeedKmh,
    this.driverUpdatedAt,
    this.arrivedAt,
    this.candidatePositions = const [],
    this.candidateIndex = -1,
  });

  final String id;
  final String riderId;
  final String riderName;
  final String riderPhone;
  final LatLng pickup;
  final String pickupAddress;
  final LatLng destination;
  final String destinationLabel;
  final String tierId;
  final String tierName;
  final double fare;
  final double distanceKm;
  final RideStatus status;
  final String? driverId;
  final String? driverName;
  final String? driverPhone;
  final String? driverVehicle;

  /// Assigned driver's KYC profile photo, average rating, and how many ratings
  /// it's based on — shown on the rider's assigned-driver card.
  final String? driverPhoto;
  final double? driverRating;
  final int? driverRatingCount;

  /// When the request was created (server timestamp) — for history lists.
  final DateTime? createdAt;

  /// For advance bookings: when the ride should be dispatched. Null for
  /// immediate rides.
  final DateTime? scheduledFor;

  /// Money (server-authoritative). [fare] is the live quote; [finalFare] is
  /// stamped at completion (quote + waiting fee). Use [displayFare].
  final double? quotedFare;
  final double? finalFare;
  final double? waitFee;
  final double? commission;
  final double? driverEarning;
  final String paymentMethod; // 'cash' | 'card'
  final String paymentStatus; // 'unpaid' | 'cash' | 'pending' | 'paid' | 'due'

  /// The amount to show the user — settled total once known, else the quote.
  double get displayFare => finalFare ?? fare;

  /// The driver currently being offered this ride, and when that offer lapses.
  final String? offeredTo;
  final DateTime? offerExpiresAt;

  /// Assigned driver's live position (mirrored into the ride so the rider can
  /// watch it without reading driver_locations).
  final LatLng? driverPos;

  /// Live driver telemetry written alongside the position — lets the rider
  /// rotate the car marker and calibrate the ETA between Directions fetches.
  final double? driverHeading;
  final double? driverSpeedKmh;
  final DateTime? driverUpdatedAt;

  /// Server-stamped when the driver marks `arrived` — drives the waiting
  /// countdown on both sides.
  final DateTime? arrivedAt;

  /// Snapshot positions of the candidate drivers (so the rider can show nearby
  /// cars while searching), and which one is currently being offered.
  final List<LatLng> candidatePositions;
  final int candidateIndex;

  /// Data for creating a ride (server stamps id/createdAt/status).
  static Map<String, dynamic> newRequest({
    required String riderId,
    required String riderName,
    required String riderPhone,
    required LatLng pickup,
    required String pickupAddress,
    required LatLng destination,
    required String destinationLabel,
    required String tierId,
    required String tierName,
    required double fare,
    required double distanceKm,
    String paymentMethod = 'cash',
    DateTime? scheduledFor,
  }) {
    return {
      'riderId': riderId,
      'riderName': riderName,
      'riderPhone': riderPhone,
      'pickupLat': pickup.latitude,
      'pickupLng': pickup.longitude,
      'pickupAddress': pickupAddress,
      'destLat': destination.latitude,
      'destLng': destination.longitude,
      'destLabel': destinationLabel,
      'tierId': tierId,
      'tierName': tierName,
      'fare': fare,
      'distanceKm': distanceKm,
      'paymentMethod': paymentMethod,
      // A future time books an advance ride (dispatched later by the server);
      // otherwise it dispatches immediately.
      'status': scheduledFor != null
          ? RideStatus.scheduled.value
          : RideStatus.requested.value,
      if (scheduledFor != null)
        'scheduledFor': Timestamp.fromDate(scheduledFor),
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  factory Ride.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return Ride(
      id: doc.id,
      riderId: m['riderId'] as String? ?? '',
      riderName: m['riderName'] as String? ?? 'Rider',
      riderPhone: m['riderPhone'] as String? ?? '',
      pickup: LatLng(d('pickupLat'), d('pickupLng')),
      pickupAddress: m['pickupAddress'] as String? ?? '',
      destination: LatLng(d('destLat'), d('destLng')),
      destinationLabel: m['destLabel'] as String? ?? '',
      tierId: m['tierId'] as String? ?? 'bolt',
      tierName: m['tierName'] as String? ?? 'Bolt',
      fare: d('fare'),
      distanceKm: d('distanceKm'),
      status: RideStatus.fromName(m['status'] as String?),
      driverId: m['driverId'] as String?,
      driverName: m['driverName'] as String?,
      driverPhone: m['driverPhone'] as String?,
      driverVehicle: m['driverVehicle'] as String?,
      driverPhoto: m['driverPhoto'] as String?,
      driverRating: (m['driverRating'] as num?)?.toDouble(),
      driverRatingCount: (m['driverRatingCount'] as num?)?.toInt(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      scheduledFor: (m['scheduledFor'] as Timestamp?)?.toDate(),
      quotedFare: (m['quotedFare'] as num?)?.toDouble(),
      finalFare: (m['finalFare'] as num?)?.toDouble(),
      waitFee: (m['waitFee'] as num?)?.toDouble(),
      commission: (m['commission'] as num?)?.toDouble(),
      driverEarning: (m['driverEarning'] as num?)?.toDouble(),
      paymentMethod: m['paymentMethod'] as String? ?? 'cash',
      paymentStatus: m['paymentStatus'] as String? ?? 'unpaid',
      offeredTo: m['offeredTo'] as String?,
      offerExpiresAt: (m['offerExpiresAt'] as Timestamp?)?.toDate(),
      driverPos: (m['driverLat'] is num && m['driverLng'] is num)
          ? LatLng((m['driverLat'] as num).toDouble(),
              (m['driverLng'] as num).toDouble())
          : null,
      driverHeading: (m['driverHeading'] as num?)?.toDouble(),
      driverSpeedKmh: (m['driverSpeedKmh'] as num?)?.toDouble(),
      driverUpdatedAt: (m['driverUpdatedAt'] as Timestamp?)?.toDate(),
      arrivedAt: (m['arrivedAt'] as Timestamp?)?.toDate(),
      candidatePositions: ((m['candidatePositions'] as List?) ?? [])
          .whereType<Map>()
          .where((p) => p['lat'] is num && p['lng'] is num)
          .map((p) =>
              LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
          .toList(),
      candidateIndex: (m['candidateIndex'] as num?)?.toInt() ?? -1,
    );
  }
}
