/**
 * Private Hotline — backend configuration.
 *
 * Everything is environment-driven so the same code runs locally, on
 * Render.com (free tier), or in any container. See .env.example.
 */

const int = (value, fallback) => {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
};

const bool = (value, fallback) => {
  if (value === undefined || value === null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
};

export const config = {
  port: int(process.env.PORT, 8080),

  /**
   * Shared secret the Owner app uses to register its identity / manage invites.
   * MUST be set in production. When unset (dev), a per-boot random token is used
   * and printed once so local tests can pick it up.
   */
  ownerToken: process.env.OWNER_TOKEN || null,

  /**
   * Store backend: 'memory' (default) or 'firestore'.
   * Firestore is activated automatically when FIRESTORE_PROJECT_ID is present.
   */
  store: process.env.FIRESTORE_PROJECT_ID ? 'firestore' : 'memory',

  // Invite behaviour -------------------------------------------------------
  inviteTtlHours: int(process.env.INVITE_TTL_HOURS, 72),
  inviteCodeBytes: int(process.env.INVITE_CODE_BYTES, 24), // => ~192-bit codes

  // Offline queue limits per pair (server is an untrusted store; keep small) --
  offlineQueueMax: int(process.env.OFFLINE_QUEUE_MAX, 500),

  // Socket.io ---------------------------------------------------------------
  corsOrigins: (process.env.CORS_ORIGINS || '*').split(',').map((s) => s.trim()),
  pingIntervalMs: int(process.env.SOCKET_PING_INTERVAL_MS, 20_000),

  // WebRTC / ICE hinting sent to clients during call setup -------------------
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    // Add a Coturn TURN entry via env when symmetric NAT traversal is needed:
    ...(process.env.TURN_URL
      ? [{ urls: process.env.TURN_URL, username: process.env.TURN_USER, credential: process.env.TURN_CREDENTIAL }]
      : []),
  ],

  logRequests: bool(process.env.LOG_REQUESTS, true),
};

/** Owner token resolution happens lazily so dev boot can mint one. */
let devToken = null;
export function resolveOwnerToken() {
  if (config.ownerToken) return config.ownerToken;
  if (!devToken) {
    devToken = `dev-${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
    console.warn(`[config] OWNER_TOKEN not set — generated ephemeral dev token: ${devToken}`);
  }
  return devToken;
}
