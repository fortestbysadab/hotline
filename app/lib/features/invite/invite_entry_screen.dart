import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';

/// App A first launch: enter the single-use invitation code received from
/// the Owner. No public registration exists — this is the only door in.
class InviteEntryScreen extends StatefulWidget {
  const InviteEntryScreen({super.key});

  @override
  State<InviteEntryScreen> createState() => _InviteEntryScreenState();
}

class _InviteEntryScreenState extends State<InviteEntryScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final state = context.read<HotlineAppState>();
    final ok = await state.pairWithInviteCode(_controller.text);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.pairingError ?? 'Pairing failed')),
      );
    }
    // On success the state flips and _HomeGate navigates automatically.
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.call_rounded,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Private Hotline',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'One line. One person. Fully encrypted.\nEnter the invitation code you received.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white54),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _controller,
                maxLines: 2,
                minLines: 1,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  hintText: 'owner-id~invitation-code',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: state.busyPairing ? null : _submit,
                child: state.busyPairing
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect my hotline'),
              ),
              const SizedBox(height: 12),
              Text(
                state.pairingError ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const Spacer(),
              Text(
                'Invitation codes are single-use and expire. '
                'Ask your hotline contact for a new one if yours was used.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
