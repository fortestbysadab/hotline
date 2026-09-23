import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../../config.dart';

/// Wraps one authenticated pair socket (Socket.io).
///
/// One instance per pair: the client app has exactly one (its owner), the
/// owner app runs one per paired contact. Reconnection is automatic; the
/// server re-authenticates and drains the offline queue on every reconnect.
class SocketService {
  SocketService({required this.pairId, required this.role, required this.secret});

  final String pairId;
  final String role; // 'owner' | 'client'
  final String secret;

  IO.Socket? _socket;
  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  final List<Map<String, dynamic>> _pendingIce = [];

  bool get isConnected => _socket?.connected ?? false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<Map<String, dynamic>> get events => _events.stream;

  void connect() {
    if (_socket != null) return;
    _socket = IO.io(
      RelayConfig.relayUrl,
      IO.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'pairId': pairId, 'role': role, 'secret': secret})
          .enableForceNew()
          .disableAutoConnect()
          .build(),
    );

    final socket = _socket!;
    socket.onConnect((_) {
      _events.add(<String, dynamic>{'type': 'connected'});
      for (final c in _pendingIce) {
        socket.emit('rtc:ice', c);
      }
      _pendingIce.clear();
    });
    socket.onDisconnect((_) => _events.add(<String, dynamic>{'type': 'disconnected'}));
    socket.onConnectError((data) => _events.add(<String, dynamic>{'type': 'connect_error', 'error': '$data'}));

    socket.on('hello', (data) => _events.add(_asMap(data)..['type'] = 'hello'));
    socket.on('presence', (data) => _events.add(_asMap(data)..['type'] = 'presence'));
    socket.on('pair:revoked', (data) => _events.add(_asMap(data)..['type'] = 'pair_revoked'));
    socket.on('msg:read', (data) => _events.add(_asMap(data)..['type'] = 'read_receipt'));
    socket.on('typing', (data) => _events.add(_asMap(data)..['type'] = 'typing'));
    socket.on('location', (data) => _events.add(_asMap(data)..['type'] = 'location'));

    // Encrypted envelope relay — the core channel.
    socket.on('msg', (data) => _messages.add(_asMap(data)));

    // WebRTC call signaling.
    for (final ev in const <String>['call:invite', 'call:accept', 'call:reject', 'call:end', 'rtc:offer', 'rtc:answer', 'rtc:ice']) {
      socket.on(ev, (data) => _events.add(_asMap(data)..['type'] = ev.replaceAll(':', '_')));
    }

    socket.connect();
  }

  static Map<String, dynamic> _asMap(Object? data) =>
      data is Map ? (data).cast<String, dynamic>() : <String, dynamic>{'raw': data};

  /// Sends an encrypted envelope; resolves to the server ack
  /// ({delivered: bool, queued: bool}).
  Future<Map<String, dynamic>> sendMessage({
    required String id,
    required String kind,
    required Map<String, dynamic> envelope,
  }) async {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      return <String, dynamic>{'ok': false, 'delivered': false, 'queued': false, 'offline': true};
    }
    final completer = Completer<Map<String, dynamic>>();
    socket.emitWithAck(
      'msg',
      <String, dynamic>{'id': id, 'kind': kind, 'envelope': envelope},
      ack: (res) {
        if (!completer.isCompleted) {
          completer.complete(res is Map ? (res).cast<String, dynamic>() : <String, dynamic>{});
        }
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => <String, dynamic>{'ok': false, 'delivered': false, 'queued': false, 'timeout': true},
    );
  }

  void sendReadReceipt(List<String> ids) {
    _socket?.emit('msg:read', <String, dynamic>{'ids': ids});
  }

  void sendTyping(bool typing) {
    _socket?.emit('typing', <String, dynamic>{'typing': typing});
  }

  /// Sends an E2EE location envelope (client → owner).
  Future<void> sendLocation(Map<String, dynamic> envelope, int timestampMs) async {
    _socket?.emit('location', <String, dynamic>{'envelope': envelope, 'timestamp': timestampMs});
  }

  // ------------------------------------------------------- call signaling --

  void callInvite({required String callId, required String media}) =>
      _emit('call:invite', <String, dynamic>{'callId': callId, 'media': media});

  void callAccept(String callId) => _emit('call:accept', <String, dynamic>{'callId': callId});

  void callReject(String callId) => _emit('call:reject', <String, dynamic>{'callId': callId});

  void callEnd(String callId) => _emit('call:end', <String, dynamic>{'callId': callId});

  void rtcOffer(String callId, String sdp) =>
      _emit('rtc:offer', <String, dynamic>{'callId': callId, 'sdp': sdp});

  void rtcAnswer(String callId, String sdp) =>
      _emit('rtc:answer', <String, dynamic>{'callId': callId, 'sdp': sdp});

  void rtcIce(String callId, Map<String, dynamic> candidate) {
    final payload = <String, dynamic>{'callId': callId, 'candidate': candidate};
    if (!isConnected) {
      _pendingIce.add(payload); // queue ICE until the socket is up
      return;
    }
    _emit('rtc:ice', payload);
  }

  void _emit(String event, Map<String, dynamic> payload) {
    _socket?.emit(event, payload);
  }

  void dispose() {
    _socket?.dispose();
    _socket = null;
    _messages.close();
    _events.close();
  }
}
