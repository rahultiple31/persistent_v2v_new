// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * Unbuffered-latency FIFO exposed as an async iterable: a pushed item is handed straight to a waiting
 * consumer, so audio frames reach the AWS SDK without an extra tick of delay.
 */
export class AsyncQueue {
  #items = [];
  #waiters = [];
  #closed = false;
  #maxItems;

  constructor({ maxItems = Infinity } = {}) {
    this.#maxItems = maxItems;
  }

  get closed() {
    return this.#closed;
  }

  /** Returns false when the queue is closed or full (the consumer has fallen behind). */
  push(item) {
    if (this.#closed) return false;
    const waiter = this.#waiters.shift();
    if (waiter) {
      waiter({ value: item, done: false });
      return true;
    }
    if (this.#items.length >= this.#maxItems) return false;
    this.#items.push(item);
    return true;
  }

  /** Ends iteration once the buffered items are consumed. */
  close() {
    if (this.#closed) return;
    this.#closed = true;
    for (const waiter of this.#waiters.splice(0)) waiter({ value: undefined, done: true });
  }

  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this.#items.length) return Promise.resolve({ value: this.#items.shift(), done: false });
        if (this.#closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => this.#waiters.push(resolve));
      },
      return: () => {
        this.close();
        this.#items = [];
        return Promise.resolve({ value: undefined, done: true });
      },
    };
  }
}
