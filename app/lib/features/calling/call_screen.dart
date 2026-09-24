import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/webrtc/call_service.dart';

/// Full-screen encrypted call UI (audio & video). Media is peer-to-peer
/// (DTLS-SRTP); the relay only shuffled SDP/ICE.
class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.pairId});

  final String pairId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final call = state.callFor(pairId);
    if (call == null) {
      return const Scaffold(body: Center(child: Text('Line unavailable')));
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E13),
      body: SafeArea(
        child: Column(
          children: [
            _Header(call: call),
            Expanded(
              child: call.isVideo ? _VideoStage(call: call) : _AudioStage(call: call),
            ),
            _Controls(pairId: pairId, call: call),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.call});

  final CallService call;

  @override
  Widget build(BuildContext context) {
    final label = switch (call.phase) {
      CallPhase.dialing => 'Encrypted line — calling…',
      CallPhase.ringing => 'Incoming encrypted call',
      CallPhase.connecting => 'Securing line…',
      CallPhase.active => 'Encrypted call in progress',
      _ => 'Call ended',
    };
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Icon(Icons.lock_rounded, size: 18, color: Colors.white38),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white54)),
          if (call.error != null)
            Text(
              call.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _VideoStage extends StatelessWidget {
  const _VideoStage({required this.call});

  final CallService call;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: call.phase == CallPhase.active
              ? RTCVideoView(call.remoteRenderer)
              : const Center(child: Icon(Icons.person_rounded, size: 96, color: Colors.white12)),
        ),
        Positioned(
          top: 12,
          right: 12,
          width: 110,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: RTCVideoView(call.localRenderer, mirror: true),
          ),
        ),
      ],
    );
  }
}

class _AudioStage extends StatelessWidget {
  const _AudioStage({required this.call});

  final CallService call;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 56,
            backgroundColor: Theme.of(context).colorScheme.secondary,
            child: const Icon(Icons.shield_rounded, size: 52),
          ),
          const SizedBox(height: 16),
          AnimatedOpacity(
            opacity: call.phase == CallPhase.active ? 1 : 0.5,
            duration: const Duration(milliseconds: 300),
            child: const Text('peer-to-peer · DTLS-SRTP', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.pairId, required this.call});

  final String pairId;
  final CallService call;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 32, top: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (call.phase == CallPhase.ringing) ...[
            _RoundAction(
              icon: Icons.call_end_rounded,
              color: accent.error,
              onTap: () => call.rejectIncoming().then((_) => _pop(context)),
            ),
            _RoundAction(
              icon: Icons.call_rounded,
              color: accent.primary,
              onTap: () => call.acceptIncoming(),
            ),
          ] else ...[
            _RoundAction(
              icon: call.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
              color: Colors.white24,
              onTap: () => call.toggleMute(),
            ),
            if (call.isVideo)
              _RoundAction(
                icon: call.cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                color: Colors.white24,
                onTap: () => call.toggleCamera(),
              ),
            _RoundAction(
              icon: Icons.call_end_rounded,
              color: accent.error,
              onTap: () => call.endCall().then((_) => _pop(context)),
            ),
          ],
        ],
      ),
    );
  }

  static void _pop(BuildContext context) {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.color, required this.onTap});

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: color == Colors.white24 ? Colors.white : Colors.black),
        ),
      ),
    );
  }
}
