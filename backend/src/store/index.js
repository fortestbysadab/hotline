/**
 * Store implementations for the Private Hotline backend.
 *
 * The server is deliberately UNTRUSTED: it only ever sees opaque identifiers
 * and ciphertext. The store interface therefore deals exclusively in public
 * keys, hashed invite codes and encrypted envelopes.
 *
 * Two implementations:
 *   • MemoryStore  — default; zero-dependency, ideal for dev/CI and free-tier
 *                    ephemeral hosting (process restart = stateless re-pair).
 *   • FirestoreStore — durable free-tier persistence per the architecture doc
 *                    (collections: owners / invites / pairs / offline_queue).
 */

import crypto from 'node:crypto';

export class MemoryStore {
  constructor({ offlineQueueMax = 500 } = {}) {
    this.offlineQueueMax = offlineQueueMax;
    this.owners = new Map();       // ownerId -> owner record (public keys + prekeys)
    this.invites = new Map();      // codeHash -> invite record
    this.pairs = new Map();        // pairId  -> pair record
    this.queues = new Map();       // `${pairId}:${role}` -> [envelope]
    this.locations = new Map();    // pairId  -> last encrypted location envelope
  }

  // Owners ------------------------------------------------------------------

  async saveOwner(owner) {
    this.owners.set(owner.ownerId, { ...owner });
    return { ...owner };
  }

  async getOwner(ownerId) {
    const owner = this.owners.get(ownerId);
    return owner ? { ...owner } : null;
  }

  async updateOwner(ownerId, patch) {
    const owner = this.owners.get(ownerId);
    if (!owner) return null;
    Object.assign(owner, patch);
    return { ...owner };
  }

  // Invites -----------------------------------------------------------------

  async createInvite(invite) {
    if (this.invites.has(invite.codeHash)) {
      const err = new Error('invite collision');
      err.code = 'COLLISION';
      throw err;
    }
    this.invites.set(invite.codeHash, { ...invite, isUsed: false });
    return { ...invite, isUsed: false };
  }

  async getInvite(codeHash) {
    const invite = this.invites.get(codeHash);
    return invite ? { ...invite } : null;
  }

  async consumeInvite(codeHash) {
    const invite = this.invites.get(codeHash);
    if (!invite) return null;
    if (invite.isUsed) return { ...invite, alreadyUsed: true };
    invite.isUsed = true;
    invite.usedAt = Date.now();
    return { ...invite };
  }

  // Pairs -------------------------------------------------------------------

  async createPair(pair) {
    this.pairs.set(pair.pairId, { ...pair, status: pair.status || 'active' });
    return { ...pair };
  }

  async getPair(pairId) {
    const pair = this.pairs.get(pairId);
    return pair ? { ...pair } : null;
  }

  async listPairs(ownerId) {
    return [...this.pairs.values()]
      .filter((p) => p.ownerId === ownerId)
      .map((p) => ({ ...p }));
  }

  async setPairStatus(pairId, status) {
    const pair = this.pairs.get(pairId);
    if (!pair) return null;
    pair.status = status;
    return { ...pair };
  }

  // Offline queue -----------------------------------------------------------

  async enqueue(pairId, recipientRole, envelope) {
    const key = `${pairId}:${recipientRole}`;
    const queue = this.queues.get(key) ?? [];
    queue.push(envelope);
    while (queue.length > this.offlineQueueMax) queue.shift(); // drop oldest
    this.queues.set(key, queue);
    return envelope;
  }

  async drainQueue(pairId, recipientRole) {
    const key = `${pairId}:${recipientRole}`;
    const queue = this.queues.get(key) ?? [];
    this.queues.set(key, []);
    return queue;
  }

  // Last-known location (still E2EE — opaque blob here) ----------------------

  async setLastLocation(pairId, envelope) {
    this.locations.set(pairId, { ...envelope });
    return envelope;
  }

  async getLastLocation(pairId) {
    const loc = this.locations.get(pairId);
    return loc ? { ...loc } : null;
  }

  async close() { /* nothing to release */ }
}

/**
 * Firestore-backed store with the exact same async interface.
 * Activated when FIRESTORE_PROJECT_ID is set (needs GOOGLE_APPLICATION_CREDENTIALS
 * or platform-level ambient credentials, e.g. on GCP).
 */
export class FirestoreStore {
  constructor(admin, firestore, { offlineQueueMax = 500 } = {}) {
    this.admin = admin;
    this.db = firestore;
    this.offlineQueueMax = offlineQueueMax;
  }

  static async create(opts) {
    const [{ default: admin }, { getFirestore, initializeApp }] = await Promise.all([
      import('firebase-admin/app'),
      import('firebase-admin/firestore'),
    ]);
    initializeApp();
    const store = new FirestoreStore(admin, getFirestore(), opts);
    console.log('[store] Firestore store initialised');
    return store;
  }

  // Owners ------------------------------------------------------------------

  async saveOwner(owner) {
    await this.db.collection('owners').doc(owner.ownerId).set({ ...owner });
    return { ...owner };
  }

  async getOwner(ownerId) {
    const snap = await this.db.collection('owners').doc(ownerId).get();
    return snap.exists ? snap.data() : null;
  }

  async updateOwner(ownerId, patch) {
    const ref = this.db.collection('owners').doc(ownerId);
    await ref.set(patch, { merge: true });
    const snap = await ref.get();
    return snap.exists ? snap.data() : null;
  }

  // Invites -----------------------------------------------------------------

  async createInvite(invite) {
    await this.db.collection('invites').doc(invite.codeHash).set({ ...invite, isUsed: false });
    return { ...invite, isUsed: false };
  }

  async getInvite(codeHash) {
    const snap = await this.db.collection('invites').doc(codeHash).get();
    return snap.exists ? snap.data() : null;
  }

  async consumeInvite(codeHash) {
    const ref = this.db.collection('invites').doc(codeHash);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const invite = snap.data();
      if (invite.isUsed) return { ...invite, alreadyUsed: true };
      tx.update(ref, { isUsed: true, usedAt: this.admin.firestore.FieldValue.serverTimestamp() });
      return { ...invite, isUsed: true };
    });
  }

  // Pairs -------------------------------------------------------------------

  async createPair(pair) {
    await this.db.collection('pairs').doc(pair.pairId).set({ ...pair, status: pair.status || 'active' });
    return { ...pair };
  }

  async getPair(pairId) {
    const snap = await this.db.collection('pairs').doc(pairId).get();
    return snap.exists ? snap.data() : null;
  }

  async listPairs(ownerId) {
    const snap = await this.db.collection('pairs').where('ownerId', '==', ownerId).get();
    return snap.docs.map((d) => d.data());
  }

  async setPairStatus(pairId, status) {
    const ref = this.db.collection('pairs').doc(pairId);
    await ref.set({ status }, { merge: true });
    const snap = await ref.get();
    return snap.exists ? snap.data() : null;
  }

  // Offline queue -----------------------------------------------------------

  async enqueue(pairId, recipientRole, envelope) {
    await this.db.collection('offline_queue').add({
      pairId,
      recipientRole,
      envelope,
      createdAt: this.admin.firestore.FieldValue.serverTimestamp(),
    });
    return envelope;
  }

  async drainQueue(pairId, recipientRole) {
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(
        this.db.collection('offline_queue')
          .where('pairId', '==', pairId)
          .where('recipientRole', '==', recipientRole)
          .orderBy('createdAt')
          .limit(this.offlineQueueMax),
      );
      const out = [];
      for (const doc of snap.docs) {
        out.push(doc.data().envelope);
        tx.delete(doc.ref);
      }
      return out;
    });
  }

  // Last-known location ------------------------------------------------------

  async setLastLocation(pairId, envelope) {
    await this.db.collection('locations').doc(pairId).set({ ...envelope });
    return envelope;
  }

  async getLastLocation(pairId) {
    const snap = await this.db.collection('locations').doc(pairId).get();
    return snap.exists ? snap.data() : null;
  }

  async close() {
    await this.db.terminate();
  }
}

/** Pick and initialise the configured store. */
export async function createStore(config) {
  if (config.store === 'firestore') {
    try {
      return await FirestoreStore.create({ offlineQueueMax: config.offlineQueueMax });
    } catch (err) {
      console.error('[store] Firestore init failed, falling back to memory:', err.message);
    }
  }
  console.log('[store] Using in-memory store (dev mode — state is ephemeral)');
  return new MemoryStore({ offlineQueueMax: config.offlineQueueMax });
}

export const sha256 = (input) =>
  crypto.createHash('sha256').update(input).digest('hex');
