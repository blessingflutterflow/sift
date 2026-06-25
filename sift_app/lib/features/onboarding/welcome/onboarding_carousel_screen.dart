import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/primary_button.dart';

/// Screen 1 (second half) — the first-launch onboarding carousel. Three slides
/// introduce Sift's core value props, then the user proceeds to registration.
///
/// Shown only on the first launch: completion is persisted via
/// [markOnboardingSeen] and the splash screen routes past it on later launches.
class OnboardingCarouselScreen extends StatefulWidget {
  const OnboardingCarouselScreen({super.key});

  /// SharedPreferences key recording that onboarding has been completed.
  static const String seenKey = 'onboarding_seen';

  /// Whether the first-launch onboarding has already been shown.
  static Future<bool> hasSeen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(seenKey) ?? false;
  }

  /// Persist that the user has finished (or skipped) onboarding.
  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(seenKey, true);
  }

  @override
  State<OnboardingCarouselScreen> createState() =>
      _OnboardingCarouselScreenState();
}

class _OnboardingScreenContent {
  const _OnboardingScreenContent({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

const List<_OnboardingScreenContent> _slides = [
  _OnboardingScreenContent(
    icon: Icons.electric_bolt,
    title: 'Rides in minutes',
    body:
        'Request a ride and the closest Sift driver is on their way. No haggling, no waiting around.',
  ),
  _OnboardingScreenContent(
    icon: Icons.my_location,
    title: 'Track every step',
    body:
        'Watch your driver approach in real time and follow your whole trip live on the map.',
  ),
  _OnboardingScreenContent(
    icon: Icons.account_balance_wallet_outlined,
    title: 'Pay your way',
    body:
        'Card or cash, your choice — with a clear, upfront fare before you ever confirm a ride.',
  ),
];

class _OnboardingCarouselScreenState extends State<OnboardingCarouselScreen> {
  final _pageController = PageController();
  int _page = 0;

  bool get _isLast => _page == _slides.length - 1;

  Future<void> _finish() async {
    await OnboardingCarouselScreen.markSeen();
    if (mounted) context.go(AppRouter.verification);
  }

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Skip — top-right, hidden on the last slide where the CTA finishes.
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 0),
                child: TextButton(
                  onPressed: _isLast ? null : _finish,
                  child: Text(
                    _isLast ? '' : 'Skip',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _slides.length,
                itemBuilder: (context, i) => _Slide(content: _slides[i]),
              ),
            ),
            _Dots(count: _slides.length, active: _page),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: PrimaryButton(
                label: _isLast ? 'Get started' : 'Next',
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  const _Slide({required this.content});
  final _OnboardingScreenContent content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 140,
            height: 140,
            decoration: const BoxDecoration(
              color: AppColors.selectedFill,
              shape: BoxShape.circle,
            ),
            child: Icon(content.icon, size: 64, color: AppColors.green),
          ),
          const SizedBox(height: 40),
          Text(
            content.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: AppColors.dark,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            content.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              color: AppColors.muted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final on = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: on ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: on ? AppColors.green : AppColors.line,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
