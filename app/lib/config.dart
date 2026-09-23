/// Build-time configuration, injected via `--dart-define` per the build
/// commands in README.md. Defaults target the Android emulator (10.0.2.2 is
/// the host loopback) for local development against `npm start` in backend/.
class RelayConfig {
  RelayConfig._();

  /// Signaling relay base URL (Render free tier in production).
  static const String relayUrl = String.fromEnvironment(
    'RELAY_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// Owner management token (App B only). REQUIRED for the owner app;
  /// passed as:  --dart-define=OWNER_TOKEN=...
  static const String ownerToken = String.fromEnvironment('OWNER_TOKEN', defaultValue: '');

  /// Stable owner identity id (App B only).
  static const String ownerId = String.fromEnvironment('OWNER_ID', defaultValue: 'owner-primary');

  static bool get ownerTokenConfigured => ownerToken.isNotEmpty;
}
