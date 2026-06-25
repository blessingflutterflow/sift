// Smoke test: the app boots into the Verification (OTP) screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sift_app/main.dart';

void main() {
  testWidgets('boots into the verification screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SiftApp()));
    await tester.pump();

    expect(find.text('Continue'), findsOneWidget);
    expect(find.textContaining('send a code'), findsOneWidget);
  });
}
