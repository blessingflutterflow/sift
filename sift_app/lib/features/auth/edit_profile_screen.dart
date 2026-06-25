import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/user_repository.dart';
import 'session_controller.dart';

/// Edit name + email (phone is the sign-in identity and stays fixed).
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _name = TextEditingController(text: s.name);
    _email = TextEditingController(text: s.email);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = ref.read(sessionProvider);
    final uid = s.uid;
    final role = s.role;
    if (uid == null || role == null) return;
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty) return;
    if (email.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That email doesn\'t look right.')));
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(userRepositoryProvider).upsertProfile(
            uid: uid,
            phone: s.phone,
            role: role,
            name: name,
            email: email,
            status: s.status,
          );
      ref
          .read(sessionProvider.notifier)
          .updateContact(name: name, email: email);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile updated.')));
        context.pop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Edit profile',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          _label('Full name'),
          _field(_name, hint: 'Your name', keyboard: TextInputType.name),
          const SizedBox(height: 16),
          _label('Email'),
          _field(_email,
              hint: 'you@example.com',
              keyboard: TextInputType.emailAddress),
          const SizedBox(height: 16),
          _label('Phone'),
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              s.phone.isEmpty ? '—' : s.phone,
              style: const TextStyle(fontSize: 16, color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Your phone number is your sign-in and can\'t be changed.',
              style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
          const SizedBox(height: 28),
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
                  : const Text('Save',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      );

  Widget _field(TextEditingController c,
      {required String hint, required TextInputType keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: AppColors.field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
