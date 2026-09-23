import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The Double Ratchet (Signal spec) — a faithful Dart port of the algorithm
/// validated by `backend/test/protocol_twin.js`:
///
///   • DH ratchet ..... X25519, fresh key pair per ratchet step
///   • Root chain ..... HKDF-SHA256(dhOut, salt = RK, info = "hotline-rk") → RK‖CK
///   • Message chain .. CK' = HMAC-SHA256(CK, 0x02); MK = HMAC-SHA256(CK, 0x01)
///   • AEAD ........... AES-256-GCM, AAD = header ‖ caller AAD (pair binding)
///   • Out-of-order ... bounded skipped-message-key cache keyed "dh:n"
///
/// Header travels in the clear: {dh, pn, n} — exactly enough to route the
/// ciphertext into the right chain state.
class RatchetMessage {
  RatchetMessage({
    required this.dh,
    required this.pn,
    required this.n,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  factory RatchetMessage.fromMap(Map<String, dynamic> m) => RatchetMessage(
        dh: m['dh'] as String,
        pn: ((m['pn'] as num?) ?? 0).toInt(),
        n: ((m['n'] as num?) ?? 0).toInt(),
        nonce: base64Decode(m['nonce'] as String),
        cipherText: base64Decode(m['ct'] as String),
        mac: base64Decode(m['mac'] as String),
      );

  final String dh; // b64 of sender's current ratchet public key
  final int pn; // length of sender's previous sending chain
  final int n; // index in the current sending chain
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'dh': dh,
        'pn': pn,
        'n': n,
        'nonce': base64Encode(nonce),
        'ct': base64Encode(cipherText),
        'mac': base64Encode(mac),
      };

  Uint8List headerBytes() {
    final dhBytes = base64Decode(dh);
    final out = Uint8List(dhBytes.length + 2);
    out.setRange(0, dhBytes.length, dhBytes);
    out[dhBytes.length] = pn & 0xff;
    out[dhBytes.length + 1] = n & 0xff;
    return out;
  }
}

class _ChainStep {
  _ChainStep({required this.messageKey, required this.next});
  final Uint8List messageKey;
  final Uint8List next;
}

class _RootStep {
  _RootStep({required this.rk, required this.ck});
  final Uint8List rk;
  final Uint8List ck;
}

class DoubleRatchet {
  DoubleRatchet._({
    required Uint8List rootKey,
    required SimpleKeyPair dhKeyPair,
    Uint8List? remoteDhPub,
  })  : _rk = rootKey,
        _dhs = dhKeyPair,
        _dhsSeed = null,
        _dhr = remoteDhPub;

  /// Initiator (client): fresh ratchet key pair; the owner's signed prekey is
  /// the initial remote key. Derives the first sending chain. (RatchetInitAlice)
  static Future<DoubleRatchet> initiate({
    required Uint8List rootKey,
    required Uint8List remoteInitialDhPub,
  }) async {
    final dhKeyPair = await X25519().newKeyPair();
    final ratchet = DoubleRatchet._(
      rootKey: rootKey,
      dhKeyPair: dhKeyPair,
      remoteDhPub: remoteInitialDhPub,
    );
    await ratchet._captureDhs();
    final out = await ratchet._kdfRatchetKey(
      await X25519().sharedSecretKey(
        keyPair: dhKeyPair,
        remotePublicKey: SimplePublicKey(remoteInitialDhPub, type: KeyPairType.x25519),
      ),
    );
    ratchet._rk = out.rk;
    ratchet._cks = out.ck;
    return ratchet;
  }

  /// Responder (owner): starts with its signed prekey pair as the local
  /// ratchet key; the receiving chain is derived lazily on first message.
  /// (RatchetInitBob)
  static Future<DoubleRatchet> respond({
    required Uint8List rootKey,
    required SimpleKeyPair initialDhKeyPair,
  }) async {
    final ratchet = DoubleRatchet._(rootKey: rootKey, dhKeyPair: initialDhKeyPair);
    await ratchet._captureDhs();
    return ratchet;
  }

  static const int _maxSkip = 256;
  static final X25519 _dh = X25519();
  static final Hmac _hmac = Hmac.sha256();

  Uint8List _rk;
  Uint8List? _cks; // sending chain key
  Uint8List? _ckr; // receiving chain key
  SimpleKeyPair _dhs; // current local ratchet key pair
  String? _dhsSeed; // raw private key (kept so state can be persisted)
  Uint8List? _dhr; // remote ratchet public key
  int _ns = 0;
  int _nr = 0;
  int _pn = 0;
  final Map<String, Uint8List> _skipped = {};

  /// The cryptography package cannot always read private key bytes back out
  /// of a generated pair, so the raw seed is captured whenever a new local
  /// ratchet key pair is adopted.
  Future<void> _captureDhs() async {
    _dhsSeed = base64Encode(await _dhs.extractPrivateKeyBytes());
  }

  // ----------------------------------------------------------------- send --

  Future<RatchetMessage> encrypt(Uint8List plaintext, List<int> aad) async {
    final cks = _cks;
    if (cks == null) {
      throw StateError('no sending chain — session not established');
    }
    final step = _kdfChainKey(cks);
    _cks = step.next;

    final dhPub = base64Encode((await _dhs.extractPublicKey()).bytes);
    final msg = RatchetMessage(dh: dhPub, pn: _pn, n: _ns, nonce: _randomNonce(), cipherText: Uint8List(0), mac: Uint8List(0));
    _ns += 1;

    final gcm = AesGcm.with256bits();
    final box = await gcm.encrypt(
      plaintext,
      secretKey: SecretKey(step.messageKey),
      nonce: msg.nonce,
      aad: [...msg.headerBytes(), ...aad],
    );
    return RatchetMessage(
      dh: dhPub,
      pn: msg.pn,
      n: msg.n,
      nonce: box.nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  // ------------------------------------------------------------- receive --

  Future<Uint8List> decrypt(RatchetMessage m, List<int> aad) async {
    // 1. Late (out-of-order) message under a known chain?
    final skippedMk = _skipped.remove('${m.dh}:${m.n}');
    if (skippedMk != null) {
      return _aeadOpen(skippedMk, m, aad);
    }

    // 2. Message under a NEW remote ratchet key → step the DH ratchet.
    if (_dhr == null || base64Encode(_dhr!) != m.dh) {
      await _skipTo(m.dh, m.pn);
      await _dhRatchetStep(base64Decode(m.dh));
    } else if (_ckr == null) {
      throw StateError('no receiving chain');
    }

    // 3. Skip forward to the message index, then open under that key.
    await _skipTo(m.dh, m.n);
    final step = _kdfChainKey(_ckr!);
    _ckr = step.next;
    _nr += 1;
    return _aeadOpen(step.messageKey, m, aad);
  }

  // ------------------------------------------------------------ internals --

  Future<void> _dhRatchetStep(Uint8List remoteDhPub) async {
    // Canonical order: DHr = new remote key;
    // RK, CKr = KDF(RK, DH(DHs_old, DHr));  ← matches the peer's sending chain
    // DHs = fresh; RK, CKs = KDF(RK, DH(DHs_new, DHr)).
    _pn = _ns;
    _ns = 0;
    _nr = 0;
    _dhr = remoteDhPub;

    final received = await _kdfRatchetKey(
      await _dh.sharedSecretKey(
        keyPair: _dhs,
        remotePublicKey: SimplePublicKey(remoteDhPub, type: KeyPairType.x25519),
      ),
    );
    _rk = received.rk;
    _ckr = received.ck;

    _dhs = await _dh.newKeyPair();
    await _captureDhs();
    final sending = await _kdfRatchetKey(
      await _dh.sharedSecretKey(
        keyPair: _dhs,
        remotePublicKey: SimplePublicKey(remoteDhPub, type: KeyPairType.x25519),
      ),
    );
    _rk = sending.rk;
    _cks = sending.ck;
  }

  Future<void> _skipTo(String remoteDhB64, int until) async {
    if (until - _nr > _maxSkip) {
      throw StateError('too many skipped messages');
    }
    final ckr = _ckr;
    if (ckr == null) {
      if (until <= _nr) return;
      throw StateError('no receiving chain to skip in');
    }
    while (_nr < until) {
      final step = _kdfChainKey(ckr);
      _ckr = step.next;
      _skipped['$remoteDhB64:$_nr'] = step.messageKey;
      _nr += 1;
    }
  }

  _ChainStep _kdfChainKey(Uint8List ck) {
    return _ChainStep(
      messageKey: Uint8List.fromList(
        _hmac.calculateMacSync(const [0x01], secretKey: SecretKeyData(ck)).bytes,
      ),
      next: Uint8List.fromList(
        _hmac.calculateMacSync(const [0x02], secretKey: SecretKeyData(ck)).bytes,
      ),
    );
  }

  Future<_RootStep> _kdfRatchetKey(SecretKey dhOut) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
    final okm = await hkdf.deriveKey(
      secretKey: dhOut,
      nonce: _rk, // salt = current root key
      info: ascii.encode('hotline-rk'),
    );
    final bytes = await okm.extractBytes();
    return _RootStep(
      rk: Uint8List.fromList(bytes.sublist(0, 32)),
      ck: Uint8List.fromList(bytes.sublist(32, 64)),
    );
  }

  Future<Uint8List> _aeadOpen(Uint8List mk, RatchetMessage m, List<int> aad) async {
    final gcm = AesGcm.with256bits();
    final clear = await gcm.decrypt(
      SecretBox(m.cipherText, nonce: m.nonce, mac: Mac(m.mac)),
      secretKey: SecretKey(mk),
      aad: [...m.headerBytes(), ...aad],
    );
    return Uint8List.fromList(clear);
  }

  // ----------------------------------------------------------- persistence --

  Map<String, dynamic> toMap() => <String, dynamic>{
        'rk': base64Encode(_rk),
        'cks': _cks == null ? null : base64Encode(_cks!),
        'ckr': _ckr == null ? null : base64Encode(_ckr!),
        'dhs': _dhsSeed,
        'dhr': _dhr == null ? null : base64Encode(_dhr!),
        'ns': _ns,
        'nr': _nr,
        'pn': _pn,
        'skipped': _skipped.map<String, String>((k, v) => MapEntry(k, base64Encode(v))),
      };

  static Future<DoubleRatchet> fromMap(Map<String, dynamic> m) async {
    final dhsSeedB64 = m['dhs'] as String?;
    if (dhsSeedB64 == null || dhsSeedB64.isEmpty) {
      throw StateError('ratchet state missing local key pair');
    }
    final dhs = await _dh.newKeyPairFromSeed(base64Decode(dhsSeedB64));
    final ratchet = DoubleRatchet._(
      rootKey: base64Decode(m['rk'] as String),
      dhKeyPair: dhs,
      remoteDhPub: m['dhr'] == null ? null : base64Decode(m['dhr'] as String),
    );
    ratchet._dhsSeed = dhsSeedB64;
    ratchet._cks = m['cks'] == null ? null : base64Decode(m['cks'] as String);
    ratchet._ckr = m['ckr'] == null ? null : base64Decode(m['ckr'] as String);
    ratchet._ns = ((m['ns'] as num?) ?? 0).toInt();
    ratchet._nr = ((m['nr'] as num?) ?? 0).toInt();
    ratchet._pn = ((m['pn'] as num?) ?? 0).toInt();
    final skipped = (m['skipped'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final e in skipped.entries) {
      ratchet._skipped[e.key] = base64Decode(e.value as String);
    }
    return ratchet;
  }
}

Uint8List _randomNonce() {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(12, (_) => r.nextInt(256)));
}
