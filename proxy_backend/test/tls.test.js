import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import https from "node:https";
import { X509Certificate, createPrivateKey } from "node:crypto";
import { createSelfSignedCertificate } from "../src/selfSignedCert.js";
import { auth, end, novaEvent, runClient, start, startTestServer, testConfig } from "./helpers.js";

// The load balancer does not check the task's certificate; these clients do the same.
function get(url, { insecure = true } = {}) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https:") ? https : http;
    lib
      .get(url, { agent: false, ...(insecure ? { rejectUnauthorized: false } : {}) }, (res) => {
        const protocol = res.socket.getProtocol?.() ?? null;
        const peerCertificate = res.socket.getPeerX509Certificate?.() ?? null;
        let body = "";
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => resolve({ status: res.statusCode, body, protocol, peerCertificate }));
      })
      .on("error", reject);
  });
}

test("tls: the self-signed certificate is valid X.509, RSA 2048, signed with its own key, new every time", async () => {
  const now = new Date("2026-10-29T12:00:00Z");
  const first = await createSelfSignedCertificate({ now });
  const cert = new X509Certificate(first.cert);
  assert.equal(cert.subject, "CN=v2v-proxy");
  assert.equal(cert.issuer, "CN=v2v-proxy");
  assert.ok(cert.verify(cert.publicKey), "signed by its own key");
  assert.ok(cert.checkPrivateKey(createPrivateKey(first.key)), "matches the private key");
  assert.equal(cert.publicKey.asymmetricKeyDetails.modulusLength, 2048);
  assert.equal(new Date(cert.validFrom).toISOString(), "2026-10-29T11:00:00.000Z");
  assert.equal(new Date(cert.validTo).toISOString(), "2027-10-29T12:00:00.000Z");
  assert.equal(cert.fingerprint256, first.fingerprint256);
  assert.match(first.key, /^-----BEGIN PRIVATE KEY-----\n/);

  const second = await createSelfSignedCertificate({ now });
  const other = new X509Certificate(second.cert);
  assert.notEqual(other.serialNumber, cert.serialNumber);
  assert.notEqual(second.key, first.key);
});

test("tls: SERVER_TLS is off by default on 8080, self-signed defaults to 8443, PORT still wins, bad values fail", () => {
  const off = testConfig();
  assert.equal(off.serverTls, "off");
  assert.equal(off.port, 8080);
  const on = testConfig({ SERVER_TLS: "self-signed" });
  assert.equal(on.serverTls, "self-signed");
  assert.equal(on.port, 8443);
  assert.equal(testConfig({ SERVER_TLS: " Self-Signed ", PORT: "9443" }).port, 9443);
  assert.throws(() => testConfig({ SERVER_TLS: "on" }), /SERVER_TLS must be one of off, self-signed/);
});

test("tls: with a certificate the server speaks HTTPS only, and WebSockets work over it", async () => {
  const tls = await createSelfSignedCertificate();
  const server = await startTestServer({ config: testConfig({ SERVER_TLS: "self-signed" }), tls });
  try {
    assert.match(server.httpUrl, /^https:/);
    const health = await get(`${server.httpUrl}/healthz`);
    assert.equal(health.status, 200);
    assert.deepEqual(JSON.parse(health.body), { status: "ok" });
    assert.ok(["TLSv1.2", "TLSv1.3"].includes(health.protocol));
    assert.equal(health.peerCertificate.fingerprint256, tls.fingerprint256);

    // A client that checks certificates refuses it (it is not from a certificate authority).
    await assert.rejects(get(`${server.httpUrl}/healthz`, { insecure: false }), { code: "DEPTH_ZERO_SELF_SIGNED_CERT" });
    // Plain HTTP on the same port gets no answer from the application.
    await assert.rejects(get(`http://127.0.0.1:${server.port}/healthz`));

    const { messages, code } = await runClient(server.wsUrl, [auth(), start("nova"), novaEvent("sessionStart"), end()], { rejectUnauthorized: false });
    assert.equal(code, 1000);
    assert.equal(messages[0].type, "ready");
    assert.deepEqual(JSON.parse(messages[1].binary.toString()), { event: { sessionStart: {} } });
  } finally {
    await server.close();
  }
});

test("tls: without a certificate the server still speaks plain HTTP", async () => {
  const server = await startTestServer();
  try {
    assert.match(server.httpUrl, /^http:/);
    assert.equal((await get(`${server.httpUrl}/healthz`)).status, 200);
  } finally {
    await server.close();
  }
});
