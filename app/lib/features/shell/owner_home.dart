import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../calling/call_screen.dart';
import '../chat/chat_screen.dart';
import '../invite/invite_generator_screen.dart';
import '../map/owner_map_screen.dart';

/// App B main shell — the Owner's command center:
///   • Inbox   every paired client as its own private thread
///   • Map     live OpenStreetMap view of clients streaming location
///   • Invites single-use code generator
class OwnerHome extends StatefulWidget {
  const OwnerHome({super.key});

  @override
  State<OwnerHome> createState() => _OwnerHomeState();
}

class _OwnerHomeState extends State<OwnerHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final contacts = state.store.allContacts();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Command Center'),
            Text(
              state.ownerRegistered ? 'relay connected · ${contacts.length} paired' : 'relay: not registered',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
        actions: [
          if (state.pairingError != null)
            IconButton(
              tooltip: state.pairingError,
              icon: Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error),
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.pairingError!))),
            ),
        ],
      ),
      body: switch (_tab) {
        0 => _InboxTab(state: state, contacts: contacts),
        1 => const OwnerMapScreen(),
        _ => const InviteGeneratorScreen(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.forum_rounded), label: 'Inbox'),
          NavigationDestination(icon: Icon(Icons.map_rounded), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.person_add_alt_1_rounded), label: 'Invites'),
        ],
      ),
    );
  }
}

class _InboxTab extends StatelessWidget {
  const _InboxTab({required this.state, required this.contacts});

  final HotlineAppState state;
  final List contacts;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_add_alt_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              const Text('No paired clients yet'),
              const SizedBox(height: 8),
              const Text(
                'Open the Invites tab, generate a single-use code\nand send it to someone you trust.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: contacts.length,
      itemBuilder: (context, i) {
        final c = contacts[i] as dynamic;
        final pairId = c.pairId as String;
        final channel = state.channels[pairId];
        final history = state.historyOf(pairId);
        final last = history.isEmpty ? null : history.last;
        return ListTile(
          leading: Stack(
            alignment: Alignment.bottomRight,
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                child: Text(
                  (c.displayName as String?)?.isEmpty == false
                      ? (c.displayName as String).substring(0, 1).toUpperCase()
                      : '?',
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (channel?.peerOnline ?? false)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white24,
                ),
              ),
            ],
          ),
          title: Text(c.displayName as String? ?? 'Unnamed'),
          subtitle: Text(
            last == null
                ? 'tap to open the private line'
                : (last.text ?? (last.kind == MessageKind.fileMeta ? '📎 encrypted file' : '…')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: (channel?.lastLocation != null)
              ? Icon(Icons.location_on_rounded, color: Theme.of(context).colorScheme.primary, size: 18)
              : null,
          onTap: () => _openThread(context, pairId, name: c.displayName as String? ?? 'Guest'),
          onLongPress: () => _confirmRevoke(context, pairId, c.displayName as String? ?? 'this guest'),
        );
      },
    );
  }

  void _openThread(BuildContext context, String pairId, {required String name}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _OwnerThread(pairId: pairId, name: name),
      ),
    );
  }

  void _confirmRevoke(BuildContext context, String pairId, String name) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke access?'),
        content: Text('$name will be disconnected immediately and cannot reconnect.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () {
              context.read<HotlineAppState>().revokePair(pairId);
              Navigator.pop(ctx);
            },
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }
}

/// The Owner's view of one client thread — same encrypted chat surface,
/// with call buttons in the app bar.
class _OwnerThread extends StatelessWidget {
  const _OwnerThread({required this.pairId, required this.name});

  final String pairId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final channel = state.channels[pairId];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(name),
            const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (channel?.peerOnline ?? false)
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white24,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded),
            onPressed: () => _call(context, video: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => _call(context, video: true),
          ),
        ],
      ),
      body: ChatScreen(pairId: pairId),
    );
  }

  void _call(BuildContext context, {required bool video}) {
    final call = context.read<HotlineAppState>().callFor(pairId);
    if (call == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CallScreen(pairId: pairId)),
    );
    call.startCall(video: video);
  }
}
