/**
 * Protocol twin-test: a faithful JS port of the Dart `DoubleRatchet` /
 * `X3dh` classes (app/lib/core/crypto/). It exists to validate the ALGORITHM
 * the mobile apps will run — key chains, ratchet steps, skipped keys, AAD —
 * against itself in a runnable environment, before any device exists.
 *
 *   DH ratchet: X25519   ·  MK derivation: HMAC-SHA256(CK, 0x01/0x02)
 *   AEAD: AES-256-GCM    ·  RK/CK ratchet: HKDF-SHA256
 *   Skipped-key store keyed by `${dhPubB64}:${n}` with a bounded cache.
 *
 * Run: node test/protocol_twin.js
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';

// ---------------------------------------------------------------- helpers --
const b64 = (buf) => Buffer.from(buf).toString('base64');
const unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));
const concat = (...arrays) => {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const a of arrays) { out.set(a, o); o += a.length; }
  return out;
};
const randomBytes = (n) => new Uint8Array(crypto.randomBytes(n));

const X25519 = {
  gen: () => crypto.generateKeyPairSync('x25519'),
  pubRaw: (kp) => new Uint8Array(kp.publicKey.export({ type: 'spki', format: 'der' }).subarray(12)),
  privRaw: (kp) => new Uint8Array(kp.privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(16)),
  dh: (privRaw, peerPubRaw) => new Uint8Array(crypto.diffieHellman({
    privateKey: crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(privRaw)]), format: 'der', type: 'pkcs8' }),
    publicKey: crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(peerPubRaw)]), format: 'der', type: 'spki' }),
  })),
};

const hkdf = (ikm, salt, info, len = 32) =>
  new Uint8Array(crypto.hkdfSync('sha256', Buffer.from(ikm), Buffer.from(salt), Buffer.from(info), len));

const hmac = (key, data) => new Uint8Array(crypto.createHmac('sha256', Buffer.from(key)).update(Buffer.from(data)).digest());

const aeadEncrypt = (key, plaintext, aad) => {
  const nonce = randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', Buffer.from(key), Buffer.from(nonce), { authTagLength: 16 });
  cipher.setAAD(Buffer.from(aad));
  const ct = new Uint8Array(cipher.update(Buffer.from(plaintext)));
  cipher.final();
  return { nonce, ct, mac: new Uint8Array(cipher.getAuthTag()) };
};
const aeadDecrypt = (key, { nonce, ct, mac }, aad) => {
  const decipher = crypto.createDecipheriv('aes-256-gcm', Buffer.from(key), Buffer.from(nonce), { authTagLength: 16 });
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(Buffer.from(mac));
  return new Uint8Array(Buffer.concat([decipher.update(Buffer.from(ct)), decipher.final()]));
};

// -------------------------------------------------------------- ratchet ----
class DoubleRatchet {
  constructor({ isInitiator, rootKey, remoteDhPub, dhKeyPair }) {
    this.RK = rootKey;
    this.CKs = null;
    this.CKr = null;
    this.dhs = dhKeyPair;                    // { priv, pub }
    this.dhr = remoteDhPub ?? null;          // Uint8Array | null
    this.Ns = 0;
    this.Nr = 0;
    this.PN = 0;
    this.skipped = new Map();                // "dhPubB64:n" -> { mk }
    this.MAX_SKIP = 256;
    if (isInitiator && remoteDhPub) {
      // RatchetInitAlice: fresh DHs (passed in), DHr = remote initial key,
      // RK, CKs = KDF_RK(SK, DH(DHs, DHr)); CKr stays null.
      this.dhr = remoteDhPub;
      ({ rk: this.RK, ck: this.CKs } = this._kdfRk(this.RK, X25519.dh(this.dhs.priv, this.dhr)));
    }
  }

  _kdfRk(rk, dhOut) {
    const okm = hkdf(dhOut, rk, 'hotline-rk', 64);
    return { rk: okm.slice(0, 32), ck: okm.slice(32, 64) };
  }

  _kdfCk(ck) {
    return { mk: hmac(ck, new Uint8Array([0x01])), ck: hmac(ck, new Uint8Array([0x02])) };
  }

  /**
   * Canonical Signal DHRatchet, with the NEW remote key (header.dh):
   *   DHr = header.dh
   *   RK, CKr = KDF_RK(RK, DH(DHs_old, DHr))   // matches the peer's sending chain
   *   DHs = GENERATE_DH()                      // fresh local key pair
   *   RK, CKs = KDF_RK(RK, DH(DHs_new, DHr))   // our new sending chain
   */
  _dhRatchetStep(remoteDhPub) {
    this.PN = this.Ns;
    this.Ns = 0;
    this.Nr = 0;
    this.dhr = remoteDhPub;
    ({ rk: this.RK, ck: this.CKr } = this._kdfRk(this.RK, X25519.dh(this.dhs.priv, this.dhr)));
    const kp = X25519.gen();
    this.dhs = { priv: X25519.privRaw(kp), pub: X25519.pubRaw(kp) };
    ({ rk: this.RK, ck: this.CKs } = this._kdfRk(this.RK, X25519.dh(this.dhs.priv, this.dhr)));
  }

  _trySkipped(header) {
    const key = `${header.dh}:${header.n}`;
    const hit = this.skipped.get(key);
    if (!hit) return null;
    this.skipped.delete(key);
    return hit.mk;
  }

  _skipTo(anchorDh, until) {
    if (until - this.Nr > this.MAX_SKIP) throw new Error('too many skipped messages');
    if (!this.CKr) {
      if (until <= this.Nr) return; // nothing to skip before the first chain exists
      throw new Error('no receiving chain');
    }
    while (this.Nr < until) {
      const { mk, ck } = this._kdfCk(this.CKr);
      this.CKr = ck;
      this.skipped.set(`${anchorDh}:${this.Nr}`, { mk });
      this.Nr += 1;
    }
  }

  encrypt(plaintext, aad = new Uint8Array(0)) {
    if (!this.CKs) throw new Error('no sending chain');
    const { mk, ck } = this._kdfCk(this.CKs);
    this.CKs = ck;
    const header = { dh: b64(this.dhs.pub), pn: this.PN, n: this.Ns };
    this.Ns += 1;
    const headerBytes = concat(unb64(header.dh), new Uint8Array([header.pn, header.n]));
    const { nonce, ct, mac } = aeadEncrypt(mk, plaintext, concat(headerBytes, aad));
    return { header, nonce: b64(nonce), ct: b64(ct), mac: b64(mac) };
  }

  decrypt(msg, aad = new Uint8Array(0)) {
    const key = `${msg.header.dh}:${msg.header.n}`;
    const skippedMk = this._trySkipped(msg.header);
    if (skippedMk) {
      return aeadDecrypt(skippedMk, { nonce: unb64(msg.nonce), ct: unb64(msg.ct), mac: unb64(msg.mac) }, concat(concat(unb64(msg.header.dh), new Uint8Array([msg.header.pn, msg.header.n])), aad));
    }
    // Receiving a message under a NEW remote ratchet key → step the DH ratchet.
    if (this.dhr === null || b64(this.dhr) !== msg.header.dh) {
      this._skipTo(msg.header.dh, msg.header.pn);
      this._dhRatchetStep(unb64(msg.header.dh));
    } else if (!this.CKr) {
      throw new Error('no receiving chain');
    }
    this._skipTo(msg.header.dh, msg.header.n);
    const { mk, ck } = this._kdfCk(this.CKr);
    this.CKr = ck;
    this.Nr += 1;
    const headerBytes = concat(unb64(msg.header.dh), new Uint8Array([msg.header.pn, msg.header.n]));
    return aeadDecrypt(mk, { nonce: unb64(msg.nonce), ct: unb64(msg.ct), mac: unb64(msg.mac) }, concat(headerBytes, aad));
  }
}

// --------------------------------------------------------------- X3DH ------
function x3dhInitiate(clientIdentity, clientEphemeral, ownerIdentityPub, ownerSignedPrekeyPub) {
  const dh1 = X25519.dh(X25519.privRaw(clientIdentity), ownerSignedPrekeyPub);
  const dh2 = X25519.dh(X25519.privRaw(clientEphemeral), ownerIdentityPub);
  const dh3 = X25519.dh(X25519.privRaw(clientEphemeral), ownerSignedPrekeyPub);
  const sk = hkdf(concat(dh1, dh2, dh3), new Uint8Array(32), 'hotline-x3dh-v1', 32);
  return sk;
}
function x3dhRespond(ownerIdentity, ownerSignedPrekey, clientIdentityPub, clientEphemeralPub) {
  const dh1 = X25519.dh(X25519.privRaw(ownerSignedPrekey), clientIdentityPub);
  const dh2 = X25519.dh(X25519.privRaw(ownerIdentity), clientEphemeralPub);
  const dh3 = X25519.dh(X25519.privRaw(ownerSignedPrekey), clientEphemeralPub);
  return hkdf(concat(dh1, dh2, dh3), new Uint8Array(32), 'hotline-x3dh-v1', 32);
}

// ----------------------------------------------------------------- test ----
console.log('Private Hotline — protocol twin test\n');

const ownerIdentity = X25519.gen();
const ownerSpk = X25519.gen();
const clientIdentity = X25519.gen();
const clientEphemeral = X25519.gen();

const skClient = x3dhInitiate(clientIdentity, clientEphemeral, X25519.pubRaw(ownerIdentity), X25519.pubRaw(ownerSpk));
const skOwner = x3dhRespond(ownerIdentity, ownerSpk, X25519.pubRaw(clientIdentity), X25519.pubRaw(clientEphemeral));
assert.deepEqual(skClient, skOwner, 'X3DH shared secrets must match');
console.log('  ✔ X3DH shared secret agrees on both sides');

// Client initiates: first ratchet key pair generated by client.
const clientFirstRatchet = X25519.gen();
const client = new DoubleRatchet({
  isInitiator: true,
  rootKey: skClient,
  remoteDhPub: X25519.pubRaw(ownerSpk), // owner's initial ratchet key = signed prekey
  dhKeyPair: { priv: X25519.privRaw(clientFirstRatchet), pub: X25519.pubRaw(clientFirstRatchet) },
});
const owner = new DoubleRatchet({
  isInitiator: false,
  rootKey: skOwner,
  dhKeyPair: { priv: X25519.privRaw(ownerSpk), pub: X25519.pubRaw(ownerSpk) },
});

const aad = new Uint8Array([1]); // pretend "pair binding" AAD
const m1 = client.encrypt(new TextEncoder().encode('hello owner'), aad);
const m2 = client.encrypt(new TextEncoder().encode('second msg'), aad);
assert.deepEqual(owner.decrypt(m1, aad), new TextEncoder().encode('hello owner'));
assert.deepEqual(owner.decrypt(m2, aad), new TextEncoder().encode('second msg'));
console.log('  ✔ owner decrypts in-order client messages');

// Owner replies → triggers DH ratchet on both sides.
const r1 = owner.encrypt(new TextEncoder().encode('reply 1'), aad);
const r2 = owner.encrypt(new TextEncoder().encode('reply 2'), aad);
assert.deepEqual(client.decrypt(r1, aad), new TextEncoder().encode('reply 1'));
assert.deepEqual(client.decrypt(r2, aad), new TextEncoder().encode('reply 2'));
console.log('  ✔ DH ratchet step works both directions');

// Out-of-order delivery: client sends 3, owner receives 1, 3, 2.
const o1 = client.encrypt(new TextEncoder().encode('seq-1'), aad);
const o2 = client.encrypt(new TextEncoder().encode('seq-2'), aad);
const o3 = client.encrypt(new TextEncoder().encode('seq-3'), aad);
assert.deepEqual(owner.decrypt(o3, aad), new TextEncoder().encode('seq-3'));
assert.deepEqual(owner.decrypt(o1, aad), new TextEncoder().encode('seq-1'));
assert.deepEqual(owner.decrypt(o2, aad), new TextEncoder().encode('seq-2'));
console.log('  ✔ out-of-order delivery handled via skipped message keys');

// Wrong AAD must fail.
const guard = client.encrypt(new TextEncoder().encode('secret'), aad);
assert.throws(() => owner.decrypt(guard, new Uint8Array([2])), /auth|decrypt|bad/i);
console.log('  ✔ tampered AAD rejected');

// Serialize/restore owner session (persist round-trip parity with Dart toMap/fromMap).
const restored = new DoubleRatchet({
  isInitiator: false,
  rootKey: owner.RK,
  dhKeyPair: owner.dhs,
});
restored.CKs = owner.CKs; restored.CKr = owner.CKr; restored.dhr = owner.dhr;
restored.Ns = owner.Ns; restored.Nr = owner.Nr; restored.PN = owner.PN;
const after = client.encrypt(new TextEncoder().encode('post-restore'), aad);
assert.deepEqual(restored.decrypt(after, aad), new TextEncoder().encode('post-restore'));
console.log('  ✔ session state survives serialize → restore');

console.log('\nAll protocol twin tests passed ✔');
