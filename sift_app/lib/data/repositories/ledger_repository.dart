import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One money event on the driver's ledger (written server-side only).
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.createdAt,
    this.rideId,
    this.finalFare,
    this.commission,
    this.driverEarning,
    this.balanceDelta = 0,
    this.amount,
  });

  final String id;
  final String type; // trip_earning_card | cash_commission_due | debt_payment | adjustment
  final DateTime? createdAt;
  final String? rideId;
  final double? finalFare;
  final double? commission;
  final double? driverEarning;
  final double balanceDelta;
  final double? amount;

  bool get isTrip =>
      type == 'trip_earning_card' || type == 'cash_commission_due';

  factory LedgerEntry.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    double? d(String k) => (m[k] as num?)?.toDouble();
    return LedgerEntry(
      id: doc.id,
      type: (m['type'] ?? '').toString(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      rideId: m['rideId'] as String?,
      finalFare: d('finalFare'),
      commission: d('commission'),
      driverEarning: d('driverEarning'),
      balanceDelta: d('balanceDelta') ?? 0,
      amount: d('amount'),
    );
  }
}

/// Driver's earnings/debt ledger — read-only on the client; all writes happen
/// in Cloud Functions (trip settlement, debt payments, admin adjustments).
class LedgerRepository {
  LedgerRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// Outstanding cash-commission balance (what the driver owes Sift).
  Stream<double> watchBalance(String uid) {
    return _db.collection('ledgers').doc(uid).snapshots().map(
        (d) => ((d.data() ?? const {})['balance'] as num?)?.toDouble() ?? 0);
  }

  Stream<List<LedgerEntry>> watchEntries(String uid) {
    return _db
        .collection('ledgers')
        .doc(uid)
        .collection('entries')
        .orderBy('createdAt', descending: true)
        .limit(60)
        .snapshots()
        .map((s) => s.docs.map(LedgerEntry.fromDoc).toList());
  }

  /// Start a checkout for the full outstanding balance.
  Future<String> initDebtPayment() async {
    final res = await _functions
        .httpsCallable('initDriverDebtPayment')
        .call<Map<dynamic, dynamic>>({});
    return res.data['authorizationUrl'] as String;
  }
}

final ledgerRepositoryProvider =
    Provider<LedgerRepository>((ref) => LedgerRepository());
