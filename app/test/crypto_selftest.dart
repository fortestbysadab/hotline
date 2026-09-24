import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline_app/core/crypto/double_ratchet.dart';
import 'package:hotline_app/core/crypto/x3dh.dart';

/// Self-test for the Dart E2EE core, mirroring backend/test/protocol_twin.js.
/// Run with: flutter test test/crypto_selftest.dart
void main() {
  test('X3DH: initiator and responder derive the same shared secret', () async {
    final owner = await X3dh.createOwnerIdentity();

    // Client side: build a fake identity key and run initiation against the
    // owner's published bundle.
    final clientIdentity = await X25519().newKeyPair();
    final clientIdentityPub = await clientIdentity.extractPublicKey();

    final bundle = X3dhPrekeyBundle(
      identityPub: owner.identityPub,
      signedPrekeyPub: owner.signedPrekeyPub,
      signingPub: owner.signingPub,
      prekeySignature: owner.prekeySignature,
    );
    expect(await bundle.verifySignature(), isTrue);

    final init = await X3dh.initiate(identityKeyPair: clientIdentity, bundle: bundle);

    final skOwner = await X3dh.respond(
      identityKeyPair: owner.identity,
      signedPrekeyPair: owner.signedPrekey,
      clientIdentityPub: Uint8List.fromList(clientIdentityPub.bytes),
      clientEphemeralPub: init.ephemeralPub,
    );
    expect(skOwner, equals(init.sharedSecret));
  });

  test('Double Ratchet: round-trip, ratchet step, out-of-order, restore', () async {
    final owner = await X3dh.createOwnerIdentity();
    final clientIdentity = await X25519().newKeyPair();

    final bundle = X3dhPrekeyBundle(
      identityPub: owner.identityPub,
      signedPrekeyPub: owner.signedPrekeyPub,
      signingPub: owner.signingPub,
      prekeySignature: owner.prekeySignature,
    );
    final init = await X3dh.initiate(identityKeyPair: clientIdentity, bundle: bundle);

    final alice = await DoubleRatchet.initiate(
      rootKey: init.sharedSecret,
      remoteInitialDhPub: owner.signedPrekeyPub,
    );
    final bob = await DoubleRatchet.respond(
      rootKey: init.sharedSecret,
      initialDhKeyPair: owner.signedPrekey,
    );

    final aad = utf8.encode('pair-binding');

    // Client → Owner, two in-order messages.
    final m1 = await alice.encrypt(utf8.encode('hello'), aad);
    final m2 = await alice.encrypt(utf8.encode('world'), aad);
    expect(utf8.decode(await bob.decrypt(m1, aad)), 'hello');
    expect(utf8.decode(await bob.decrypt(m2, aad)), 'world');

    // Owner replies → DH ratchet steps on both sides.
    final r1 = await bob.encrypt(utf8.encode('reply'), aad);
    expect(utf8.decode(await alice.decrypt(r1, aad)), 'reply');

    // Out-of-order: alice sends 3, bob receives #3 first.
    final o1 = await alice.encrypt(utf8.encode('seq-1'), aad);
    final o2 = await alice.encrypt(utf8.encode('seq-2'), aad);
    final o3 = await alice.encrypt(utf8.encode('seq-3'), aad);
    expect(utf8.decode(await bob.decrypt(o3, aad)), 'seq-3');
    expect(utf8.decode(await bob.decrypt(o1, aad)), 'seq-1');
    expect(utf8.decode(await bob.decrypt(o2, aad)), 'seq-2');

    // Tampered AAD must throw.
    final guard = await alice.encrypt(utf8.encode('x'), aad);
    expect(() => bob.decrypt(guard, utf8.encode('other')), throwsA(anything));

    // Persist/restore bob, then keep receiving.
    final saved = bob.toMap();
    final restored = await DoubleRatchet.fromMap(saved);
    final post = await alice.encrypt(utf8.encode('after-restore'), aad);
    expect(utf8.decode(await restored.decrypt(post, aad)), 'after-restore');
  });
}
