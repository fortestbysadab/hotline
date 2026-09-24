import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'double_ratchet.dart';
import 'x3dh.dart';

/// Manages one E2EE session per pair, plus the device identity keys.
///
/// All key material lives in [FlutterSecureStorage] (Android Keystore-backed);
/// only PUBLIC keys ever leave the device. The ratchet state is persisted
/// after every operation so message chains survive restarts.
class SessionManager {
  SessionManager({
    required this.pairId,
    FlutterSecureStorage? secureStorage,
  }) : _storage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final String pairId;
  final FlutterSecureStorage _storage;

  static const String _kIdentity = 'identity';
  static String _sessionKey(String pairId) => 'session_$pairId';

  DoubleRatchet? _session;
  bool _sessionConfirmed = false; // true after first inbound ratchet message

  /// Local X25519 identity key pair (client), plus owner extras when App B.
  SimpleKeyPair? _identity;
  OwnerIdentityMaterial? _ownerIdentity;

  List<int> get _aad => utf8.encode(pairId); // binds ciphertext to the pair

  // ------------------------------------------------------------ identities --

  /// Loads or creates this device's X25519 identity key. Returns the public
  /// half (base64) for pairing.
  Future<String> ensureIdentity() async {
    if (_identity != null) {
      return base64Encode((await _identity!.extractPublicKey()).bytes);
    }
    final raw = await _storage.read(key: _kIdentity);
    if (raw != null) {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _identity = await X25519().newKeyPairFromSeed(base64Decode(m['ik'] as String));
      return base64Encode((await _identity!.extractPublicKey()).bytes);
    }
    final kp = await X25519().newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    _identity = await X25519().newKeyPairFromSeed(seed);
    await _storage.write(
      key: _kIdentity,
      value: jsonEncode(<String, String>{'ik': base64Encode(seed)}),
    );
    return base64Encode((await _identity!.extractPublicKey()).bytes);
  }

  /// App B: loads or creates the full owner identity (identity + signed
  /// prekey + Ed25519 signing key) and returns the registration body.
  Future<Map<String, String>> ensureOwnerIdentity(String ownerId) async {
    if (_ownerIdentity != null) return _ownerIdentity!.registrationBody(ownerId);
    final raw = await _storage.read(key: _kIdentity);
    if (raw != null) {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final identity = await X25519().newKeyPairFromSeed(base64Decode(m['ik'] as String));
      final spk = await X25519().newKeyPairFromSeed(base64Decode(m['spk'] as String));
      final signing = await Ed25519().newKeyPairFromSeed(base64Decode(m['sig'] as String));
      final spkPub = Uint8List.fromList((await spk.extractPublicKey()).bytes);
      final sigPub = Uint8List.fromList((await signing.extractPublicKey()).bytes);
      final spkSig = Uint8List.fromList(
        (await Ed25519().sign(spkPub, keyPair: signing)).bytes,
      );
      _identity = identity;
      _ownerIdentity = OwnerIdentityMaterial(
        identity: identity,
        signedPrekey: spk,
        signing: signing,
        identityPub: Uint8List.fromList((await identity.extractPublicKey()).bytes),
        signedPrekeyPub: spkPub,
        signingPub: sigPub,
        prekeySignature: spkSig,
      );
      return _ownerIdentity!.registrationBody(ownerId);
    }
    final material = await X3dh.createOwnerIdentity();
    _identity = material.identity;
    _ownerIdentity = material;
    await _storage.write(
      key: _kIdentity,
      value: jsonEncode(<String, String>{
        'ik': base64Encode(await material.identity.extractPrivateKeyBytes()),
        'spk': base64Encode(await material.signedPrekey.extractPrivateKeyBytes()),
        'sig': base64Encode(await material.signing.extractPrivateKeyBytes()),
      }),
    );
    return material.registrationBody(ownerId);
  }

  // ------------------------------------------------------------- sessions --

  /// Client: build the session from the owner's prekey bundle obtained at
  /// invite redemption. The returned x3dh block is also stored locally and
  /// rides along on outbound messages until the session is confirmed.
  Future<Map<String, dynamic>> establishClientSession(X3dhPrekeyBundle bundle) async {
    final existing = await _loadSession();
    if (existing != null) {
      _session = existing;
      await loadPendingHandshake();
      return _pendingHandshake ?? <String, dynamic>{};
    }
    if (!(await bundle.verifySignature())) {
      throw SecurityError('owner prekey signature verification failed');
    }
    final init = await X3dh.initiate(identityKeyPair: _identity!, bundle: bundle);
    _session = await DoubleRatchet.initiate(
      rootKey: init.sharedSecret,
      remoteInitialDhPub: bundle.signedPrekeyPub,
    );
    await _persistSession();
    final block = <String, dynamic>{
      'ik': base64Encode((await _identity!.extractPublicKey()).bytes),
      'ek': base64Encode(init.ephemeralPub),
    };
    await storePendingHandshake(block);
    return block;
  }

  /// Owner: establish (or reuse) the session from an inbound x3dh block.
  Future<void> ensureOwnerSessionFromInitial(Map<String, dynamic> x3dh) async {
    final existing = await _loadSession();
    if (existing != null) {
      _session = existing;
      return;
    }
    final sk = await X3dh.respond(
      identityKeyPair: _identity!,
      signedPrekeyPair: _ownerIdentity!.signedPrekey,
      clientIdentityPub: base64Decode(x3dh['ik'] as String),
      clientEphemeralPub: base64Decode(x3dh['ek'] as String),
    );
    _session = await DoubleRatchet.respond(
      rootKey: sk,
      initialDhKeyPair: _ownerIdentity!.signedPrekey,
    );
    await _persistSession();
  }

  /// Encrypts an inner payload (already-JSON string bytes) into a socket
  /// envelope, attaching the x3dh handshake while the session is unconfirmed.
  Future<Map<String, dynamic>> encryptPayload(String innerJson) async {
    final session = _session;
    if (session == null) throw SecurityError('no session established');
    final msg = await session.encrypt(utf8.encode(innerJson), _aad);
    await _persistSession();
    final envelope = <String, dynamic>{'v': 1, 'ratchet': msg.toMap()};
    final pending = _x3dhBlockIfPending();
    if (pending != null) envelope['x3dh'] = pending;
    return envelope;
  }

  /// Decrypts an inbound socket envelope into the inner payload JSON string.
  Future<String> decryptEnvelope(Map<String, dynamic> envelope) async {
    final session = _session;
    if (session == null) {
      final x3dh = envelope['x3dh'];
      if (x3dh == null) throw SecurityError('envelope without session or handshake');
      await ensureOwnerSessionFromInitial((x3dh as Map).cast<String, dynamic>());
    }
    final msg = RatchetMessage.fromMap(
      (envelope['ratchet'] as Map).cast<String, dynamic>(),
    );
    final clear = await _session!.decrypt(msg, _aad);
    _sessionConfirmed = true;
    await _persistSession();
    return utf8.decode(clear);
  }

  bool get hasSession => _session != null;

  Map<String, dynamic>? _x3dhBlockIfPending() {
    if (_sessionConfirmed) return null;
    // Reuse the stored handshake material until the owner confirms receipt.
    final raw = _pendingHandshake;
    return raw;
  }

  Map<String, dynamic>? _pendingHandshake;

  Future<DoubleRatchet?> _loadSession() async {
    if (_session != null) return _session;
    final raw = await _storage.read(key: _sessionKey(pairId));
    if (raw == null) return null;
    final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return DoubleRatchet.fromMap(m);
  }

  Future<void> _persistSession() async {
    if (_session == null) return;
    await _storage.write(
      key: _sessionKey(pairId),
      value: jsonEncode(_session!.toMap()),
    );
  }

  /// Client-side: remembers the handshake block produced at session creation
  /// so it can be replayed on every outbound message until confirmation.
  Future<void> storePendingHandshake(Map<String, dynamic> x3dh) async {
    _pendingHandshake = x3dh;
    await _storage.write(key: 'handshake_$pairId', value: jsonEncode(x3dh));
  }

  Future<void> loadPendingHandshake() async {
    final raw = await _storage.read(key: 'handshake_$pairId');
    if (raw != null) {
      _pendingHandshake = (jsonDecode(raw) as Map).cast<String, dynamic>();
    }
  }

  Future<void> clearPendingHandshake() async {
    _pendingHandshake = null;
    _sessionConfirmed = true;
    await _storage.delete(key: 'handshake_$pairId');
  }
}

class SecurityError implements Exception {
  SecurityError(this.message);
  final String message;
  @override
  String toString() => 'SecurityError: $message';
}
