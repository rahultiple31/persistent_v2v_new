'use strict';

const http = require('node:http');

const port = Number.parseInt(process.env.PORT || '8080', 10);

const server = http.createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  response.writeHead(501, { 'content-type': 'application/json' });
  response.end(JSON.stringify({
    error: 'Translation proxy application handlers are not configured.',
  }));
});

server.listen(port, '0.0.0.0', () => {
  process.stdout.write(`V2V translation proxy listening on port ${port}\n`);
});

function shutdown(signal) {
  process.stdout.write(`Received ${signal}; shutting down\n`);
  server.close((error) => {
    if (error) {
      process.stderr.write(`${error.stack || error}\n`);
      process.exitCode = 1;
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
