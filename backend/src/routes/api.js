/**
 * REST: owner identity registration + invite lifecycle.
 *
 * Security model (alpha):
 *  • The Owner app authenticates management calls with the shared OWNER_TOKEN.
 *  • Invite codes are high-entropy random values; only their SHA-256 hash is
 *    persisted, so a database leak never reveals usable codes.
 *  • Redeeming exchanges the client's public identity key for the Owner's
 *    prekey bundle — the raw material for X3DH on the client.
 */
import { Router } from 'express';
import crypto from 'node:crypto';
import { config, resolveOwnerToken } from '../config.js';
import { sha256 } from '../store/index.js';

export function apiRouter(store, cfg) {
  const router = Router();

  const requireOwner = (req, res, next) => {
    const auth = req.header('authorization') || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : req.query.token;
    const expected = cfg?.ownerToken || resolveOwnerToken();
    if (!token || token !== expected) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    next();
  };

  // Health -------------------------------------------------------------------

  router.get('/health', async (_req, res) => {
    res.json({ ok: true, store: config.store, time: new Date().toISOString() });
  });

  // Owner identity -----------------------------------------------------------

  /**
   * POST /api/owner/register
   * { ownerId, identityPubKey, signedPrekey, prekeySignature }
   * Idempotent: re-registers/refreshes the prekey bundle.
   */
  router.post('/owner/register', requireOwner, async (req, res) => {
    const { ownerId, identityPubKey, signedPrekey, prekeySignature, signingPubKey } = req.body ?? {};
    if (!ownerId || !identityPubKey || !signedPrekey || !signingPubKey) {
      return res.status(400).json({ error: 'ownerId, identityPubKey, signedPrekey and signingPubKey are required' });
    }
    const existing = await store.getOwner(ownerId);
    const owner = await (existing
      ? store.updateOwner(ownerId, {
          identityPubKey,
          signedPrekey,
          prekeySignature: prekeySignature ?? null,
          signingPubKey,
        })
      : store.saveOwner({
          ownerId,
          identityPubKey,
          signedPrekey,
          prekeySignature: prekeySignature ?? null,
          signingPubKey,
          createdAt: Date.now(),
        }));
    res.json({ ok: true, owner });
  });

  // Invites ------------------------------------------------------------------

  /**
   * POST /api/invites  (owner)
   * { ownerId }
   * → { code, expiresAt }  The plaintext code is returned exactly once.
   *
   * Codes are self-contained: "<ownerId>~<random>", so a guest only ever
   * handles a single string. Only the SHA-256 of the full code is stored.
   */
  router.post('/invites', requireOwner, async (req, res) => {
    const { ownerId } = req.body ?? {};
    if (!ownerId) return res.status(400).json({ error: 'ownerId required' });
    const owner = await store.getOwner(ownerId);
    if (!owner) return res.status(404).json({ error: 'owner not found — register the owner identity first' });

    const random = crypto.randomBytes(config.inviteCodeBytes).toString('base64url');
    const code = `${ownerId}~${random}`;
    const expiresAt = Date.now() + config.inviteTtlHours * 3600 * 1000;
    const invite = {
      codeHash: sha256(code),
      ownerId,
      createdAt: Date.now(),
      expiresAt,
    };
    await store.createInvite(invite);
    res.status(201).json({ code, expiresAt, ttlHours: config.inviteTtlHours });
  });

  /**
   * GET /api/invites/:codeHash/status (owner) — quick check without redeeming.
   */
  router.get('/invites/:codeHash/status', requireOwner, async (req, res) => {
    const invite = await store.getInvite(req.params.codeHash);
    if (!invite) return res.status(404).json({ error: 'not found' });
    const { codeHash, isUsed, createdAt, expiresAt } = invite;
    res.json({ codeHash, isUsed, createdAt, expiresAt, expired: expiresAt < Date.now() });
  });

  /**
   * POST /api/invites/redeem  (client — no auth beyond the code itself)
   * { code, clientPubKey, clientSigningPub?, clientDisplayName? }
   * → { pairId, pairSecret, ownerId, ownerIdentityPubKey, ownerSignedPrekey,
   *     ownerSigningPubKey }
   *
   * Creates the pair atomically with consuming the invite.
   */
  router.post('/invites/redeem', async (req, res) => {
    const { code, clientPubKey, clientSigningPub, clientDisplayName } = req.body ?? {};
    if (!code || !clientPubKey) {
      return res.status(400).json({ error: 'code and clientPubKey are required' });
    }
    const sep = code.indexOf('~');
    if (sep <= 0) return res.status(400).json({ error: 'malformed code' });
    const ownerId = code.slice(0, sep);
    const owner = await store.getOwner(ownerId);
    if (!owner) return res.status(404).json({ error: 'owner not found' });

    const invite = await store.consumeInvite(sha256(code));
    if (!invite) return res.status(404).json({ error: 'invalid code' });
    if (invite.alreadyUsed) return res.status(409).json({ error: 'code already used' });
    if (invite.expiresAt < Date.now()) return res.status(410).json({ error: 'code expired' });

    const pairId = crypto.randomUUID();
    const pairSecret = crypto.randomBytes(32).toString('base64url');
    const pair = await store.createPair({
      pairId,
      ownerId,
      clientPubKey,
      clientSigningPub: clientSigningPub ?? null,
      clientDisplayName: clientDisplayName ?? null,
      pairSecretHash: sha256(pairSecret),
      status: 'active',
      createdAt: Date.now(),
    });

    res.status(201).json({
      pairId,
      pairSecret,
      ownerId,
      ownerIdentityPubKey: owner.identityPubKey,
      ownerSignedPrekey: owner.signedPrekey,
      ownerSigningPubKey: owner.signingPubKey ?? null,
      prekeySignature: owner.prekeySignature ?? null,
      createdAt: pair.createdAt,
    });
  });

  // Pair management (owner) ----------------------------------------------------

  router.get('/pairs', requireOwner, async (req, res) => {
    const ownerId = req.query.ownerId;
    if (!ownerId) return res.status(400).json({ error: 'ownerId required' });
    res.json({ pairs: await store.listPairs(ownerId) });
  });

  router.post('/pairs/:pairId/revoke', requireOwner, async (req, res) => {
    const pair = await store.setPairStatus(req.params.pairId, 'revoked');
    if (!pair) return res.status(404).json({ error: 'pair not found' });
    req.app.get('emitToPair')?.(req.params.pairId, 'pair:revoked', { pairId: req.params.pairId });
    res.json({ ok: true, pair });
  });

  return router;
}
