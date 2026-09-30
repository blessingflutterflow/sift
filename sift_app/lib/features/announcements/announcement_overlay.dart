import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'announcement.dart';

/// Wraps the whole app (via MaterialApp.router `builder`) and floats a
/// full-screen takeover over everything whenever the current driver has an
/// active, undismissed announcement. Nothing dismisses it but the button, and
/// it re-appears on every app open until the driver taps "Got it".
class AnnouncementGate extends ConsumerWidget {
  const AnnouncementGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingAnnouncementsProvider);
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        child,
        if (pending.isNotEmpty)
          Positioned.fill(
            // key by id so switching to the next queued announcement animates.
            child: _Takeover(key: ValueKey(pending.first.id), a: pending.first),
          ),
      ],
    );
  }
}

class _Style {
  const _Style(this.accent, this.icon, this.label);
  final Color accent;
  final IconData icon;
  final String label;
}

_Style _styleFor(String severity) {
  switch (severity) {
    case 'critical':
      return const _Style(
          Color(0xFFE0524D), Icons.report_gmailerrorred_rounded, 'Important');
    case 'warning':
      return const _Style(
          Color(0xFFF59E0B), Icons.warning_amber_rounded, 'Notice');
    default:
      return const _Style(Color(0xFF2563EB), Icons.campaign_rounded, 'Update');
  }
}

class _Takeover extends ConsumerStatefulWidget {
  const _Takeover({super.key, required this.a});
  final Announcement a;

  @override
  ConsumerState<_Takeover> createState() => _TakeoverState();
}

class _TakeoverState extends ConsumerState<_Takeover> {
  bool _busy = false;

  Future<void> _dismiss() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(announcementRepositoryProvider).dismiss(widget.a.id);
    // The provider stream will drop this one; if another is queued it slides in.
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final s = _styleFor(a.severity);
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Severity band + icon.
                  Container(
                    color: s.accent,
                    padding: const EdgeInsets.fromLTRB(24, 26, 24, 26),
                    child: Column(
                      children: [
                        Icon(s.icon, color: Colors.white, size: 52),
                        const SizedBox(height: 10),
                        Text(
                          s.label.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          a.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF16181D),
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          a.body,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.45,
                            color: Color(0xFF3C3F47),
                          ),
                        ),
                        if (a.createdAt != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _fmt(a.createdAt!),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF9A9CA5),
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        SizedBox(
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _busy ? null : _dismiss,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: s.accent,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(27),
                              ),
                            ),
                            child: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.5, color: Colors.white),
                                  )
                                : const Text(
                                    'Got it',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]}, $h:$m';
  }
}
