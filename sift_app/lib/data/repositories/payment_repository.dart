import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A vaulted card. Created exclusively by the Paystack webhook (the raw card
/// number never passes through the app); the client only reads display fields
/// and manages which card is the default.
class PaymentMethod {
  const PaymentMethod({
    required this.id,
    required this.last4,
    required this.brand,
    required this.bank,
    required this.isDefault,
    this.expMonth,
    this.expYear,
  });

  final String id;
  final String last4;
  final String brand;
  final String bank;
  final bool isDefault;
  final String? expMonth;
  final String? expYear;

  String get label => '${brand.isEmpty ? 'Card' : brand} •••• $last4';

  factory PaymentMethod.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    return PaymentMethod(
      id: doc.id,
      last4: (m['last4'] ?? '????').toString(),
      brand: _titleCase((m['brand'] ?? '').toString()),
      bank: (m['bank'] ?? '').toString(),
      isDefault: m['isDefault'] == true,
      expMonth: m['expMonth']?.toString(),
      expYear: m['expYear']?.toString(),
    );
  }

  static String _titleCase(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    return t[0].toUpperCase() + t.substring(1);
  }
}

/// Client side of the payments contract: read vaulted cards, kick off the
/// Paystack checkouts (card vault / debt settlement) via callables, and manage
/// the default card. All money movement stays server-side.
class PaymentRepository {
  PaymentRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> _methods(String uid) =>
      _db.collection('users').doc(uid).collection('payment_methods');

  /// Cards, default first then newest first.
  Stream<List<PaymentMethod>> watchMethods(String uid) {
    return _methods(uid).snapshots().map((s) {
      final list = s.docs.map(PaymentMethod.fromDoc).toList()
        ..sort((a, b) {
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return b.id.compareTo(a.id);
        });
      return list;
    });
  }

  /// Start the card-vault checkout (R1 probe, auto-refunded). Returns the
  /// Paystack authorization URL to open in the in-app WebView.
  Future<String> initCardSetup(String email) async {
    final res = await _functions
        .httpsCallable('initCardSetup')
        .call<Map<dynamic, dynamic>>({'email': email});
    return res.data['authorizationUrl'] as String;
  }

  /// Start a checkout to settle an unpaid ride (`paymentStatus: 'due'`).
  Future<String> initDebtPayment(String rideId, {String? email}) async {
    final res = await _functions
        .httpsCallable('initDebtPayment')
        .call<Map<dynamic, dynamic>>({
      'rideId': rideId,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    return res.data['authorizationUrl'] as String;
  }

  /// Make [methodId] the default card (the one trips are charged to).
  Future<void> setDefault(String uid, String methodId,
      List<PaymentMethod> current) async {
    final batch = _db.batch();
    for (final m in current) {
      final shouldBe = m.id == methodId;
      if (m.isDefault != shouldBe) {
        batch.update(_methods(uid).doc(m.id), {'isDefault': shouldBe});
      }
    }
    await batch.commit();
  }

  Future<void> remove(String uid, String methodId) =>
      _methods(uid).doc(methodId).delete();
}

final paymentRepositoryProvider =
    Provider<PaymentRepository>((ref) => PaymentRepository());
