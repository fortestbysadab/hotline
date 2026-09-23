import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';

/// Continuous, battery-aware live location engine (App A).
///
/// A foreground service keeps Android alive while the user shares location;
/// an adaptive sampler follows §5.2 of the architecture doc:
///
///   in motion (>5 km/h):  fix every ~4 s, 10 m distance filter
///   stationary (<5 km/h): fix every ~60 s, 50 m distance filter
///
/// The background isolate only *produces* samples (`service.invoke`) —
/// encryption and transport stay in the main isolate, where the E2EE session
/// lives. A persistent status-bar notification is mandated by Android for
/// this kind of foreground execution.
class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _configured = false;
  bool _running = false;

  /// Emits samples produced by the background isolate.
  Stream<Map<String, dynamic>> get samples =>
      _service.on('location').map<Map<String, dynamic>>((e) => (e as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{});

  Future<bool> checkPermissions({bool requestIfNeeded = false}) async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && requestIfNeeded) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.whileInUse || perm == LocationPermission.always;
  }

  Future<void> configure() async {
    if (_configured) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _backgroundEntry,
        isForegroundMode: true,
        autoStartOnBoot: false,
        notificationChannelId: 'hotline_location',
        initialNotificationTitle: 'Hotline',
        initialNotificationContent: 'Live location sharing is active',
        foregroundServiceNotificationId: 4711,
        foregroundServiceTypes: <AndroidForegroundType>[AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(),
    );
    _configured = true;
  }

  Future<void> start() async {
    await configure();
    _running = await _service.startService();
  }

  Future<void> stop() async {
    _service.invoke('stop_stream');
    _running = false;
  }

  bool get isRunning => _running;
}

/// Entry point inside the background isolate. Never touches Hive, secure
/// storage or sockets — all of that belongs to the main isolate.
@pragma('vm:entry-point')
Future<void> _backgroundEntry(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  LocationSettings settings = const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 50, // stationary default
  );
  StreamSubscription<Position>? sub;
  bool moving = false;

  void listen() {
    sub?.cancel();
    sub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      final speed = pos.speed.isNaN ? 0.0 : pos.speed;
      final nowMoving = speed > 1.4; // > ~5 km/h
      if (nowMoving != moving) {
        moving = nowMoving;
        settings = LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: moving ? 10 : 50,
        );
        listen();
      }
      service.invoke('location', <String, dynamic>{
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'speed': speed,
        'altitude': pos.altitude,
        'timestampMs': pos.timestamp.millisecondsSinceEpoch,
      });
    });
  }

  listen();

  service.on('stop_stream').listen((_) async {
    await sub?.cancel();
    sub = null;
    service.stopSelf();
  });
}
