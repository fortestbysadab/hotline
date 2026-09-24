import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../calling/call_screen.dart';
import '../chat/chat_screen.dart';

/// App A main portal: a single, dedicated conversation with the Owner,
/// plus the live-location safety switch and one-tap encrypted calls.
/// There is deliberately no contact list, no search, no groups.
class ClientHome extends StatelessWidget {
  const ClientHome({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final pairing = state.store.myPairing;
    if (pairing == null) {
      return const Scaffold(body: Center(child: Text('Not paired')));
    }
    final pairId = pairing['pairId'] as String;
    final channel = state.channels[pairId];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  child: const Icon(Icons.shield_rounded, size: 20),
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
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('My Hotline', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Text(
                  channel?.peerOnline ?? false ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    color: channel?.peerOnline ?? false
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white38,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => _startCall(context, pairId, video: false),
          ),
          IconButton(
            tooltip: 'Video call',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => _startCall(context, pairId, video: true),
          ),
          IconButton(
            tooltip: channel?.locationSharing ?? false
                ? 'Stop live location'
                : 'Start live location',
            icon: Icon(
              Icons.location_on_rounded,
              color: (channel?.locationSharing ?? false)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: () async {
              final ok = await context.read<HotlineAppState>().toggleLocationSharing();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? ((channel?.locationSharing ?? false)
                            ? 'Live location is ON — encrypted, owner only'
                            : 'Live location stopped')
                        : 'Location permission denied',
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: ChatScreen(pairId: pairId),
    );
  }

  void _startCall(BuildContext context, String pairId, {required bool video}) {
    final state = context.read<HotlineAppState>();
    final call = state.callFor(pairId);
    if (call == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CallScreen(pairId: pairId)),
    );
    call.startCall(video: video);
  }
}
