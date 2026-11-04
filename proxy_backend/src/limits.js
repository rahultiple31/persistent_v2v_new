// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Per-task limits. With several tasks behind the load balancer each task enforces its own share;
// these exist to stop one user or a runaway client from exhausting a task, not as a billing control.

/** Caps open WebSocket connections in total and per user. */
export class ConnectionLimiter {
  #maxTotal;
  #maxPerUser;
  #total = 0;
  #perUser = new Map();

  constructor({ maxTotal, maxPerUser }) {
    this.#maxTotal = maxTotal;
    this.#maxPerUser = maxPerUser;
  }

  get total() {
    return this.#total;
  }

  tryAcquireConnection() {
    if (this.#total >= this.#maxTotal) return false;
    this.#total++;
    return true;
  }

  releaseConnection() {
    this.#total = Math.max(0, this.#total - 1);
  }

  tryAcquireUser(userId) {
    const count = this.#perUser.get(userId) ?? 0;
    if (count >= this.#maxPerUser) return false;
    this.#perUser.set(userId, count + 1);
    return true;
  }

  releaseUser(userId) {
    const count = (this.#perUser.get(userId) ?? 0) - 1;
    if (count > 0) this.#perUser.set(userId, count);
    else this.#perUser.delete(userId);
  }
}

/** Token bucket per key, refilled continuously at `perMinute`. */
export class RateLimiter {
  #capacity;
  #refillPerMs;
  #buckets = new Map();
  #now;

  constructor({ perMinute, now = () => Date.now() }) {
    this.#capacity = perMinute;
    this.#refillPerMs = perMinute / 60_000;
    this.#now = now;
  }

  tryTake(key) {
    const now = this.#now();
    const bucket = this.#buckets.get(key) ?? { tokens: this.#capacity, updatedAt: now };
    bucket.tokens = Math.min(this.#capacity, bucket.tokens + (now - bucket.updatedAt) * this.#refillPerMs);
    bucket.updatedAt = now;
    this.#buckets.set(key, bucket);
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  /** Drops buckets that have refilled completely, so the map does not grow without bound. */
  prune() {
    const now = this.#now();
    for (const [key, bucket] of this.#buckets) {
      if (bucket.tokens + (now - bucket.updatedAt) * this.#refillPerMs >= this.#capacity) this.#buckets.delete(key);
    }
  }
}
