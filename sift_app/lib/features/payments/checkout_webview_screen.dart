import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_colors.dart';

/// In-app Paystack checkout. Pops with `true` when payment is confirmed.
///
/// Two completion signals, whichever lands first:
///  • [doneSignal] — the caller watches Firestore for the webhook's write
///    (new card doc / ride flips to paid), the authoritative confirmation.
///  • Paystack's success redirect to standard.paystack.co/close — optimistic,
///    the webhook usually lands within a second anyway.
class CheckoutWebViewScreen extends StatefulWidget {
  const CheckoutWebViewScreen({
    super.key,
    required this.url,
    required this.title,
    this.doneSignal,
  });

  final String url;
  final String title;
  final Stream<void>? doneSignal;

  @override
  State<CheckoutWebViewScreen> createState() => _CheckoutWebViewScreenState();
}

class _CheckoutWebViewScreenState extends State<CheckoutWebViewScreen> {
  late final WebViewController _controller;
  StreamSubscription<void>? _doneSub;
  bool _loading = true;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _doneSub = widget.doneSignal?.listen((_) => _finish(true));
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onNavigationRequest: (request) {
          final url = request.url;
          // Paystack's "close" endpoint = checkout finished/cancelled.
          if (url.startsWith('https://standard.paystack.co/close')) {
            _finish(true);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  void _finish(bool ok) {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop(ok);
  }

  @override
  void dispose() {
    _doneSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title,
            style: const TextStyle(
                color: AppColors.dark,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: AppColors.dark),
          onPressed: () => _finish(false),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(
                child: CircularProgressIndicator(color: AppColors.green)),
        ],
      ),
    );
  }
}
