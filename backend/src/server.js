/**
 * Private Hotline — signaling server bootstrap.
 *
 * An UNTRUSTED relay: invites, pair registry, encrypted message store-and-forward,
 * WebRTC signaling and presence. All payload data is E2EE on the devices;
 * the server only ever routes opaque envelopes.
 */
import http from 'node:http';
import express from 'express';
import { Server as SocketIOServer } from 'socket.io';
import { config } from './config.js';
import { createStore } from './store/index.js';
import { apiRouter } from './routes/api.js';
import { attachRealtime } from './realtime/signaling.js';

export async function createServer(overrides = {}) {
  const cfg = { ...config, ...overrides };
  const store = overrides.store ?? (await createStore(cfg));

  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '1mb' })); // bodies are tiny: routing metadata + ciphertext
  if (cfg.logRequests) app.use((req, _res, next) => { next(); });

  app.use('/api', apiRouter(store, cfg));
  app.get('/', (_req, res) => res.json({ service: 'private-hotline-relay', status: 'ok' }));

  const server = http.createServer(app);
  const io = new SocketIOServer(server, {
    cors: { origin: cfg.corsOrigins, methods: ['GET', 'POST'] },
    pingInterval: cfg.pingIntervalMs,
    maxHttpBufferSize: 2e6, // signaling + small envelopes only; big files go P2P
  });

  attachRealtime(io, store, cfg);
  app.set('emitToPair', (pairId, event, payload) => io.emitToPair(pairId, event, payload));

  return { app, server, io, store, config: cfg };
}

/** Standalone entry point. */
const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop());
if (isMain) {
  const { server, config: cfg } = await createServer();
  server.listen(cfg.port, '0.0.0.0', () => {
    console.log(`[hotline] relay listening on :${cfg.port} (store=${cfg.store})`);
  });
}
