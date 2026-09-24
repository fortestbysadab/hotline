/**
 * Real-time layer (Socket.io).
 *
 * The server is an untrusted postbox: every payload handled here is opaque,
 * E2EE ciphertext produced by the Double Ratchet on the devices. The server
 * only understands routing metadata (pairId, role, message ids).
 *
 * Event map
 * ---------
 *  client ─ msg {id, kind, envelope}         → peer (or offline queue)
 *         ─ msg:read {ids}                   → peer
 *         ─ typing {typing}                  → peer
 *         ─ location {envelope}              → peer + last-known slot
 *         ─ call:invite {callId, media}      → peer
 *         ─ call:accept | call:reject | call:end        → peer
 *         ─ rtc:offer | rtc:answer | rtc:ice {callId, ...} → peer
 *  server ─ msg, msg:ack, msg:read, typing, location, call:*, rtc:*,
 *         ─ presence {role, online}, pair:revoked, hello {iceServers}
 */
import { sha256 } from '../store/index.js';
import { resolveOwnerToken } from '../config.js';

/** pairId -> { owner: Set<socketId>, client: Set<socketId> } */
const presence = new Map();
/** socketId -> { pairId, role } */
const socketIndex = new Map();

function peerRole(role) {
  return role === 'owner' ? 'client' : 'owner';
}

function onlineSockets(io, pairId, role) {
  return [...(presence.get(pairId)?.[role] ?? [])].map((sid) => io.sockets.sockets.get(sid)).filter(Boolean);
}

function emitPresence(io, pairId, exceptSocket = null) {
  const roles = presence.get(pairId);
  if (!roles) return;
  const state = { owner: roles.owner.size > 0, client: roles.client.size > 0 };
  for (const role of ['owner', 'client']) {
    // Tell each side about its PEER: { role: <peer role>, online: <peer online> }
    const peer = peerRole(role);
    for (const sid of roles[role]) {
      if (sid === exceptSocket) continue;
      io.to(sid).emit('presence', { role: peer, online: state[peer] });
    }
  }
}

export function attachRealtime(io, store, config) {
  io.on('connection', (socket) => {
    const { pairId, role, secret } = socket.handshake.auth ?? {};

    (async () => {
      // ---- Authentication ------------------------------------------------
      if (!pairId || !role || !secret || !['owner', 'client'].includes(role)) {
        socket.emit('auth:error', { error: 'pairId, role and secret are required' });
        socket.disconnect(true);
        return;
      }
      const pair = await store.getPair(pairId);
      const pairSecretOk = pair && pair.pairSecretHash === sha256(secret);
      // Owner-role sockets may alternatively authenticate with the shared
      // OWNER_TOKEN — the owner device never learns per-pair secrets (those
      // are handed only to the redeeming client).
      const ownerTokenOk =
        role === 'owner' && config.ownerToken !== undefined && secret === (config.ownerToken || resolveOwnerToken());
      if (!pair || (!pairSecretOk && !ownerTokenOk)) {
        socket.emit('auth:error', { error: 'invalid pair credentials' });
        socket.disconnect(true);
        return;
      }
      if (pair.status !== 'active') {
        socket.emit('auth:error', { error: 'pair revoked' });
        socket.disconnect(true);
        return;
      }

      socket.join(`pair:${pairId}:${role}`);
      if (!presence.has(pairId)) presence.set(pairId, { owner: new Set(), client: new Set() });
      presence.get(pairId)[role].add(socket.id);
      socketIndex.set(socket.id, { pairId, role });

      // ---- Hello ---------------------------------------------------------
      socket.emit('hello', { pairId, role, iceServers: config.iceServers, serverTime: Date.now() });

      // ---- Drain offline queue -------------------------------------------
      const queued = await store.drainQueue(pairId, role);
      for (const envelope of queued) {
        socket.emit('msg', { ...envelope, queued: true });
      }

      emitPresence(io, pairId);
      console.log(`[rt] ${role} joined pair ${pairId} (${presence.get(pairId)[role].size} online)`);
    })().catch((err) => {
      console.error('[rt] handshake failed:', err);
      socket.emit('auth:error', { error: 'handshake failed' });
      socket.disconnect(true);
    });

    // ---- Generic encrypted message relay ---------------------------------
    socket.on('msg', async ({ id, kind, envelope } = {}, ack) => {
      const ctx = socketIndex.get(socket.id);
      if (!ctx) return ack?.({ error: 'not authenticated' });
      if (!id || typeof envelope === 'undefined') return ack?.({ error: 'id and envelope required' });

      const record = { id, kind: kind ?? 'chat', from: ctx.role, envelope, ts: Date.now() };
      const target = onlineSockets(io, ctx.pairId, peerRole(ctx.role));

      if (target.length > 0) {
        for (const s of target) s.emit('msg', record);
        ack?.({ ok: true, delivered: true, queued: false });
      } else {
        await store.enqueue(ctx.pairId, peerRole(ctx.role), record);
        ack?.({ ok: true, delivered: false, queued: true });
      }
    });

    // ---- Read receipts & typing (ephemeral; dropped when peer offline) ----
    const relayEphemeral = (event, pick) =>
      socket.on(event, async (data, ack) => {
        const ctx = socketIndex.get(socket.id);
        if (!ctx) return ack?.({ error: 'not authenticated' });
        const payload = pick(data ?? {});
        for (const s of onlineSockets(io, ctx.pairId, peerRole(ctx.role))) s.emit(event, payload);
        ack?.({ ok: true, delivered: onlineSockets(io, ctx.pairId, peerRole(ctx.role)).length > 0 });
      });

    relayEphemeral('msg:read', (d) => ({ from: socketIndex.get(socket.id)?.role, ids: d.ids ?? [] }));
    relayEphemeral('typing', (d) => ({ from: socketIndex.get(socket.id)?.role, typing: !!d.typing }));

    // ---- Live location (encrypted envelope) ------------------------------
    socket.on('location', async ({ envelope, timestamp } = {}, ack) => {
      const ctx = socketIndex.get(socket.id);
      if (!ctx) return ack?.({ error: 'not authenticated' });
      if (!envelope) return ack?.({ error: 'envelope required' });

      await store.setLastLocation(ctx.pairId, { envelope, timestamp: timestamp ?? Date.now(), from: ctx.role });
      const targets = onlineSockets(io, ctx.pairId, peerRole(ctx.role));
      for (const s of targets) s.emit('location', { from: ctx.role, envelope, timestamp: timestamp ?? Date.now() });
      ack?.({ ok: true, delivered: targets.length > 0 });
    });

    socket.on('location:last', async (_data, ack) => {
      const ctx = socketIndex.get(socket.id);
      if (!ctx) return ack?.({ error: 'not authenticated' });
      ack?.({ ok: true, last: await store.getLastLocation(ctx.pairId) });
    });

    // ---- WebRTC call signalling ------------------------------------------
    const relayRtc = (event) =>
      socket.on(event, async (data = {}, ack) => {
        const ctx = socketIndex.get(socket.id);
        if (!ctx) return ack?.({ error: 'not authenticated' });
        const payload = { ...data, from: ctx.role };
        const targets = onlineSockets(io, ctx.pairId, peerRole(ctx.role));
        for (const s of targets) s.emit(event, payload);
        ack?.({ ok: true, delivered: targets.length > 0 });
      });

    relayRtc('call:invite');
    relayRtc('call:accept');
    relayRtc('call:reject');
    relayRtc('call:end');
    relayRtc('rtc:offer');
    relayRtc('rtc:answer');
    relayRtc('rtc:ice');

    // ---- Disconnect ------------------------------------------------------
    socket.on('disconnect', () => {
      const ctx = socketIndex.get(socket.id);
      if (!ctx) return;
      const roles = presence.get(ctx.pairId);
      roles?.[ctx.role]?.delete(socket.id);
      socketIndex.delete(socket.id);
      emitPresence(io, ctx.pairId);
      console.log(`[rt] ${ctx.role} left pair ${ctx.pairId}`);
    });
  });

  /** Push an event to every online socket of a pair (used by REST, e.g. revoke). */
  io.emitToPair = (pairId, event, payload) => {
    const roles = presence.get(pairId);
    if (!roles) return;
    for (const sid of [...roles.owner, ...roles.client]) {
      io.sockets.sockets.get(sid)?.emit(event, payload);
    }
    if (event === 'pair:revoked') {
      for (const sid of [...roles.owner, ...roles.client]) {
        io.sockets.sockets.get(sid)?.disconnect(true);
      }
      presence.delete(pairId);
    }
  };

  return io;
}
