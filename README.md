# Private Hotline

Asymmetric, invitation-only, end-to-end-encrypted 1-to-N communication network.
One central **Owner** (command center) + invited **Clients** (a private hotline
each). No public registration, no directory, no client-to-client topology —
exactly the system in `Project Vision & Overview (1).md` and
`Technical Architecture & Specifications.md`.

```
                    ┌────────────────────────┐
                    │   App B — Owner (Hub)  │
                    └───┬───────┬───────┬────┘
        E2EE P2P (WebRTC/WS)    …       …
              ┌─────────┴────┬─────────┴───┐
        ┌─────┴─────┐  ┌─────┴─────┐  ┌────┴──────┐
        │ App A ×1  │  │ App A ×2  │  │ App A ×N  │   (clients never see
        └───────────┘  └───────────┘  └───────────┘    each other)
                     ▲
                     │  untrusted relay only:
             [ Node.js signaling ]  invites · ciphertext store-and-forward ·
             WebRTC SDP/ICE · presence — zero plaintext, zero big blobs
```

## Repository layout

| Path | What it is |
| :--- | :--- |
| `backend/` | Node.js + Socket.io relay: invites, pairing, E2EE envelope relay, offline queue, WebRTC signaling, presence, revoke. In-memory store (dev) or Firestore (free-tier production). **19-step e2e smoke test + protocol twin-test.** |
| `app/` | Single Flutter codebase, two flavors: `client` (App A) and `owner` (App B). X3DH + Double Ratchet E2EE, Hive local store, WebRTC calls, foreground-service live location, flutter_map/OpenStreetMap view. |
| `Project Vision & Overview (1).md` | Product spec (original planning doc). |
| `Technical Architecture & Specifications.md` | System design (original planning doc). |

## Quick start

### 1. Relay

```bash
cd backend
npm install
OWNER_TOKEN="$(openssl rand -hex 32)" npm start     # :8080, memory store
npm test                                            # end-to-end smoke suite
```

### 2. Apps

```bash
cd app
flutter pub get

# App A — guest (Android emulator reaches host via 10.0.2.2)
flutter run --flavor client -t lib/main_client.dart

# App B — owner (token must match the relay's OWNER_TOKEN)
flutter run --flavor owner -t lib/main_owner.dart \
  --dart-define=OWNER_TOKEN="$OWNER_TOKEN"
```

Release APKs — per the spec's build commands:

```bash
flutter build apk --release --flavor client -t lib/main_client.dart
flutter build apk --release --flavor owner  -t lib/main_owner.dart
```

See `app/README.md` and `backend/README.md` for configuration, Firestore
activation, TURN fallback, signing and FCM setup.

## How the security works (short version)

1. **Owner** publishes an identity: X25519 identity key + signed prekey
   (signature verifiable via its Ed25519 key) — `POST /api/owner/register`.
2. **Owner** mints single-use invite codes (`<ownerId>~<192-bit random>`);
   the relay stores only their SHA-256 hash.
3. **Client** redeems a code → receives the owner prekey bundle → runs
   **X3DH** locally → derives the Double Ratchet root key.
4. Every chat message, file reference and location packet is sealed with
   **AES-256-GCM under per-message keys from the Double Ratchet**
   (HKDF-SHA256 root chain, HMAC-SHA256 message chains, bounded skipped-key
   cache). The X3DH handshake rides on the first outbound messages until the
   session is confirmed.
5. Files: random per-file AES key → chunked AES-GCM → chunks relayed as
   opaque envelopes; the key travels only inside the ratchet.
6. The relay can route, store ciphertext and hand out ICE servers — and
   nothing else. Revoking a pair severs sockets immediately.

## Status / roadmap

- [x] Phase 2 groundwork: relay + security protocol implemented & tested
- [x] Flutter dual-flavor app: chat, calls, invites, map, location engine
- [ ] Phase 1/3 polish: wireframes realized 1:1, physical-device hardening
- [ ] FCM push integration (config-drop ready, see `app/README.md`)
- [ ] Coturn TURN deployment for symmetric-NAT calls
- [ ] Firestore production cutover (adapter already implemented)
