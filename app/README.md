# Private Hotline — Flutter Apps (App A + App B)

One codebase, two product flavors, per `Technical Architecture & Specifications.md` §2.

| | App A (`client`) | App B (`owner`) |
| :-- | :--- | :--- |
| Role | Guest's direct encrypted line | Owner's command center |
| Package | `com.hotline.app.client` | `com.hotline.app.owner` |
| Entry | `lib/main_client.dart` | `lib/main_owner.dart` |
| UI | Invite entry → single hotline screen | Inbox + live map + invite generator |

## Prerequisites

- Flutter SDK 3.x (see root README)
- Android SDK, NDK, JDK 17
- A running relay (see `../backend`). For the Android emulator the default
  `RELAY_URL` (`http://10.0.2.2:8080`) already points at your host machine.

## Run (debug)

```bash
# App A — guest
flutter run --flavor client -t lib/main_client.dart \
  --dart-define=RELAY_URL=http://10.0.2.2:8080

# App B — owner  (OWNER_TOKEN must match the relay's env)
flutter run --flavor owner -t lib/main_owner.dart \
  --dart-define=RELAY_URL=http://10.0.2.2:8080 \
  --dart-define=OWNER_TOKEN="$OWNER_TOKEN" \
  --dart-define=OWNER_ID=owner-primary
```

## Release builds

```bash
flutter build apk --release --flavor client -t lib/main_client.dart
flutter build apk --release --flavor owner  -t lib/main_owner.dart
# → build/app/outputs/flutter-apk/app-{client,owner}-release.apk
```

### Signing (before any real distribution)

The debug keystore is used by default (`android/app/build.gradle` → TODO).
Create a keystore and wire it via `android/key.properties`:

```
storePassword=…
keyPassword=…
keyAlias=hotline
storeFile=/path/to/keystore.jks
```

### Push notifications (FCM, optional in alpha)

1. Create two Firebase apps with package ids `com.hotline.app.client` / `com.hotline.app.owner`.
2. Drop the config files at `android/app/src/client/google-services.json` and
   `android/app/src/owner/google-services.json` — the Gradle file applies the
   plugin automatically when both are present.

## Layout

```
lib/
├── main_client.dart / main_owner.dart   # flavor entry points
├── app.dart                             # bootstrap + routing
├── app_state.dart                       # central controller (channels, E2EE, files)
├── config.dart                          # --dart-define configuration
├── core/
│   ├── crypto/                          # X3DH, Double Ratchet, session manager
│   ├── network/                         # relay REST + Socket.io channel
│   ├── storage/                         # Hive-backed local store
│   ├── location/                        # foreground service + adaptive GPS
│   └── webrtc/                          # call engine
├── features/
│   ├── invite/                          # code entry (A) / generator (B)
│   ├── chat/                            # encrypted conversation surface
│   ├── calling/                         # WebRTC call UI
│   ├── map/                             # flutter_map OSM live view (B)
│   └── shell/                           # home screens per flavor
├── models/                              # shared data structures
└── shared/theme.dart
```

## Tests

```bash
flutter test test/crypto_selftest.dart   # E2EE core (mirrors backend twin-test)
```
