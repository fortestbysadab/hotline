/**
 * End-to-end smoke test for the Private Hotline relay.
 * Boots a server on an ephemeral port and exercises the full flow:
 *
 *   health → owner register → invite create → invite redeem → sockets
 *   (auth, presence, message relay, offline queue, read receipts,
 *    location relay, WebRTC signaling, revoke)
 *
 * Zero test-framework dependencies; exits non-zero on any failure.
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { io as Client } from 'socket.io-client';
import { createServer } from '../src/server.js';
import { MemoryStore } from '../src/store/index.js';

const OWNER_TOKEN = `test-${crypto.randomBytes(8).toString('hex')}`;
const authHeaders = { authorization: `Bearer ${OWNER_TOKEN}` };
const OWNER_ID = 'owner-test-1';

const passed = [];
const step = async (name, fn) => {
  await fn();
  passed.push(name);
  console.log(`  ✔ ${name}`);
};

// --- helpers ---------------------------------------------------------------

function connect(pairId, role, secret) {
  return new Promise((resolve, reject) => {
    const socket = Client(`http://127.0.0.1:${port}`, {
      auth: { pairId, role, secret },
      transports: ['websocket'],
      reconnection: false,
    });
    const presenceEvents = [];
    socket.on('presence', (e) => presenceEvents.push(e));
    const msgs = [];
    socket.on('msg', (e) => msgs.push(e));
    const t = setTimeout(() => reject(new Error('connect timeout')), 5000);
    socket.on('hello', (msg) => { clearTimeout(t); resolve({ socket, hello: msg, presenceEvents, msgs }); });
    socket.on('auth:error', (e) => { clearTimeout(t); reject(new Error(`auth: ${e.error}`)); });
    socket.on('connect_error', (e) => { clearTimeout(t); reject(new Error(`connect_error: ${e.message}`)); });
  });
}

/** Wait until the recorder saw `role` go online (or offline). */
async function waitPresence(recorder, role, online = true, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const hit = recorder.find((e) => e.role === role && e.online === online);
    if (hit) return hit;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timeout waiting for presence ${role}=${online}`);
}

const emitAck = (socket, event, payload) =>
  new Promise((resolve) => socket.emit(event, payload, (res) => resolve(res)));

const waitFor = (socket, event, timeout = 5000) =>
  new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout waiting for ${event}`)), timeout);
    socket.once(event, (data) => { clearTimeout(t); resolve(data); });
  });

// --- boot ------------------------------------------------------------------

const store = new MemoryStore();
const { server, io } = await createServer({ store, ownerToken: OWNER_TOKEN, logRequests: false });
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
console.log(`Smoke test on :${port}\n`);

const base = `http://127.0.0.1:${port}/api`;

// --- 1. health ---------------------------------------------------------------
await step('GET /api/health', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
});

// --- 2. owner registration ------------------------------------------------------
let ownerBundle;
await step('POST /api/owner/register', async () => {
  ownerBundle = {
    ownerId: OWNER_ID,
    identityPubKey: crypto.randomBytes(32).toString('base64'),
    signedPrekey: crypto.randomBytes(32).toString('base64'),
    prekeySignature: crypto.randomBytes(64).toString('base64'),
  };
  const res = await fetch(`${base}/owner/register`, {
    method: 'POST', headers: { ...authHeaders, 'content-type': 'application/json' },
    body: JSON.stringify(ownerBundle),
  });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).ok, true);
});

await step('owner register rejects bad token', async () => {
  const res = await fetch(`${base}/owner/register`, {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer nope' },
    body: JSON.stringify(ownerBundle),
  });
  assert.equal(res.status, 401);
});

// --- 3. invite lifecycle --------------------------------------------------------
let inviteCode, pair;
await step('POST /api/invites returns single-use code', async () => {
  const res = await fetch(`${base}/invites`, { method: 'POST', headers: authHeaders });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.ok(body.code.length >= 20);
  inviteCode = body.code;
});

await step('POST /api/invites rejects unauthenticated', async () => {
  const res = await fetch(`${base}/invites`, { method: 'POST' });
  assert.equal(res.status, 401);
});

await step('redeem exchanges code for pair + owner prekey bundle', async () => {
  const res = await fetch(`${base}/invites/redeem`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      code: inviteCode,
      ownerId: OWNER_ID,
      clientPubKey: crypto.randomBytes(32).toString('base64'),
      clientDisplayName: 'Test Guest',
    }),
  });
  assert.equal(res.status, 201);
  pair = await res.json();
  assert.ok(pair.pairId && pair.pairSecret);
  assert.equal(pair.ownerIdentityPubKey, ownerBundle.identityPubKey);
});

await step('redeem is single-use (second use → 409)', async () => {
  const res = await fetch(`${base}/invites/redeem`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code: inviteCode, ownerId: OWNER_ID, clientPubKey: 'x' }),
  });
  assert.equal(res.status, 409);
});

await step('unknown code → 404', async () => {
  const res = await fetch(`${base}/invites/redeem`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code: 'garbage', ownerId: OWNER_ID, clientPubKey: 'x' }),
  });
  assert.equal(res.status, 404);
});

// --- 4. sockets -------------------------------------------------------------------
let ownerSock, clientSock, ownerHello, clientHello, clientPresence;
await step('owner + client sockets authenticate and say hello', async () => {
  ({ socket: ownerSock, hello: ownerHello } = await connect(pair.pairId, 'owner', pair.pairSecret));
  ({ socket: clientSock, hello: clientHello, presenceEvents: clientPresence } = await connect(pair.pairId, 'client', pair.pairSecret));
  assert.equal(ownerHello.role, 'owner');
  assert.equal(clientHello.role, 'client');
  assert.ok(Array.isArray(ownerHello.iceServers) && ownerHello.iceServers.length > 0);
});

await step('socket auth rejects bad secret', async () => {
  await assert.rejects(() => connect(pair.pairId, 'client', 'wrong-secret'));
});

await step('presence: both sides see each other online', async () => {
  await waitPresence(clientPresence, 'owner', true);
});

// --- 5. message relay ---------------------------------------------------------------
await step('client → owner encrypted message relays online', async () => {
  const env = { ct: crypto.randomBytes(64).toString('base64'), n: 1 };
  const p = waitFor(ownerSock, 'msg');
  const ack = await emitAck(clientSock, 'msg', { id: 'm1', kind: 'chat', envelope: env });
  assert.equal(ack.delivered, true);
  const got = await p;
  assert.equal(got.from, 'client');
  assert.deepEqual(got.envelope, env);
});

await step('read receipt relays owner → client', async () => {
  const p = waitFor(clientSock, 'msg:read');
  await emitAck(ownerSock, 'msg:read', { ids: ['m1'] });
  const got = await p;
  assert.deepEqual(got.ids, ['m1']);
});

await step('typing indicator relays', async () => {
  const p = waitFor(clientSock, 'typing');
  await emitAck(ownerSock, 'typing', { typing: true });
  const got = await p;
  assert.equal(got.typing, true);
});

await step('location envelope relays and is stored as last-known', async () => {
  const env = { ct: crypto.randomBytes(32).toString('base64') };
  const p = waitFor(ownerSock, 'location');
  const ack = await emitAck(clientSock, 'location', { envelope: env, timestamp: 123 });
  assert.equal(ack.delivered, true);
  const got = await p;
  assert.deepEqual(got.envelope, env);

  const last = await emitAck(ownerSock, 'location:last', {});
  assert.deepEqual(last.last.envelope, env);
});

// --- 6. offline queue ------------------------------------------------------------------
await step('message queues when peer offline, drains on reconnect', async () => {
  clientSock.disconnect();
  await new Promise((r) => setTimeout(r, 100)); // let the server observe the drop

  const ack = await emitAck(ownerSock, 'msg', { id: 'm2', kind: 'chat', envelope: { ct: 'x' } });
  assert.equal(ack.queued, true);
  assert.equal(ack.delivered, false);

  const second = await connect(pair.pairId, 'client', pair.pairSecret);
  const deadline = Date.now() + 5000;
  while (!second.msgs.some((m) => m.id === 'm2') && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 20));
  }
  const got = second.msgs.find((m) => m.id === 'm2');
  assert.ok(got, 'queued message not delivered on reconnect');
  assert.equal(got.queued, true);
  clientSock.close();
  clientSock = second.socket; // the reconnected socket is now the active client
  clientPresence = second.presenceEvents;
});

// --- 7. WebRTC signaling -------------------------------------------------------------
await step('call invite / offer / answer / ice relay both ways', async () => {
  const pInvite = waitFor(ownerSock, 'call:invite');
  await emitAck(clientSock, 'call:invite', { callId: 'c1', media: 'video' });
  assert.equal((await pInvite).callId, 'c1');

  const pOffer = waitFor(clientSock, 'rtc:offer');
  await emitAck(ownerSock, 'rtc:offer', { callId: 'c1', sdp: 'offer-sdp' });
  assert.equal((await pOffer).sdp, 'offer-sdp');

  const pAnswer = waitFor(ownerSock, 'rtc:answer');
  await emitAck(clientSock, 'rtc:answer', { callId: 'c1', sdp: 'answer-sdp' });
  assert.equal((await pAnswer).sdp, 'answer-sdp');

  const pIce = waitFor(clientSock, 'rtc:ice');
  await emitAck(ownerSock, 'rtc:ice', { callId: 'c1', candidate: { candidate: 'x' } });
  assert.equal((await pIce).candidate.candidate, 'x');
});

// --- 8. revoke ------------------------------------------------------------------------
await step('revoke closes both sockets', async () => {
  const closedOwner = waitFor(ownerSock, 'disconnect');
  const res = await fetch(`${base}/pairs/${pair.pairId}/revoke`, {
    method: 'POST', headers: { ...authHeaders, 'content-type': 'application/json' },
  });
  assert.equal(res.status, 200);
  await closedOwner;
  await assert.rejects(() => connect(pair.pairId, 'client', pair.pairSecret));
});

// --- done -------------------------------------------------------------------------------
for (const s of [ownerSock, clientSock]) s?.close();
io.close();
server.close();
await store.close();

console.log(`\nAll ${passed.length} smoke tests passed ✔`);
process.exit(0);
