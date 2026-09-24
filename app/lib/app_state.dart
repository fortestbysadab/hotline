import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'core/crypto/session_manager.dart';
import 'core/location/location_service.dart';
import 'core/network/relay_api.dart';
import 'core/network/socket_service.dart';
import 'core/storage/local_store.dart';
import 'core/webrtc/call_service.dart';
import 'models/models.dart';

export 'models/models.dart';

enum AppFlavor { client, owner }

/// One live connection to the peer of a pair: authenticated socket, E2EE
/// session, presence and typing state. The client app owns exactly one
/// channel; the owner app owns one per paired contact.
class PairChannel {
  PairChannel({required this.pairId, required this.socket, required this.session});

  final String pairId;
  final SocketService socket;
  final SessionManager session;

  bool peerOnline = false;
  bool peerTyping = false;
  bool locationSharing = false; // client: is our background stream on
  LocationSample? lastLocation; // owner: peer's latest decrypted fix
}

/// App-wide controller. Listens to every channel and exposes a uniform,
/// notifyListeners-driven API to the widgets.
class HotlineAppState extends ChangeNotifier {
  HotlineAppState({required this.flavor, required this.store, required this.api});

  final AppFlavor flavor;
  final LocalStore store;
  final RelayApi api;

  final Map<String, PairChannel> channels = {};
  final Map<String, List<ChatMessage>> _history = {};
  final Map<String, Map<String, List<Uint8List>>> _fileChunks = {};
  final Map<String, Map<String, dynamic>> _fileMeta = {};

  String? activePairId; // owner UI: which conversation is open
  bool booted = false;
  bool ownerRegistered = false;
  String? pairingError;
  LocationSample? myLastSample; // client: last fix we sent
  bool busyPairing = false;

  StreamSubscription? _locationSub;

  bool get isClient => flavor == AppFlavor.client;

  CallService? _call;

  CallService? callFor(String pairId) {
    final socket = channels[pairId]?.socket;
    if (socket == null) return null;
    return _call ??= CallService(socket: socket);
  }

  // ------------------------------------------------------------------ boot --

  Future<void> boot() async {
    if (booted) return;
    booted = true;

    if (isClient) {
      final pairing = store.myPairing;
      if (pairing != null) {
        await _openChannel(
          pairId: pairing['pairId'] as String,
          secret: pairing['pairSecret'] as String,
          contact: Contact(
            pairId: pairing['pairId'] as String,
            displayName: 'My Hotline',
            keyFingerprint: _fingerprint(pairing['ownerIdentityPubKey'] as String? ?? ''),
          ),
          connect: true,
        );
        await _resumePendingHandshake();
      }
    } else {
      await _bootOwner();
    }
    notifyListeners();
  }

  Future<void> _bootOwner() async {
    if (!RelayConfig.ownerTokenConfigured) {
      pairingError = 'OWNER_TOKEN dart-define is required for the owner app.';
      return;
    }
    try {
      final probe = SessionManager(pairId: 'identity');
      final body = await probe.ensureOwnerIdentity(RelayConfig.ownerId);
      await api.registerOwner(body);
      ownerRegistered = true;
      final pairs = await api.listPairs(RelayConfig.ownerId);
      for (final p in pairs.cast<Map>()) {
        final pair = p.cast<String, dynamic>();
        final pairId = pair['pairId'] as String;
        if (channels.containsKey(pairId)) continue;
        await _openChannel(
          pairId: pairId,
          // Owner-role sockets authenticate with the shared OWNER_TOKEN —
          // per-pair secrets are only ever handed to the redeeming client,
          // so the owner device never stores them (server-side rule matches).
          secret: RelayConfig.ownerToken,
          contact: Contact(
            pairId: pairId,
            displayName: pair['clientDisplayName'] as String? ?? 'Guest ${pairId.substring(0, 4)}',
            keyFingerprint: _fingerprint(pair['clientPubKey'] as String? ?? ''),
          ),
          connect: true,
        );
      }
    } on RelayException catch (e) {
      pairingError = 'Relay: ${e.message}';
    } catch (e) {
      pairingError = '$e';
    }
  }

  Future<void> _resumePendingHandshake() async {
    final pairing = store.myPairing;
    if (pairing == null) return;
    final channel = channels[pairing['pairId'] as String];
    if (channel == null) return;
    final session = channel.session;
    await session.ensureIdentity();
  }

  // --------------------------------------------------------------- pairing --

  /// App A only: exchange an invite code for a permanent encrypted pair.
  Future<bool> pairWithInviteCode(String rawCode, {String? displayName}) async {
    final code = rawCode.trim();
    if (code.isEmpty || busyPairing) return false;
    busyPairing = true;
    pairingError = null;
    notifyListeners();
    try {
      final session = SessionManager(pairId: 'pending');
      final identityPub = await session.ensureIdentity();
      final redeem = await api.redeemInvite(
        code: code,
        clientPubKey: identityPub,
        clientDisplayName: displayName,
      );
      final pairId = redeem['pairId'] as String;

      final realSession = SessionManager(pairId: pairId);
      await realSession.ensureIdentity();
      final handshake = await realSession.establishClientSession(
        X3dhPrekeyBundle.fromRedeemResponse(redeem),
      );

      await store.saveMyPairing(redeem);
      await _openChannel(
        pairId: pairId,
        secret: redeem['pairSecret'] as String,
        contact: Contact(
          pairId: pairId,
          displayName: 'My Hotline',
          keyFingerprint: _fingerprint(redeem['ownerIdentityPubKey'] as String? ?? ''),
        ),
        connect: true,
      );
      // Nothing to do with [handshake] here — SessionManager replays it on
      // every outbound envelope until the owner confirms the session.
      notifyListeners();
      return true;
    } on RelayException catch (e) {
      pairingError = e.message;
      return false;
    } catch (e) {
      pairingError = '$e';
      return false;
    } finally {
      busyPairing = false;
      notifyListeners();
    }
  }

  /// App B only: mint a fresh single-use invite code.
  Future<InviteCreated?> generateInvite() async {
    try {
      return await api.createInvite(RelayConfig.ownerId);
    } on RelayException {
      return null;
    }
  }

  /// App B only: cut a client off immediately.
  Future<void> revokePair(String pairId) async {
    await api.revokePair(pairId);
    channels[pairId]?.socket.dispose();
    channels.remove(pairId);
    await store.deleteContact(pairId);
    notifyListeners();
  }

  // --------------------------------------------------------------- channels --

  Future<void> _openChannel({
    required String pairId,
    required String secret,
    required Contact contact,
    required bool connect,
  }) async {
    if (channels.containsKey(pairId)) return;
    final channel = PairChannel(
      pairId: pairId,
      socket: SocketService(pairId: pairId, role: isClient ? 'client' : 'owner', secret: secret),
      session: SessionManager(pairId: pairId),
    );
    channels[pairId] = channel;
    await store.saveContact(contact);
    _history[pairId] = await store.history(pairId);

    channel.socket.events.listen((event) { _onChannelEvent(channel, event); });
    channel.socket.messages.listen((data) => _onEnvelope(channel, data));

    // Identity keys live under a fixed secure-storage key, so every
    // SessionManager instance shares the same device identity.
    await channel.session.ensureIdentity();
    if (isClient) {
      await channel.session.loadPendingHandshake();
    } else {
      // Owner: load identity+prekeys so inbound X3DH handshakes can be
      // answered by this channel's session manager.
      await channel.session.ensureOwnerIdentity(RelayConfig.ownerId);
    }
    if (connect) channel.socket.connect();
  }

  Future<void> _onChannelEvent(PairChannel channel, Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'hello':
        callFor(channel.pairId)?.updateIceServers(
          ((event['iceServers'] as List?) ?? const [])
              .cast<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList(),
        );
        break;
      case 'presence':
        channel.peerOnline = event['online'] as bool? ?? false;
        if (!channel.peerOnline) channel.peerTyping = false;
        break;
      case 'pair_revoked':
        channel.peerOnline = false;
        await store.deleteContact(channel.pairId);
        break;
      case 'typing':
        channel.peerTyping = event['typing'] as bool? ?? false;
        break;
      case 'read_receipt':
        final ids = ((event['ids'] as List?) ?? const []).cast<String>().toSet();
        final list = _history[channel.pairId] ?? const <ChatMessage>[];
        for (final m in list) {
          if (ids.contains(m.id)) {
            m.status = SendStatus.read;
            await store.updateMessage(channel.pairId, m);
          }
        }
        break;
      case 'location':
        _onLocationEnvelope(channel, event);
        break;
      default:
        final type = event['type'] as String?;
        final isCallSignal = type != null &&
            (type.startsWith('call_') ||
                type == 'rtc_offer' ||
                type == 'rtc_answer' ||
                type == 'rtc_ice');
        if (isCallSignal) {
          await callFor(channel.pairId)?.handleSignal(type, event);
        }
    }
    notifyListeners();
  }

  // -------------------------------------------------------------- messaging --

  List<ChatMessage> historyOf(String pairId) => _history[pairId] ?? const <ChatMessage>[];

  Future<void> sendChat(String pairId, String text) async {
    final channel = channels[pairId];
    if (channel == null || text.trim().isEmpty) return;
    final msg = ChatMessage(
      id: const Uuid().v4(),
      kind: MessageKind.chat,
      outgoing: true,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      status: SendStatus.sending,
      text: text.trim(),
    );
    await _recordOutgoing(channel, msg);
    final envelope = await channel.session.encryptPayload(
      jsonEncode(<String, dynamic>{'kind': 'chat', 'text': msg.text}),
    );
    await _deliver(channel, msg, envelope);
  }

  Future<void> sendFile(String pairId, String filePath) async {
    final channel = channels[pairId];
    final f = File(filePath);
    if (channel == null || !f.existsSync()) return;
    final bytes = await f.readAsBytes();
    const chunkSize = 96 * 1024;
    final fileId = const Uuid().v4();
    final fileKey = _randomBytes(32);
    final gcm = AesGcm.with256bits();

    final total = (bytes.length / chunkSize).ceil().clamp(1, 1 << 20);
    final meta = ChatMessage(
      id: const Uuid().v4(),
      kind: MessageKind.fileMeta,
      outgoing: true,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      status: SendStatus.sending,
      fileId: fileId,
      fileName: filePath.split(Platform.pathSeparator).last,
      fileSize: bytes.length,
    );
    await _recordOutgoing(channel, meta);
    final envelope = await channel.session.encryptPayload(jsonEncode(<String, dynamic>{
      'kind': 'file_meta',
      'fileId': fileId,
      'name': meta.fileName,
      'size': bytes.length,
      'chunks': total,
      'key': base64Encode(fileKey),
    }));
    await _deliver(channel, meta, envelope);

    for (var i = 0; i < total; i++) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, bytes.length);
      final nonce = _randomBytes(12);
      final box = await gcm.encrypt(
        bytes.sublist(start, end),
        secretKey: SecretKey(fileKey),
        nonce: nonce,
        aad: utf8.encode('$fileId:$i'),
      );
      await channel.socket.sendMessage(
        id: '$fileId:$i',
        kind: 'file_chunk',
        envelope: <String, dynamic>{
          'v': 1,
          'chunk': <String, dynamic>{
            'fileId': fileId,
            'index': i,
            'total': total,
            'ct': base64Encode(box.cipherText),
            'mac': base64Encode(box.mac.bytes),
            'nonce': base64Encode(nonce),
          },
        },
      );
    }
  }

  Future<void> _onEnvelope(PairChannel channel, Map<String, dynamic> data) async {
    final id = data['id'] as String? ?? const Uuid().v4();
    final kind = data['kind'] as String? ?? 'chat';

    // File chunks are AES-GCM sealed with the file key (delivered inside the
    // ratcheted file_meta) — they bypass the ratchet by design.
    if (kind == 'file_chunk') {
      await _onFileChunk(channel, data);
      return;
    }

    try {
      final innerRaw = await channel.session.decryptEnvelope(
        (data['envelope'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
      final inner = (jsonDecode(innerRaw) as Map).cast<String, dynamic>();

      switch (inner['kind']) {
        case 'chat':
          final msg = ChatMessage(
            id: id,
            kind: MessageKind.chat,
            outgoing: false,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            text: inner['text'] as String?,
          );
          await _recordIncoming(channel, msg);
          channel.socket.sendReadReceipt(<String>[id]);
          await channel.session.clearPendingHandshake();
          break;
        case 'file_meta':
          final msg = ChatMessage(
            id: id,
            kind: MessageKind.fileMeta,
            outgoing: false,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            fileId: inner['fileId'] as String?,
            fileName: inner['name'] as String?,
            fileSize: (inner['size'] as num?)?.toInt(),
          );
          _fileMeta[inner['fileId'] as String] = inner;
          _fileChunks[inner['fileId'] as String] = <String, List<Uint8List>>{};
          await _recordIncoming(channel, msg);
          await channel.session.clearPendingHandshake();
          break;
        case 'loc':
          // Location arrives via the 'location' socket event; a loc message
          // in the chat stream is only a fallback, store nothing visible.
          break;
      }
    } on Exception catch (e) {
      debugPrint('decrypt failed for $id: $e');
    }
    notifyListeners();
  }

  Future<void> _onFileChunk(PairChannel channel, Map<String, dynamic> data) async {
    final envelope = (data['envelope'] as Map?)?.cast<String, dynamic>() ?? const {};
    final chunk = (envelope['chunk'] as Map?)?.cast<String, dynamic>();
    if (chunk == null) return;
    final fileId = chunk['fileId'] as String;
    final index = (chunk['index'] as num).toInt();
    final total = (chunk['total'] as num).toInt();
    final meta = _fileMeta[fileId];
    final buckets = _fileChunks[fileId];
    if (meta == null || buckets == null) return; // meta not seen yet — drop (alpha)

    buckets[index.toString()] = <Uint8List>[
      base64Decode(chunk['ct'] as String),
      base64Decode(chunk['nonce'] as String),
      base64Decode(chunk['mac'] as String),
    ];

    if (buckets.length < total) return;
    final gcm = AesGcm.with256bits();
    final parts = BytesBuilder();
    for (var i = 0; i < total; i++) {
      final part = buckets[i.toString()];
      if (part == null) return; // gap — wait for retransmit
      final clear = await gcm.decrypt(
        SecretBox(part[0], nonce: part[1], mac: Mac(part[2])),
        secretKey: SecretKey(base64Decode(meta['key'] as String)),
        aad: utf8.encode('$fileId:$i'),
      );
      parts.add(clear);
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_${meta['name']}';
    await File(path).writeAsBytes(parts.toBytes());

    final list = _history[channel.pairId];
    if (list != null) {
      for (final m in list.reversed) {
        if (!m.outgoing && m.fileId == fileId) {
          m.filePath = path;
          await store.updateMessage(channel.pairId, m);
          break;
        }
      }
    }
    _fileChunks.remove(fileId);
    notifyListeners();
  }

  Future<void> _recordOutgoing(PairChannel channel, ChatMessage msg) async {
    (_history[channel.pairId] ??= <ChatMessage>[]).add(msg);
    await store.appendMessage(channel.pairId, msg);
    notifyListeners();
  }

  Future<void> _recordIncoming(PairChannel channel, ChatMessage msg) async {
    (_history[channel.pairId] ??= <ChatMessage>[]).add(msg);
    await store.appendMessage(channel.pairId, msg);
  }

  Future<void> _deliver(PairChannel channel, ChatMessage msg, Map<String, dynamic> envelope) async {
    final ack = await channel.socket.sendMessage(id: msg.id, kind: 'chat', envelope: envelope);
    msg.status = ack['delivered'] == true
        ? SendStatus.delivered
        : (ack['queued'] == true ? SendStatus.sent : SendStatus.failed);
    await store.updateMessage(channel.pairId, msg);
    notifyListeners();
  }

  void setTyping(String pairId, bool typing) => channels[pairId]?.socket.sendTyping(typing);

  // --------------------------------------------------------------- location --

  /// Client: toggle continuous E2EE live location sharing.
  Future<bool> toggleLocationSharing() async {
    final pairing = store.myPairing;
    if (pairing == null || !isClient) return false;
    final channel = channels[pairing['pairId'] as String];
    if (channel == null) return false;

    if (channel.locationSharing) {
      await LocationService.instance.stop();
      channel.locationSharing = false;
      _locationSub?.cancel();
      _locationSub = null;
      notifyListeners();
      return false;
    }

    final granted = await LocationService.instance.checkPermissions(requestIfNeeded: true);
    if (!granted) return false;
    await LocationService.instance.start();
    channel.locationSharing = true;
    _locationSub ??= LocationService.instance.samples.listen((raw) async {
      final sample = LocationSample(
        latitude: (raw['latitude'] as num).toDouble(),
        longitude: (raw['longitude'] as num).toDouble(),
        accuracy: ((raw['accuracy'] as num?) ?? 0).toDouble(),
        speed: ((raw['speed'] as num?) ?? 0).toDouble(),
        altitude: ((raw['altitude'] as num?) ?? 0).toDouble(),
        batteryLevel: 0,
        isCharging: false,
        timestampMs: (raw['timestampMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      );
      myLastSample = sample;
      try {
        final envelope = await channel.session.encryptPayload(jsonEncode(<String, dynamic>{
          'kind': 'loc',
          ...sample.toJson(),
        }));
        await channel.socket.sendLocation(envelope, sample.timestampMs);
      } catch (e) {
        debugPrint('location send failed: $e');
      }
      notifyListeners();
    });
    notifyListeners();
    return true;
  }

  void _onLocationEnvelope(PairChannel channel, Map<String, dynamic> event) {
    final envelope = (event['envelope'] as Map?)?.cast<String, dynamic>();
    if (envelope == null) return;
    () async {
      try {
        final inner = (jsonDecode(await channel.session.decryptEnvelope(envelope)) as Map)
            .cast<String, dynamic>();
        if (inner['kind'] == 'loc') {
          channel.lastLocation = LocationSample.fromJson(inner);
          await store.saveLocation(channel.pairId, channel.lastLocation!);
          notifyListeners();
        }
      } catch (e) {
        debugPrint('location decrypt failed: $e');
      }
    }();
  }

  // ------------------------------------------------------------------ misc --

  Contact? contactFor(String pairId) => store.getContact(pairId);

  static String _fingerprint(String pubKeyB64) {
    if (pubKeyB64.isEmpty) return '—';
    final bytes = base64Decode(pubKeyB64);
    // FNV-1a style short hash — a *display* fingerprint only.
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return (h & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _call?.dispose();
    for (final c in channels.values) {
      c.socket.dispose();
    }
    super.dispose();
  }
}
