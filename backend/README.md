# Private Hotline — Relay Backend

An **untrusted** signaling server for the Private Hotline network. It never sees
plaintext: every message, file reference and location packet arrives as an
E2EE envelope produced on-device (X3DH + Double Ratchet, AES-256-GCM).

## Responsibilities

| Area | What the server does |
| :--- | :--- |
| Invitations | Mints single-use, high-entropy codes; stores only their SHA-256 hash |
| Pairing | Exchanges the client's public identity key for the Owner's prekey bundle (X3DH input) |
| Messaging | Store-and-forward of opaque ciphertext envelopes when the peer is offline |
| Live location | Relays encrypted location envelopes; keeps the last one per pair |
| Calls | WebRTC signaling relay (offer / answer / ICE), Google STUN by default, TURN optional |
| Presence | Online/offline state per side of a pair, typing + read receipts |
| Access control | Owner can revoke a pair; sockets are severed immediately |

## Layout

```
src/
├── server.js            # bootstrap: express + socket.io
├── config.js            # env-driven configuration
├── store/
│   ├── index.js         # MemoryStore (dev) + FirestoreStore (production)
├── routes/api.js        # REST: owner register, invites, pairs
└── realtime/signaling.js# socket.io event handlers
test/smoke.js            # end-to-end smoke test (no framework needed)
```

## Run

```bash
npm install
npm start                 # :8080, in-memory store (dev)
npm test                  # 18-step end-to-end smoke test
```

## Configuration

Copy `.env.example` → `.env` (or set environment vars in your host dashboard).

| Variable | Purpose |
| :--- | :--- |
| `OWNER_TOKEN` | Shared secret for all Owner management calls. **Required in production.** |
| `FIRESTORE_PROJECT_ID` | Set to activate the durable Firestore store (needs GCP credentials) |
| `INVITE_TTL_HOURS` / `INVITE_CODE_BYTES` | Invite lifetime & entropy (defaults: 72 h, 192-bit) |
| `OFFLINE_QUEUE_MAX` | Per-pair offline envelope cap (default 500) |
| `TURN_URL` / `TURN_USER` / `TURN_CREDENTIAL` | Optional TURN relay for symmetric NATs |
| `CORS_ORIGINS` | Socket CORS allow-list (default `*`) |

## API overview

### REST (owner calls use `Authorization: Bearer $OWNER_TOKEN`)

```
POST /api/owner/register        { ownerId, identityPubKey, signedPrekey, prekeySignature? }
POST /api/invites               → { code, expiresAt }          # plaintext shown once
GET  /api/invites/:hash/status  → { isUsed, expired, ... }
POST /api/invites/redeem        { code, ownerId, clientPubKey, clientDisplayName? }
                                → { pairId, pairSecret, ownerIdentityPubKey, ownerSignedPrekey }
GET  /api/pairs?ownerId=…       → { pairs: [...] }
POST /api/pairs/:id/revoke      → { ok }
GET  /api/health                → { ok }
```

### Socket.io

Connect with `auth: { pairId, role: 'owner'|'client', secret }`.
Server replies `hello { iceServers }`, then drains queued envelopes as `msg {queued: true}`.

| Event | Direction | Payload |
| :--- | :--- | :--- |
| `msg` | both | `{ id, kind, envelope }` — relayed or queued |
| `msg:ack` | → sender | `{ delivered, queued }` |
| `msg:read` | both | `{ ids: [...] }` |
| `typing` | both | `{ typing }` |
| `location` | both | `{ envelope, timestamp }` + stored as last-known |
| `location:last` | both | → last known envelope |
| `call:invite` / `call:accept` / `call:reject` / `call:end` | both | `{ callId, media? }` |
| `rtc:offer` / `rtc:answer` / `rtc:ice` | both | `{ callId, sdp / candidate }` |
| `presence` | → both | `{ role: peerRole, online }` |
| `pair:revoked` | → both | access terminated |

## Security posture

- Invite codes: 192-bit random, only hashes persisted → a DB leak yields nothing usable.
- Pair sockets authenticate with a per-pair secret issued once at redemption.
- The server cannot read, forge, or replay meaningfully: envelopes are ratcheted ciphertext.
- Message bodies capped at 1 MB HTTP / 2 MB socket — large files are transferred P2P
  (WebRTC data channel) per the architecture doc, never stored here.
