import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';

/// App B live map: OpenStreetMap raster tiles via flutter_map — zero API
/// keys, zero per-use cost. Markers render for every paired client whose
/// decrypted location stream is live; the info card shows the encrypted
/// telemetry (speed / accuracy / battery) once decrypted on-device.
class OwnerMapScreen extends StatelessWidget {
  const OwnerMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final channels = state.channels.values.where((c) => c.lastLocation != null).toList();

    final fixes = channels.map((c) => c.lastLocation!).toList();
    final center = fixes.isNotEmpty
        ? LatLng(fixes.last.latitude, fixes.last.longitude)
        : const LatLng(22.5726, 88.3639); // neutral start (per spec example)

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: fixes.isEmpty ? 4 : 14),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.hotline.app.owner',
            ),
            MarkerLayer(
              markers: <Marker>[
                for (final c in channels)
                  Marker(
                    point: LatLng(c.lastLocation!.latitude, c.lastLocation!.longitude),
                    width: 44,
                    height: 56,
                    alignment: Alignment.topCenter,
                    child: _PeerPin(
                      label: state.contactFor(c.pairId)?.displayName ?? 'Guest',
                      moving: c.lastLocation!.isMoving,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ],
        ),
        if (channels.isEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Card(
              color: const Color(0xEE121821),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No live location streams.\nA client appears here the moment they enable sharing — '
                  'their coordinates arrive AES-256-GCM encrypted and are only decrypted on this device.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          )
        else
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Column(
              children: [
                for (final c in channels)
                  Card(
                    color: const Color(0xE6121821),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        c.lastLocation!.isMoving ? Icons.directions_walk_rounded : Icons.phonelink_lock_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(
                        state.contactFor(c.pairId)?.displayName ?? 'Guest',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '±${c.lastLocation!.accuracy.toStringAsFixed(0)} m · '
                        '${(c.lastLocation!.speed * 3.6).toStringAsFixed(1)} km/h · '
                        'updated ${_ago(c.lastLocation!.timestampMs)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Text(
                        '${c.lastLocation!.batteryLevel}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: c.lastLocation!.batteryLevel < 20
                              ? Theme.of(context).colorScheme.error
                              : Colors.white38,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now().millisecondsSinceEpoch - ms;
    if (d < 60_000) return '${(d / 1000).round()}s ago';
    if (d < 3_600_000) return '${(d / 60_000).round()}m ago';
    return '${(d / 3_600_000).round()}h ago';
  }
}

class _PeerPin extends StatelessWidget {
  const _PeerPin({
    required this.label,
    required this.moving,
    required this.color,
  });

  final String label;
  final bool moving;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xEE0B0F14),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: const TextStyle(fontSize: 10)),
        ),
        Icon(
          moving ? Icons.directions_walk_rounded : Icons.location_on_rounded,
          color: color,
          size: 34,
          shadows: const <Shadow>[Shadow(blurRadius: 8, color: Color(0x88000000))],
        ),
      ],
    );
  }
}
