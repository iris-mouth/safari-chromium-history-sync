import assert from "node:assert/strict";
import test from "node:test";

import { createSyncController } from "../extension/sync_controller.js";
import { createChromeGenerationStore } from "../extension/chrome_generation_store.js";
import { isReceipt } from "../extension/protocol.js";

function memoryStore(initial = {}) {
  let value = structuredClone(initial);
  return {
    async load() { return structuredClone(value); },
    async replace(next) { value = structuredClone(next); },
  };
}

test("profile-switch errors are not mistaken for durable receipts", () => {
  assert.equal(isReceipt({ type: "receipt", status: "ACKNOWLEDGED" }, "ACKNOWLEDGED"), true);
  assert.equal(isReceipt({ type: "error", code: "PROFILE_NOT_ACTIVE" }, "ACKNOWLEDGED"), false);
  assert.equal(isReceipt(undefined, "RECOVERY_RECORDED"), false);
});

test("browserExchange rejects a message from another protocol version", async () => {
  const sync = createSyncController({ store: memoryStore() });

  const result = await sync.browserExchange({
    version: 2,
    operation: "pull",
    profileId: "edge:Default",
  });

  assert.deepEqual(result, {
    type: "error",
    code: "UNSUPPORTED_PROTOCOL",
    retryable: false,
  });
});

test("status contains queue health without local profile-switch state", async () => {
  const sync = createSyncController({ store: memoryStore() });

  assert.deepEqual(await sync.status(), {
    protocolVersion: 1,
    pendingBrowserToSafari: 0,
    pendingSafariToBrowser: 0,
    recoveryCount: 0,
    unrecoverableCount: 0,
  });
});

test("freeze acknowledgements are no longer part of the browser protocol", async () => {
  const sync = createSyncController({ store: memoryStore() });

  assert.deepEqual(await sync.browserExchange({
    version: 1,
    operation: "freezeAck",
    profileId: "edge:Default",
  }), {
    type: "error",
    code: "INVALID_OPERATION",
    retryable: false,
  });
});

test("browserExchange assigns durable increasing sequence numbers", async () => {
  const store = memoryStore();
  let sync = createSyncController({ store });

  const first = await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [{ eventId: "event-a", url: "https://example.com/a" }],
  });
  sync = createSyncController({ store });
  const second = await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [{ eventId: "event-b", url: "https://example.com/b" }],
  });

  assert.equal(first.accepted[0].sequence, 1);
  assert.equal(second.accepted[0].sequence, 2);
});

test("browserExchange rejects an invalid page without accepting its valid prefix", async () => {
  const store = memoryStore();
  const sync = createSyncController({ store });

  assert.equal((await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [
      { eventId: "valid-prefix", url: "https://example.com/valid" },
      { eventId: "invalid-suffix", url: "file:///private/data" },
    ],
  })).code, "INVALID_EVENT");

  const retry = await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [{ eventId: "valid-prefix", url: "https://example.com/valid" }],
  });
  assert.deepEqual(retry.accepted, [{ eventId: "valid-prefix", sequence: 1 }]);
});

test("browserExchange deduplicates a retried source event", async () => {
  const sync = createSyncController({ store: memoryStore() });
  const message = {
    version: 1,
    operation: "publish",
    profileId: "chrome:Default",
    events: [{ eventId: "same-event", url: "https://example.com/once" }],
  };

  assert.equal((await sync.browserExchange(message)).accepted.length, 1);
  assert.equal((await sync.browserExchange(message)).accepted.length, 0);
  assert.equal((await sync.status()).pendingBrowserToSafari, 1);
});

test("status survives a controller restart through immutable Chrome generations", async () => {
  const values = {};
  const chromeStorage = {
    async get(key) { return { [key]: structuredClone(values[key]) }; },
    async set(patch) { Object.assign(values, structuredClone(patch)); },
    async remove(key) { delete values[key]; },
  };
  const store = createChromeGenerationStore(chromeStorage);
  let sync = createSyncController({ store });
  await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Persistent",
    events: [{ eventId: "durable", url: "https://example.com/durable" }],
  });
  const firstGeneration = structuredClone(values.sync_state_generation_1);

  sync = createSyncController({ store });
  await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Persistent",
    events: [{ eventId: "durable-2", url: "https://example.com/still-durable" }],
  });

  assert.equal((await sync.status()).pendingBrowserToSafari, 2);
  assert.deepEqual(values.sync_state_generation_1, firstGeneration);
  assert.equal(values.sync_state_head, 2);
});

test("browser-to-Safari pages remain pending until a cumulative receipt", async () => {
  const sync = createSyncController({ store: memoryStore() });
  await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "chrome:Default",
    events: [{ eventId: "visit", url: "https://example.com/visit" }],
  });

  const page = await sync.browserExchange({
    version: 1,
    operation: "pull",
    stream: "browserToSafari",
    profileId: "chrome:Default",
  });
  assert.deepEqual(page.events.map(({ eventId, sequence, url }) => ({ eventId, sequence, url })), [
    { eventId: "visit", sequence: 1, url: "https://example.com/visit" },
  ]);
  assert.equal((await sync.status()).pendingBrowserToSafari, 1);

  await sync.browserExchange({
    version: 1,
    operation: "ack",
    stream: "browserToSafari",
    profileId: "chrome:Default",
    throughSequence: 1,
  });
  assert.equal((await sync.status()).pendingBrowserToSafari, 0);
});

test("a resolver replay with a new random event ID does not duplicate a browser visit", async () => {
  const sync = createSyncController({ store: memoryStore() });
  const base = {
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
  };
  await sync.browserExchange({ ...base, events: [{
    eventId: "random-a",
    sourceKey: "https://example.com\n42",
    url: "https://example.com",
  }] });
  const replay = await sync.browserExchange({ ...base, events: [{
    eventId: "random-b",
    sourceKey: "https://example.com\n42",
    url: "https://example.com",
  }] });

  assert.equal(replay.accepted.length, 0);
  assert.equal((await sync.status()).pendingBrowserToSafari, 1);
});

test("queues and receipts are isolated by profile", async () => {
  const sync = createSyncController({ store: memoryStore() });
  await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [{ eventId: "edge-event", url: "https://example.com/edge" }],
  });
  await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "chrome:Default",
    events: [{ eventId: "chrome-event", url: "https://example.com/chrome" }],
  });

  const chromePage = await sync.browserExchange({
    version: 1,
    operation: "pull",
    stream: "browserToSafari",
    profileId: "chrome:Default",
  });
  assert.deepEqual(chromePage.events.map((event) => event.eventId), ["chrome-event"]);

  await sync.browserExchange({
    version: 1,
    operation: "ack",
    stream: "browserToSafari",
    profileId: "chrome:Default",
    throughSequence: chromePage.events[0].sequence,
  });

  const edgePage = await sync.browserExchange({
    version: 1,
    operation: "pull",
    stream: "browserToSafari",
    profileId: "edge:Default",
  });
  assert.deepEqual(edgePage.events.map((event) => event.eventId), ["edge-event"]);
  assert.equal((await sync.status()).pendingBrowserToSafari, 1);
});

test("deduplication keys are isolated by profile", async () => {
  const sync = createSyncController({ store: memoryStore() });
  const event = {
    eventId: "same-event",
    sourceKey: "https://example.com\n42",
    url: "https://example.com",
  };

  const edge = await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "edge:Default",
    events: [event],
  });
  const chrome = await sync.browserExchange({
    version: 1,
    operation: "publish",
    profileId: "chrome:Default",
    events: [event],
  });

  assert.equal(edge.accepted.length, 1);
  assert.equal(chrome.accepted.length, 1);
});

test("version 1 state migrates queues without retaining switch state", async () => {
  const sync = createSyncController({ store: memoryStore({
    schemaVersion: 1,
    generation: 3,
    activeProfileId: "edge:Legacy",
    stagingProfileId: "chrome:Ignored",
    switchState: "AWAITING_FREEZE_ACK",
    nextBrowserToSafariSequence: 2,
    nextSafariToBrowserSequence: 1,
    browserToSafari: [{
      sequence: 1,
      eventId: "legacy-event",
      url: "https://example.com/legacy",
      acked: false,
    }],
    safariToBrowser: [],
    seenBrowserEventIds: ["legacy-event"],
    seenBrowserSourceKeys: [],
    recoveryCount: 0,
    unrecoverableCount: 0,
  }) });

  const page = await sync.browserExchange({
    version: 1,
    operation: "pull",
    stream: "browserToSafari",
    profileId: "edge:Legacy",
  });
  assert.deepEqual(page.events.map((event) => event.eventId), ["legacy-event"]);
  assert.deepEqual(await sync.status(), {
    protocolVersion: 1,
    pendingBrowserToSafari: 1,
    pendingSafariToBrowser: 0,
    recoveryCount: 0,
    unrecoverableCount: 0,
  });
});
