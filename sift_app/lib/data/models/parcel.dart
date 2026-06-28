import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Lifecycle of a parcel delivery, shared by sender + driver via Firestore.
/// Values must match the Cloud Functions exactly.
enum ParcelStatus {
  requested('requested'),
  accepted('accepted'),
  arriving('arriving'), // driver heading to the pickup
  pickedUp('picked_up'), // collected from the sender
  delivering('delivering'), // en route through the drop-offs
  completed('completed'),
  cancelled('cancelled'),
  expired('expired');

  const ParcelStatus(this.value);
  final String value;

  static ParcelStatus fromName(String? n) => ParcelStatus.values.firstWhere(
        (s) => s.value == n,
        orElse: () => ParcelStatus.requested,
      );
}

/// Parcel size tiers — drive the fare surcharge and what the driver expects.
enum ParcelSize {
  small('small', 'Small', 'Envelope / small box (≤2 kg)'),
  medium('medium', 'Medium', 'Backpack-sized (≤10 kg)'),
  large('large', 'Large', 'Large box / multiple items (≤25 kg)');

  const ParcelSize(this.value, this.label, this.hint);
  final String value;
  final String label;
  final String hint;

  static ParcelSize fromName(String? n) => ParcelSize.values.firstWhere(
        (s) => s.value == n,
        orElse: () => ParcelSize.small,
      );
}

/// One drop-off in a (possibly multi-stop) parcel delivery.
class ParcelStop {
  const ParcelStop({
    required this.location,
    required this.address,
    required this.recipientName,
    required this.recipientPhone,
    this.size = 'small',
    this.note = '',
    this.status = 'pending', // pending | delivered | failed
    this.podPhotoUrl,
    this.podSignatureUrl,
    this.receivedBy,
    this.deliveredAt,
    this.failReason,
  });

  final LatLng location;
  final String address;
  final String recipientName;
  final String recipientPhone;
  final String size;
  final String note;
  final String status;
  final String? podPhotoUrl;
  final String? podSignatureUrl;
  final String? receivedBy;
  final DateTime? deliveredAt;
  final String? failReason;

  bool get isResolved => status == 'delivered' || status == 'failed';

  Map<String, dynamic> toMap() => {
        'lat': location.latitude,
        'lng': location.longitude,
        'address': address,
        'recipientName': recipientName,
        'recipientPhone': recipientPhone,
        'size': size,
        'note': note,
        'status': status,
        if (podPhotoUrl != null) 'podPhotoUrl': podPhotoUrl,
        if (podSignatureUrl != null) 'podSignatureUrl': podSignatureUrl,
        if (receivedBy != null) 'receivedBy': receivedBy,
        if (failReason != null) 'failReason': failReason,
      };

  factory ParcelStop.fromMap(Map<String, dynamic> m) {
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return ParcelStop(
      location: LatLng(d('lat'), d('lng')),
      address: m['address'] as String? ?? '',
      recipientName: m['recipientName'] as String? ?? '',
      recipientPhone: m['recipientPhone'] as String? ?? '',
      size: m['size'] as String? ?? 'small',
      note: m['note'] as String? ?? '',
      status: m['status'] as String? ?? 'pending',
      podPhotoUrl: m['podPhotoUrl'] as String?,
      podSignatureUrl: m['podSignatureUrl'] as String?,
      receivedBy: m['receivedBy'] as String?,
      deliveredAt: (m['deliveredAt'] as Timestamp?)?.toDate(),
      failReason: m['failReason'] as String?,
    );
  }
}

class Parcel {
  const Parcel({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.senderPhone,
    required this.pickup,
    required this.pickupAddress,
    required this.stops,
    required this.status,
    required this.distanceKm,
    required this.fare,
    this.quotedFare,
    this.finalFare,
    this.commission,
    this.driverEarning,
    this.paymentMethod = 'cash',
    this.paymentStatus = 'unpaid',
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.driverVehicle,
    this.driverPhoto,
    this.driverRating,
    this.createdAt,
    this.currentStopIndex = 0,
    this.offeredTo,
    this.offerExpiresAt,
    this.driverPos,
    this.driverHeading,
    this.candidatePositions = const [],
  });

  final String id;
  final String senderId;
  final String senderName;
  final String senderPhone;
  final LatLng pickup;
  final String pickupAddress;
  final List<ParcelStop> stops;
  final ParcelStatus status;
  final double distanceKm;
  final double fare;
  final double? quotedFare;
  final double? finalFare;
  final double? commission;
  final double? driverEarning;
  final String paymentMethod; // cash | card | wallet
  final String paymentStatus; // unpaid | cash | processing | paid | due
  final String? driverId;
  final String? driverName;
  final String? driverPhone;
  final String? driverVehicle;
  final String? driverPhoto;
  final double? driverRating;
  final DateTime? createdAt;

  /// Which drop-off the driver is currently working through.
  final int currentStopIndex;

  final String? offeredTo;
  final DateTime? offerExpiresAt;
  final LatLng? driverPos;
  final double? driverHeading;
  final List<LatLng> candidatePositions;

  double get displayFare => finalFare ?? fare;
  int get deliveredCount => stops.where((s) => s.status == 'delivered').length;
  int get failedCount => stops.where((s) => s.status == 'failed').length;

  /// The next unresolved drop-off, or null when all are done.
  ParcelStop? get activeStop {
    for (final s in stops) {
      if (!s.isResolved) return s;
    }
    return null;
  }

  /// Data for creating a parcel request (server stamps id/createdAt/fare).
  static Map<String, dynamic> newRequest({
    required String senderId,
    required String senderName,
    required String senderPhone,
    required LatLng pickup,
    required String pickupAddress,
    required List<ParcelStop> stops,
    required double distanceKm,
    required double fare,
    String paymentMethod = 'cash',
  }) {
    return {
      'senderId': senderId,
      'senderName': senderName,
      'senderPhone': senderPhone,
      'pickupLat': pickup.latitude,
      'pickupLng': pickup.longitude,
      'pickupAddress': pickupAddress,
      'stops': stops.map((s) => s.toMap()).toList(),
      'distanceKm': distanceKm,
      'fare': fare,
      'paymentMethod': paymentMethod,
      'status': ParcelStatus.requested.value,
      'currentStopIndex': 0,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  factory Parcel.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return Parcel(
      id: doc.id,
      senderId: m['senderId'] as String? ?? '',
      senderName: m['senderName'] as String? ?? 'Sender',
      senderPhone: m['senderPhone'] as String? ?? '',
      pickup: LatLng(d('pickupLat'), d('pickupLng')),
      pickupAddress: m['pickupAddress'] as String? ?? '',
      stops: ((m['stops'] as List?) ?? [])
          .whereType<Map>()
          .map((s) => ParcelStop.fromMap(Map<String, dynamic>.from(s)))
          .toList(),
      status: ParcelStatus.fromName(m['status'] as String?),
      distanceKm: d('distanceKm'),
      fare: d('fare'),
      quotedFare: (m['quotedFare'] as num?)?.toDouble(),
      finalFare: (m['finalFare'] as num?)?.toDouble(),
      commission: (m['commission'] as num?)?.toDouble(),
      driverEarning: (m['driverEarning'] as num?)?.toDouble(),
      paymentMethod: m['paymentMethod'] as String? ?? 'cash',
      paymentStatus: m['paymentStatus'] as String? ?? 'unpaid',
      driverId: m['driverId'] as String?,
      driverName: m['driverName'] as String?,
      driverPhone: m['driverPhone'] as String?,
      driverVehicle: m['driverVehicle'] as String?,
      driverPhoto: m['driverPhoto'] as String?,
      driverRating: (m['driverRating'] as num?)?.toDouble(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      currentStopIndex: (m['currentStopIndex'] as num?)?.toInt() ?? 0,
      offeredTo: m['offeredTo'] as String?,
      offerExpiresAt: (m['offerExpiresAt'] as Timestamp?)?.toDate(),
      driverPos: (m['driverLat'] is num && m['driverLng'] is num)
          ? LatLng((m['driverLat'] as num).toDouble(),
              (m['driverLng'] as num).toDouble())
          : null,
      driverHeading: (m['driverHeading'] as num?)?.toDouble(),
      candidatePositions: ((m['candidatePositions'] as List?) ?? [])
          .whereType<Map>()
          .where((p) => p['lat'] is num && p['lng'] is num)
          .map((p) =>
              LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
          .toList(),
    );
  }
}
