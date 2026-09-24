import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// X3DH (Extended Triple Diffie-Hellman) key agreement over Curve25519,
/// adapted per the architecture document: the CLIENT initiates, the OWNER
/// publishes a signed prekey bundle.
///
///   DH1 = DH(IK_client, SPK_owner)
///   DH2 = DH(EK_client, IK_owner)
///   DH3 = DH(EK_client, SPK_owner)
///   SK  = HKDF-SHA256(DH1 || DH2 || DH3, salt = 0^32, info = "hotline-x3dh-v1")
///
/// The Owner's signed prekey (SPK) doubles as its initial Double Ratchet key,
/// exactly like Bob's signed prekey in the Signal spec.
class X3dhPrekeyBundle {
  X3dhPrekeyBundle({
    required this.identityPub,
    required this.signedPrekeyPub,
    required this.signingPub,
    required this.prekeySignature,
  });

  factory X3dhPrekeyBundle.fromRedeemResponse(Map<String, dynamic> body) =>
      X3dhPrekeyBundle(
        identityPub: base64Decode(body['ownerIdentityPubKey'] as String),
        signedPrekeyPub: base64Decode(body['ownerSignedPrekey'] as String),
        signingPub: body['ownerSigningPubKey'] != null
            ? base64Decode(body['ownerSigningPubKey'] as String)
            : Uint8List(0),
        prekeySignature: body['prekeySignature'] != null
            ? base64Decode(body['prekeySignature'] as String)
            : Uint8List(0),
      );

  final Uint8List identityPub;
  final Uint8List signedPrekeyPub;
  final Uint8List signingPub; // Ed25519 public key
  final Uint8List prekeySignature; // Ed25519 signature over signedPrekeyPub

  /// Defense in depth: the relay authenticates the owner with a shared
  /// token, and the client ADDITIONALLY verifies the prekey is signed by the
  /// owner's Ed25519 identity key. Returns true when verification is not
  /// applicable (bundle published without a signing key) and false on any
  /// mismatch.
  Future<bool> verifySignature() async {
    if (signingPub.isEmpty || prekeySignature.isEmpty) return true;
    const ed = Ed25519();
    try {
      return await ed.verifyBytes(
        signedPrekeyPub,
        Signature(prekeySignature, publicKey: SimplePublicKey(signingPub, type: KeyPairType.ed25519)),
      );
    } on Exception {
      return false;
    }
  }
}

/// Result of the client-side X3DH initiation.
class X3dhInitiation {
  X3dhInitiation({required this.sharedSecret, required this.ephemeralPub});

  final Uint8List sharedSecret;
  final Uint8List ephemeralPub; // MUST be delivered to the owner (x3dh.ek)
}

class X3dh {
  X3dh._();

  static final X25519 _dh = X25519();
  static final Ed25519 _signing = Ed25519();
  static const String _info = 'hotline-x3dh-v1';

  /// Client side: compute the shared secret from the owner's prekey bundle.
  static Future<X3dhInitiation> initiate({
    required SimpleKeyPair identityKeyPair,
    required X3dhPrekeyBundle bundle,
  }) async {
    final ephemeral = await _dh.newKeyPair();

    final dh1 = await _dh.sharedSecretKey(
      keyPair: identityKeyPair,
      remotePublicKey: SimplePublicKey(bundle.signedPrekeyPub, type: KeyPairType.x25519),
    );
    final dh2 = await _dh.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(bundle.identityPub, type: KeyPairType.x25519),
    );
    final dh3 = await _dh.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(bundle.signedPrekeyPub, type: KeyPairType.x25519),
    );

    final ikm = BytesBuilder()
      ..add(await dh1.extractBytes())
      ..add(await dh2.extractBytes())
      ..add(await dh3.extractBytes());

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final sk = await hkdf.deriveKey(
      secretKey: SecretKey(ikm.toBytes()),
      nonce: Uint8List(32), // salt = zeros
      info: ascii.encode(_info),
    );

    final ephemeralPub = await ephemeral.extractPublicKey();
    return X3dhInitiation(
      sharedSecret: Uint8List.fromList(await sk.extractBytes()),
      ephemeralPub: Uint8List.fromList(ephemeralPub.bytes),
    );
  }

  /// Owner side: reconstruct the SAME shared secret from the client's
  /// (identityPub, ephemeralPub) pair delivered in the initial envelope.
  static Future<Uint8List> respond({
    required SimpleKeyPair identityKeyPair,
    required SimpleKeyPair signedPrekeyPair,
    required Uint8List clientIdentityPub,
    required Uint8List clientEphemeralPub,
  }) async {
    final dh1 = await _dh.sharedSecretKey(
      keyPair: signedPrekeyPair,
      remotePublicKey: SimplePublicKey(clientIdentityPub, type: KeyPairType.x25519),
    );
    final dh2 = await _dh.sharedSecretKey(
      keyPair: identityKeyPair,
      remotePublicKey: SimplePublicKey(clientEphemeralPub, type: KeyPairType.x25519),
    );
    final dh3 = await _dh.sharedSecretKey(
      keyPair: signedPrekeyPair,
      remotePublicKey: SimplePublicKey(clientEphemeralPub, type: KeyPairType.x25519),
    );

    final ikm = BytesBuilder()
      ..add(await dh1.extractBytes())
      ..add(await dh2.extractBytes())
      ..add(await dh3.extractBytes());

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final sk = await hkdf.deriveKey(
      secretKey: SecretKey(ikm.toBytes()),
      nonce: Uint8List(32),
      info: ascii.encode(_info),
    );
    return Uint8List.fromList(await sk.extractBytes());
  }

  /// Full owner identity material for App B registration.
  static Future<OwnerIdentityMaterial> createOwnerIdentity() async {
    final identity = await _dh.newKeyPair();
    final signedPrekey = await _dh.newKeyPair();
    final signing = await _signing.newKeyPair();

    final spkPub = await signedPrekey.extractPublicKey();
    final signature = await _signing.sign(
      Uint8List.fromList(spkPub.bytes),
      keyPair: signing,
    );

    return OwnerIdentityMaterial(
      identity: identity,
      signedPrekey: signedPrekey,
      signing: signing,
      identityPub: Uint8List.fromList((await identity.extractPublicKey()).bytes),
      signedPrekeyPub: Uint8List.fromList(spkPub.bytes),
      signingPub: Uint8List.fromList((await signing.extractPublicKey()).bytes),
      prekeySignature: Uint8List.fromList(signature.bytes),
    );
  }
}

/// Everything App B needs to register its identity and answer X3DH later.
class OwnerIdentityMaterial {
  OwnerIdentityMaterial({
    required this.identity,
    required this.signedPrekey,
    required this.signing,
    required this.identityPub,
    required this.signedPrekeyPub,
    required this.signingPub,
    required this.prekeySignature,
  });

  final SimpleKeyPair identity;
  final SimpleKeyPair signedPrekey; // initial Double Ratchet key pair
  final SimpleKeyPair signing;

  final Uint8List identityPub;
  final Uint8List signedPrekeyPub;
  final Uint8List signingPub;
  final Uint8List prekeySignature;

  Map<String, String> registrationBody(String ownerId) => <String, String>{
        'ownerId': ownerId,
        'identityPubKey': base64Encode(identityPub),
        'signedPrekey': base64Encode(signedPrekeyPub),
        'signingPubKey': base64Encode(signingPub),
        'prekeySignature': base64Encode(prekeySignature),
      };
}
