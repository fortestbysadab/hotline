# Technical Architecture & System Design Document

## 1. System Topology & Overview

The system operates on an asymmetric **Hub-and-Spoke (1-to-$N$)** model. Communication pathways are strictly isolated between the central host (**Owner / App B**) and invited clients (**Clients / App A**).

```
 ┌─────────────────────────────────────────────────────────┐
 │                      App B (Owner)                      │
 └──────┬──────────────────────┬────────────────────┬──────┘
        │                      │                    │
        │ Direct P2P (E2EE)    │ Direct P2P (E2EE) │ Direct P2P (E2EE)
        ▼                      ▼                    ▼
 ┌──────────────┐       ┌──────────────┐     ┌──────────────┐
 │ App A (User) │       │ App A (User) │     │ App A (User) │
 └──────────────┘       └──────────────┘     └──────────────┘
```

* **No Client-to-Client Topology:** Client devices ($A_1, A_2, \dots, A_n$) have no cryptographic knowledge of each other, no network connections between them, and no access to a global user registry.
* **Server Role:** The intermediate backend acts purely as an untrusted signaling server, invitation relay, and temporary offline message store. All payload data (text, media, location, audio/video) is encrypted on the client device prior to transport.

---

## 2. Mobile App Architecture (Single Codebase, Dual Targets)

The frontend applications are built using a single **Flutter** codebase leveraging **Build Flavors** (Android Product Flavors) to isolate UI components, routes, and capabilities.

### 2.1 Target Configurations

| Parameter | App A Target (`client`) | App B Target (`owner`) |
| :--- | :--- | :--- |
| **Package ID** | `com.hotline.app.client` | `com.hotline.app.owner` |
| **App Identity** | Direct Hotline | Command Center |
| **User Directory** | None (Hardcoded to single Owner peer) | Dynamic list of paired client contacts |
| **Key Generation** | Single Identity Key Pair | Identity Key Pair + Client Key Directory |
| **Permissions** | Location, Camera, Mic, Foreground Service | Camera, Mic, Notifications |

### 2.2 Flavor Project Structure

```
lib/
├── main_client.dart            # Entry point for App A
├── main_owner.dart             # Entry point for App B
├── core/
│   ├── crypto/                 # Double Ratchet & Keystore logic
│   ├── network/                # Socket.io & WebRTC signaling
│   ├── storage/                # Encrypted local database (Isar / Hive)
│   └── location/               # Android Foreground Service & GPS streaming
├── features/
│   ├── chat/                   # E2EE Text & File transmission UI
│   ├── calling/                # WebRTC Audio/Video UI
│   ├── map/                    # flutter_map + OpenStreetMap layers
│   └── invite/                 # Code entry (App A) / Generator (App B)
└── models/                     # Shared data structures
```

---

## 3. End-to-End Encryption (E2EE) Protocol

The platform implements an adapted version of the **Signal Protocol** (utilizing $X3DH$ key agreement and the **Double Ratchet** algorithm).

```
[App A]                                                [App B]
   │                                                      │
   ├── Generate Ephemeral Key (EK_A)                      │
   ├── Fetch Owner Prekey (IK_B, SPK_B) from Server ──────►│
   ├── Compute Master Shared Secret (DH1 + DH2 + DH3)     │
   │                                                      │
   │◄──────────────── Express Double Ratchet Sync ────────┤
```

### 3.1 Cryptographic Primitives
* **Key Exchange:** $X3DH$ (Extended Triple Diffie-Hellman) over Curve25519.
* **Symmetric Encryption:** $AES-256-GCM$ for message payloads, files, and location packets.
* **Symmetric Ratchet:** $HKDF-SHA256$ to derive new message keys for every single payload.
* **Local Key Storage:** Private keys are generated and locked inside the **Android Keystore System** via hardware-backed security (TEE/StrongBox).

### 3.2 Secure File & Media Exchange Flow
1. **Sender Side:**
   * Generates a random $256$-bit symmetric key ($K_{file}$) and an Initialization Vector ($IV$).
   * Encrypts the raw file locally using $AES-256-GCM$.
   * Uploads the encrypted binary blob to temporary cloud storage (or streams via WebRTC DataChannel).
   * Encrypts $K_{file}$ + download URI using the recipient's current Double Ratchet key state.
2. **Receiver Side:**
   * Receives and decrypts the meta-message payload using Double Ratchet to obtain $K_{file}$.
   * Downloads the encrypted file blob and decrypts it locally to disk.

---

## 4. Real-Time Communication Pipeline (WebRTC + WebSockets)

Voice calls, video calls, and low-latency data streams are handled via **WebRTC**, orchestrated by a Node.js WebSocket signaling server.

```
[App A]                    [Node.js Server]                   [App B]
   │                              │                              │
   │── Send SDP Offer ───────────►│── Relay SDP Offer ──────────►│
   │                              │                              │
   │◄── Relay SDP Answer ─────────│◄── Send SDP Answer ──────────│
   │                              │                              │
   │── Exchange ICE Candidates ──►│── Exchange ICE Candidates ──►│
   │                              │                              │
   └===================== Direct P2P Connection =================┘
                         (DTLS-SRTP Audio/Video)
```

### 4.1 WebRTC Setup & Configuration
* **Media Protocols:** DTLS-SRTP (Datagram Transport Layer Security Extension to Secure Real-time Transport Protocol).
* **STUN Server Configuration:** Google Public STUN (`stun:stun.l.google.com:19302`) for NAT discovery.
* **TURN Server Relay (Fallback):** Public/Open Relay or low-tier Coturn instance activated only when both devices are behind symmetric NATs that block direct peer connections.

---

## 5. Encrypted Live Location & Background Engine

Live location sharing requires persistent background execution on Android without battery drain or operating system termination.

### 5.1 Android Foreground Service
* **Package:** `flutter_background_service` combined with `geolocator`.
* **System Requirement:** Continuous notification displayed in the Android status bar (`ONGOING_NOTIFICATION`).
* **Power Management:** Android `WAKE_LOCK` acquired only during active GPS sampling intervals.

### 5.2 Adaptive Sampling Strategy

| Device State | Sampling Interval | Distance Filter | Battery Impact |
| :--- | :--- | :--- | :--- |
| **In Motion ($> 5 \text{ km/h}$)** | $3 - 5 \text{ seconds}$ | $10 \text{ meters}$ | Moderate |
| **Stationary ($< 5 \text{ km/h}$)** | $60 \text{ seconds}$ | $50 \text{ meters}$ | Minimal ($< 1\% / \text{hour}$) |

### 5.3 Location Payload Schema
Before transmission over WebSockets or Firestore, the location payload is serialized and encrypted:

```json
{
  "sender_id": "client_uuid_9876",
  "timestamp": 1774321200,
  "encrypted_payload": "a3f89021b... (AES-256-GCM cipher text)"
}
```

**Decrypted Payload Structure (Visible only to App B):**
```json
{
  "latitude": 22.5726,
  "longitude": 88.3639,
  "accuracy": 4.5,
  "speed": 1.2,
  "altitude": 12.0,
  "battery_level": 84,
  "is_charging": false
}
```

---

## 6. Database & Backend Schemas

The backend uses **Firebase Firestore** for lightweight coordination and **Node.js (Socket.io)** for real-time socket events.

### 6.1 Firestore Collections

#### Collection: `invites`
| Field | Type | Description |
| :--- | :--- | :--- |
| `token_id` | String (PK) | Single-use cryptographic invite code (hashed) |
| `created_at` | Timestamp | Server generation time |
| `is_used` | Boolean | Access flag (`true` after pairing) |
| `owner_pub_key` | String | Owner Identity Public Key |

#### Collection: `pairs`
| Field | Type | Description |
| :--- | :--- | :--- |
| `pair_id` | String (PK) | Unique pair ID (`owner_id` + `client_id`) |
| `client_id` | String | Anonymous Client UUID |
| `client_pub_key`| String | Client Identity Public Key |
| `created_at` | Timestamp | Timestamp of activation |

#### Collection: `offline_queue`
| Field | Type | Description |
| :--- | :--- | :--- |
| `message_id` | String (PK) | Unique message UUID |
| `recipient_id` | String | Recipient User UUID |
| `ciphertext` | String | E2EE encrypted message string |
| `created_at` | Timestamp | Time dropped into queue |

---

## 7. Zero-Cost Infrastructure & Deployment Blueprint

The infrastructure leverages free operational tiers across platforms.

```
[Flutter Mobile Clients]
       │
       ├── WebSockets & Signaling ──► [Render.com (Free Node.js Tier)]
       │                                  (Spins down when idle, wakes on request)
       │
       ├── Key Pairings & Queue ────► [Firebase Firestore (Free Tier)]
       │                                  (50k reads, 20k writes per day)
       │
       └── Push Notifications ──────► [Firebase Cloud Messaging (FCM)]
                                          (100% Unlimited Free)
```

### 7.1 Infrastructure Limits vs. System Demands

* **Firestore Usage:** $1$ active pairing uses $\sim 5$ database reads/writes during setup. Everyday chat uses WebSocket connection; Firestore is touched **only** if the recipient device is offline.
* **Server Bandwidth:** Audio, video, and active live location streams run P2P or over Socket.io text frames. Total backend bandwidth usage stays well under Render’s free $100\text{ GB/month}$ limit.

---

## 8. Android Build & Flavor Distribution Commands

### 8.1 Prerequisites
* Flutter SDK (Version 3.x or higher)
* Android NDK & JDK 17
* Firebase `google-services.json` placed in:
  * `android/app/src/client/google-services.json`
  * `android/app/src/owner/google-services.json`

### 8.2 Build Commands

#### Generating Client App APK (App A)
```bash
flutter build apk --release --flavor client -t lib/main_client.dart
```
*Output Location:* `build/app/outputs/flutter-apk/app-client-release.apk`

#### Generating Owner App APK (App B)
```bash
flutter build apk --release --flavor owner -t lib/main_owner.dart
```
*Output Location:* `build/app/outputs/flutter-apk/app-owner-release.apk`