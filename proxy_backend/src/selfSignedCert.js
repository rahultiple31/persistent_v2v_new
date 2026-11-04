// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// SERVER_TLS=self-signed: HTTPS between the load balancer and this task. The load balancer encrypts with
// the task's certificate but does not check it (AWS: "The load balancer does not validate these
// certificates. Therefore, you can use self-signed certificates"), so each task makes its own key and
// certificate at start-up. Nothing is stored or downloaded, and the key never leaves the task's memory.
//
// Node has no API that writes a certificate, so this file encodes the few DER (ASN.1) structures an X.509
// certificate needs. RSA 2048 + SHA-256: every load balancer security policy accepts it.
import { generateKeyPair, randomBytes, sign, X509Certificate } from "node:crypto";
import { promisify } from "node:util";

const generateKeyPairAsync = promisify(generateKeyPair);
const VALID_DAYS = 365; // not checked by the load balancer; a new task makes a new certificate
const COMMON_NAME = "v2v-proxy";

function der(tag, ...parts) {
  const body = Buffer.concat(parts);
  if (body.length < 0x80) return Buffer.concat([Buffer.from([tag, body.length]), body]);
  const length = [];
  for (let n = body.length; n > 0; n = Math.floor(n / 256)) length.unshift(n % 256);
  return Buffer.concat([Buffer.from([tag, 0x80 | length.length, ...length]), body]);
}

const sequence = (...parts) => der(0x30, ...parts);
const set = (...parts) => der(0x31, ...parts);
const NULL = Buffer.from([0x05, 0x00]);

function oid(dotted) {
  const [first, second, ...rest] = dotted.split(".").map(Number);
  const bytes = [40 * first + second];
  for (const n of rest) {
    const chunk = [n % 128];
    for (let v = Math.floor(n / 128); v > 0; v = Math.floor(v / 128)) chunk.unshift((v % 128) | 0x80);
    bytes.push(...chunk);
  }
  return der(0x06, Buffer.from(bytes));
}

// YYMMDDHHMMSSZ: RFC 5280 requires UTCTime for dates up to 2049.
function utcTime(date) {
  const iso = date.toISOString(); // 2026-10-29T12:34:56.789Z
  const text = `${iso.slice(2, 4)}${iso.slice(5, 7)}${iso.slice(8, 10)}${iso.slice(11, 13)}${iso.slice(14, 16)}${iso.slice(17, 19)}Z`;
  return der(0x17, Buffer.from(text, "ascii"));
}

const name = (commonName) => sequence(set(sequence(oid("2.5.4.3"), der(0x0c, Buffer.from(commonName, "utf8")))));
const SHA256_WITH_RSA = sequence(oid("1.2.840.113549.1.1.11"), NULL);

function pem(label, body) {
  const lines = body.toString("base64").match(/.{1,64}/g);
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

/**
 * A new RSA key and a self-signed certificate for it, as PEM strings for https.createServer, plus the
 * certificate's SHA-256 fingerprint for the log.
 */
export async function createSelfSignedCertificate({ now = new Date(), commonName = COMMON_NAME } = {}) {
  const { publicKey, privateKey } = await generateKeyPairAsync("rsa", { modulusLength: 2048 });
  // A random positive serial number: first byte 0x40-0x7f, so it is never negative and needs no padding.
  const serial = randomBytes(16);
  serial[0] = (serial[0] & 0x3f) | 0x40;
  const notBefore = new Date(now.getTime() - 60 * 60_000); // an hour back, in case clocks differ
  const notAfter = new Date(now.getTime() + VALID_DAYS * 24 * 60 * 60_000);

  const tbsCertificate = sequence(
    der(0xa0, der(0x02, Buffer.from([2]))), // version 3
    der(0x02, serial),
    SHA256_WITH_RSA,
    name(commonName), // issuer = subject: self-signed
    sequence(utcTime(notBefore), utcTime(notAfter)),
    name(commonName),
    publicKey.export({ type: "spki", format: "der" })
  );
  const signature = sign("sha256", tbsCertificate, privateKey);
  const certificate = sequence(tbsCertificate, SHA256_WITH_RSA, der(0x03, Buffer.from([0]), signature));

  const cert = pem("CERTIFICATE", certificate);
  return {
    key: privateKey.export({ type: "pkcs8", format: "pem" }),
    cert,
    fingerprint256: new X509Certificate(cert).fingerprint256,
  };
}
