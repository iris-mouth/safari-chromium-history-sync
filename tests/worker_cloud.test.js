import test from "node:test";
import assert from "node:assert/strict";

let instance = 0;
const runtimeKey = "browser_runtime_v1";

async function harness(t, { capabilities = ["cloud-delivery-v1"], failAck = false, failAdd = false,
  failIntent = false, noImport = false, cancelAck = false } = {}) {
  const stored = {};
  const listeners = {};
  const requests = [];
  const visits = new Map();
  const event = { eventId: "safari-event", sequence: 1, url: "https://example.com/from-safari" };
  let complete = noImport;
  let adds = 0;
  const originalChrome = globalThis.chrome;
  const originalTimeout = globalThis.setTimeout;
  const timers = [];
  globalThis.setTimeout = (...args) => {
    const timer = originalTimeout(...args);
    timer.unref();
    timers.push(timer);
    return timer;
  };
  t.after(() => {
    for (const timer of timers) clearTimeout(timer);
    globalThis.setTimeout = originalTimeout;
    globalThis.chrome = originalChrome;
  });
  globalThis.chrome = {
    storage: { local: {
      async get(key) { return { [key]: structuredClone(stored[key]) }; },
      async set(values) {
        if (failIntent && values[runtimeKey]?.pendingEvidence?.[event.eventId]) {
          throw new Error("intent storage unavailable");
        }
        Object.assign(stored, structuredClone(values));
      },
      async remove(key) { delete stored[key]; },
    } },
    history: {
      onVisited: { addListener(callback) { listeners.visited = callback; } },
      onVisitRemoved: { addListener(callback) { listeners.removed = callback; } },
      async getVisits({ url }) { return structuredClone(visits.get(url) ?? []); },
      async addUrl({ url }) {
        assert.ok(stored[runtimeKey].pendingEvidence[event.eventId], "durable intent precedes addUrl");
        adds++;
        visits.set(url, [...(visits.get(url) ?? []), { visitId: String(adds), visitTime: Date.now() }]);
        if (failAdd) throw new Error("accepted write, rejected response");
      },
    },
    runtime: {
      getManifest() { return { version: "6.0" }; },
      onInstalled: { addListener() {} }, onStartup: { addListener() {} },
      async sendNativeMessage(host, message) {
        requests.push(structuredClone(message));
        if (message.operation === "pull") {
          return { type: "page", stream: "safariToBrowser", events: complete ? [] : [event],
            hasMore: false, ...(capabilities ? { capabilities } : {}) };
        }
        if (message.operation === "ack") {
          complete = true;
          if (cancelAck) return { type: "error", code: "CLOUD_DELIVERY_CANCELLED" };
          if (failAck) { failAck = false; throw new Error("ACK response lost"); }
          return { type: "receipt", status: "ACKNOWLEDGED", throughSequence: message.throughSequence };
        }
        if (message.operation === "cloudRemoval") return { type: "receipt", status: "REMOVAL_RECORDED" };
        if (message.operation === "outcome") {
          complete = true;
          return { type: "receipt", status: "RECOVERY_RECORDED" };
        }
        return { type: "receipt", status: "ACCEPTED", throughSequence: message.events?.at(-1)?.sequence ?? 0 };
      },
    },
    alarms: { onAlarm: { addListener() {} }, create() {} },
  };
  async function restart() { return import(`../extension/worker.js?cloud-test=${++instance}`); }
  const worker = await restart();
  return { worker, restart, event, stored, visits, requests, listeners,
    get adds() { return adds; },
    due() { stored[runtimeKey].pendingEvidence[event.eventId].dueAt = 0; },
  };
}

test("worker persists exact local evidence before ACK and retries a lost ACK after restart without another visit", async (t) => {
  const h = await harness(t, { failAck: true });
  await h.worker.exchange();
  h.due();
  await assert.rejects(h.worker.verifyEvidence(), /ACK response lost/);
  const saved = structuredClone(h.stored[runtimeKey].pendingEvidence[h.event.eventId].localReceipt);
  assert.equal(saved.visitId, "1");
  assert.equal(h.stored[runtimeKey].visitMarkers[h.event.url], "1");
  const restarted = await h.restart();
  await restarted.verifyEvidence();
  assert.equal(h.adds, 1);
  const acks = h.requests.filter((request) => request.operation === "ack");
  assert.equal(acks.length, 2);
  assert.deepEqual(acks[0].localReceipts, [saved]);
  assert.deepEqual(acks[1].localReceipts, [saved]);
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
});

test("worker reports explicit history removal and never retries the removed import", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.visits.set(h.event.url, []);
  await h.listeners.removed({ allHistory: false, urls: [h.event.url] });
  await h.worker.exchange();
  assert.equal(h.adds, 1);
  assert.deepEqual(h.requests.find((request) => request.operation === "cloudRemoval").removedURLs, [h.event.url]);
  assert.equal(h.requests.find((request) => request.operation === "outcome").outcome, "LOCAL_REMOVED");
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
});

test("worker resolves an ambiguous addUrl failure by querying evidence", async (t) => {
  const h = await harness(t, { failAdd: true });
  await h.worker.exchange();
  h.due();
  await h.worker.verifyEvidence();
  assert.equal(h.adds, 1);
  assert.equal(h.requests.find((request) => request.operation === "ack").localReceipts[0].visitId, "1");
});

test("an account-rebound probe releases the worker without undoing or repeating its local visit", async (t) => {
  const h = await harness(t, { cancelAck: true });
  await h.worker.exchange();
  h.due();
  await h.worker.verifyEvidence();
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
  assert.equal(h.stored[runtimeKey].visitMarkers[h.event.url], "1");
  await h.worker.exchange();
  assert.equal(h.adds, 1);
});

test("worker does not invoke the writer when the durable intent cannot be saved", async (t) => {
  const h = await harness(t, { failIntent: true });
  await assert.rejects(h.worker.exchange(), /intent storage unavailable/);
  assert.equal(h.adds, 0);
});

test("worker negotiates cloud receipts while retaining the old Agent local ACK format", async (t) => {
  const h = await harness(t, { capabilities: null });
  await h.worker.exchange();
  h.due();
  await h.worker.verifyEvidence();
  assert.equal(h.requests.find((request) => request.operation === "ack").localReceipts, undefined);
  assert.equal(h.stored[runtimeKey].agentCloudTracking, false);
});

test("durable import markers suppress echoes but allow a later real visit to the same URL", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.due();
  await h.worker.verifyEvidence();
  await h.listeners.visited({ url: h.event.url });
  await h.worker.exchange();
  assert.equal(h.requests.filter((request) => request.operation === "publish").length, 0);
  h.visits.get(h.event.url).push({ visitId: "2", visitTime: Date.now() + 10 });
  await h.listeners.visited({ url: h.event.url });
  await h.worker.exchange();
  const published = h.requests.filter((request) => request.operation === "publish");
  assert.equal(published.length, 1);
  assert.equal(published[0].events[0].url, h.event.url);
  assert.equal(h.adds, 1);
});

test("large browser pages fit the authenticated native transport and leave the remaining prefix queued", async (t) => {
  const h = await harness(t, { noImport: true });
  for (let index = 0; index < 100; index++) {
    const url = `https://example.com/${index}/` + "a".repeat(6000);
    h.visits.set(url, [{ visitId: String(index + 1), visitTime: Date.now() }]);
    await h.listeners.visited({ url });
  }
  await h.worker.exchange();
  const first = h.requests.find((request) => request.operation === "publish");
  assert.ok(new TextEncoder().encode(JSON.stringify(first)).length < 512 * 1024);
  assert.ok(first.events.length > 0 && first.events.length < 100);
  await h.worker.exchange();
  await h.worker.exchange();
  const pages = h.requests.filter((request) => request.operation === "publish");
  assert.equal(pages.flatMap((page) => page.events).length, 100);
  assert.equal(new Set(pages.flatMap((page) => page.events.map((event) => event.eventId))).size, 100);
});
