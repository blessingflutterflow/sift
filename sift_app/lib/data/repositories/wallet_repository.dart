import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One movement on the rider's wallet (written server-side only).
class WalletEntry {
  const WalletEntry({
    required this.id,
    required this.type,
    required this.balanceDelta,
    this.amount,
    this.rideId,
    this.createdAt,
  });

  final String id;
  final String type; // topup | ride_payment
  final double balanceDelta;
  final double? amount;
  final String? rideId;
  final DateTime? createdAt;

  bool get isCredit => balanceDelta >= 0;

  factory WalletEntry.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    return WalletEntry(
      id: doc.id,
      type: (m['type'] ?? '').toString(),
      balanceDelta: (m['balanceDelta'] as num?)?.toDouble() ?? 0,
      amount: (m['amount'] as num?)?.toDouble(),
      rideId: m['rideId'] as String?,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Rider prepaid wallet — read-only on the client. Top-ups go through Paystack
/// (the webhook credits the balance); rides are debited by `completeRide`.
class WalletRepository {
  WalletRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  Stream<double> watchBalance(String uid) {
    return _db.collection('wallets').doc(uid).snapshots().map(
        (d) => ((d.data() ?? const {})['balance'] as num?)?.toDouble() ?? 0);
  }

  /// One-shot balance read (for the payment selector).
  Future<double> balance(String uid) async {
    final d = await _db.collection('wallets').doc(uid).get();
    return ((d.data() ?? const {})['balance'] as num?)?.toDouble() ?? 0;
  }

  Stream<List<WalletEntry>> watchEntries(String uid) {
    return _db
        .collection('wallets')
        .doc(uid)
        .collection('entries')
        .orderBy('createdAt', descending: true)
        .limit(60)
        .snapshots()
        .map((s) => s.docs.map(WalletEntry.fromDoc).toList());
  }

  /// Start a Paystack checkout to top up by [amount] ZAR. Returns the
  /// authorization URL to open in the in-app WebView.
  Future<String> initTopup(double amount, {String? email}) async {
    final res = await _functions
        .httpsCallable('initWalletTopup')
        .call<Map<dynamic, dynamic>>({
      'amount': amount,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    return res.data['authorizationUrl'] as String;
  }
}

final walletRepositoryProvider =
    Provider<WalletRepository>((ref) => WalletRepository());
