'use strict';

const http = require('node:http');
const net = require('node:net');

const port = Number(process.env.PORT || 8080);

function pingPostgres() {
  const host = process.env.DB_HOST;
  const dbPort = Number(process.env.DB_PORT || 5432);
  if (!host) return Promise.resolve({ ok: false, reason: 'DB_HOST missing' });

  return new Promise((resolve) => {
    const socket = net.connect({ host, port: dbPort, timeout: 2000 }, () => {
      socket.end();
      resolve({ ok: true });
    });
    socket.on('error', (err) => resolve({ ok: false, reason: err.message }));
    socket.on('timeout', () => {
      socket.destroy();
      resolve({ ok: false, reason: 'timeout' });
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = req.url || '/';
  if (url === '/healthz' || url === '/') {
    const db = await pingPostgres();
    const body = JSON.stringify({
      status: db.ok ? 'ok' : 'degraded',
      service: 'catalog-api',
      db,
    });
    res.writeHead(db.ok ? 200 : 503, { 'content-type': 'application/json' });
    res.end(body);
    return;
  }

  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(
    JSON.stringify({
      service: 'catalog-api',
      bucket: process.env.ASSETS_BUCKET || null,
    }),
  );
});

server.listen(port, '0.0.0.0');
