import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';

/// Hard stop shown when this build is older than `config/pricing.minVersion`.
/// Old clients predate money-critical contracts, so they don't get to run.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  Future<void> _openStore() async {
    const id = 'za.co.sift.app';
    final market = Uri.parse('market://details?id=$id');
    if (await launchUrl(market, mode: LaunchMode.externalApplication)) return;
    await launchUrl(
      Uri.parse('https://play.google.com/store/apps/details?id=$id'),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppColors.selectedFill,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.system_update,
                    color: AppColors.green, size: 44),
              ),
              const SizedBox(height: 20),
              const Text('Update Sift to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                'This version is no longer supported. Get the latest version '
                'for new features and fixes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 14.5),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _openStore,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27)),
                  ),
                  child: const Text('Update now',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
