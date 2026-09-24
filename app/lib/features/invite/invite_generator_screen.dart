import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/network/relay_api.dart';
import '../../app_state.dart';

/// App B invite generator: mint single-use codes, show them once, and offer
/// a shareable deep link (hotline://join?c=…).
class InviteGeneratorScreen extends StatefulWidget {
  const InviteGeneratorScreen({super.key});

  @override
  State<InviteGeneratorScreen> createState() => _InviteGeneratorScreenState();
}

class _InviteGeneratorScreenState extends State<InviteGeneratorScreen> {
  InviteCreated? _last;
  bool _busy = false;

  Future<void> _generate() async {
    setState(() => _busy = true);
    final invite = await context.read<HotlineAppState>().generateInvite();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _last = invite;
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = _last?.code;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Invitation-only access',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Every code works exactly once and expires. Send it to one person '
          'over a channel you trust — they enter it in the Hotline app and '
          'their device pairs with yours permanently.',
          style: TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_link_rounded),
          label: const Text('Generate invitation'),
        ),
        const SizedBox(height: 24),
        if (code != null) _CodeCard(code: code, expiresAtMs: _last!.expiresAtMs),
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.expiresAtMs});

  final String code;
  final int expiresAtMs;

  @override
  Widget build(BuildContext context) {
    final expiry = DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(expiresAtMs));
    final link = 'hotline://join?c=${Uri.encodeComponent(code)}';
    return Card(
      color: const Color(0xFF121821),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_rounded, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                const Text('Single-use code'),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              code,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 0.3),
            ),
            const SizedBox(height: 8),
            Text('Expires $expiry · works once', style: const TextStyle(fontSize: 12, color: Colors.white38)),
            const Divider(height: 28),
            const Text('Invitation link', style: TextStyle(fontSize: 12, color: Colors.white38)),
            const SizedBox(height: 4),
            SelectableText(link, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copy the code above and send it over a trusted channel')),
                );
              },
              icon: const Icon(Icons.share_rounded),
              label: const Text('Share via… (alpha: copy manually)'),
            ),
          ],
        ),
      ),
    );
  }
}
