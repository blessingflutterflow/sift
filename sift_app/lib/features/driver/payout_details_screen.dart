import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../auth/session_controller.dart';

/// Driver payout setup: pick a bank (live Paystack list), enter the account
/// number, and the server verifies + saves it (creating the Paystack
/// subaccount that card-trip earnings settle to).
class PayoutDetailsScreen extends ConsumerStatefulWidget {
  const PayoutDetailsScreen({super.key});

  @override
  ConsumerState<PayoutDetailsScreen> createState() =>
      _PayoutDetailsScreenState();
}

class _Bank {
  const _Bank(this.name, this.code);
  final String name;
  final String code;
}

class _PayoutDetailsScreenState extends ConsumerState<PayoutDetailsScreen> {
  final _account = TextEditingController();
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

  List<_Bank> _banks = [];
  _Bank? _bank;
  bool _loadingBanks = true;
  bool _saving = false;
  String? _savedAccountName;
  Map<String, dynamic>? _existing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Existing payout details (if any) + the ZA bank list, in parallel.
    final uid = ref.read(sessionProvider).uid;
    try {
      final results = await Future.wait([
        _functions.httpsCallable('listBanks').call<List<dynamic>>(),
        if (uid != null)
          FirebaseFirestore.instance
              .collection('applications')
              .doc(uid)
              .get(),
      ]);
      final banksRes = results[0] as HttpsCallableResult<List<dynamic>>;
      final banks = banksRes.data
          .whereType<Map>()
          .map((b) => _Bank(b['name'].toString(), b['code'].toString()))
          .toList();
      Map<String, dynamic>? existing;
      if (results.length > 1) {
        final doc = results[1] as DocumentSnapshot<Map<String, dynamic>>;
        existing = doc.data()?['payout'] as Map<String, dynamic>?;
      }
      if (mounted) {
        setState(() {
          _banks = banks;
          _existing = existing;
          _loadingBanks = false;
          if (existing != null) {
            _account.text = (existing['accountNumber'] ?? '').toString();
            _savedAccountName = existing['accountName']?.toString();
            _bank = banks
                .where((b) => b.code == existing!['bankCode'])
                .firstOrNull;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingBanks = false);
    }
  }

  Future<void> _pickBank() async {
    final picked = await showModalBottomSheet<_Bank>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          itemCount: _banks.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: AppColors.line),
          itemBuilder: (context, i) => ListTile(
            title: Text(_banks[i].name),
            onTap: () => Navigator.pop(sheetContext, _banks[i]),
          ),
        ),
      ),
    );
    if (picked != null) setState(() => _bank = picked);
  }

  Future<void> _save() async {
    final bank = _bank;
    final number = _account.text.trim();
    if (bank == null || number.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pick your bank and enter the account number.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final res = await _functions
          .httpsCallable('savePayoutDetails')
          .call<Map<dynamic, dynamic>>({
        'bankCode': bank.code,
        'bankName': bank.name,
        'accountNumber': number,
      });
      final name = res.data['accountName'] as String?;
      if (mounted) {
        setState(() => _savedAccountName = name);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(name == null
                ? 'Bank details saved.'
                : 'Verified: $name. Payouts are set up.')));
        context.pop();
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.code == 'not-found'
                ? 'That account could not be verified. Check the number.'
                : 'Could not save bank details. Try again.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save bank details. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Payout details',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: _loadingBanks
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.green))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                const Text(
                  'Earnings from card trips are paid directly to your bank '
                  'account by Paystack after each trip.',
                  style: TextStyle(color: AppColors.muted, fontSize: 14),
                ),
                const SizedBox(height: 18),
                const Text('Bank',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _pickBank,
                  child: Container(
                    height: 54,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: AppColors.field,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _bank?.name ?? 'Select your bank',
                            style: TextStyle(
                              fontSize: 16,
                              color: _bank == null
                                  ? AppColors.muted
                                  : AppColors.dark,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_down,
                            color: AppColors.muted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Account number',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                TextField(
                  controller: _account,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: 'e.g. 62001234567',
                    filled: true,
                    fillColor: AppColors.field,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (_savedAccountName != null && _existing != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.verified,
                          size: 18, color: AppColors.green),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('On file: $_savedAccountName',
                            style: const TextStyle(
                                fontSize: 13.5, color: AppColors.muted)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 26),
                SizedBox(
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(27)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Verify & save',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your account is verified with your bank before saving. '
                  'Sift never stores your card or online-banking credentials.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.muted),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }
}
