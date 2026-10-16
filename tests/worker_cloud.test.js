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

test("ACK recovery preserves all later visits when the saved receipt is outside the recent evidence window", async (t) => {
  const h = await harness(t, { failAck: true });
  await h.worker.exchange();
  h.due();
  await assert.rejects(h.worker.verifyEvidence(), /ACK response lost/);
  const time = h.visits.get(h.event.url)[0].visitTime;
  for (let id = 2; id <= 66; id++) {
    h.visits.get(h.event.url).push({ visitId: String(id), visitTime: time + id });
  }
  await h.listeners.visited({ url: h.event.url });
  const restarted = await h.restart();
  await restarted.verifyEvidence();
  assert.ok(h.stored[runtimeKey].dirtyUrls[h.event.url], "later visits remain dirty after ACK recovery");
  await restarted.exchange();
  const published = h.requests.filter((request) => request.operation === "publish");
  assert.equal(published.flatMap((page) => page.events).length, 65);
  assert.equal(h.adds, 1, "receipt recovery never repeats the imported visit");
});

test("a cancelled account probe is checked with the Agent before a second addUrl", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.visits.set(h.event.url, []);
  const pending = h.stored[runtimeKey].pendingEvidence[h.event.eventId];
  pending.attempt = 5;
  pending.deliveryAttempt = 1;
  pending.dueAt = 0;
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async (host, message) => {
    if (message.operation === "pull") {
      h.requests.push(structuredClone(message));
      return { type: "page", events: [], capabilities: ["cloud-delivery-v1"] };
    }
    return native(host, message);
  };
  await h.worker.verifyEvidence();
  assert.equal(h.adds, 1, "a removed old-binding event must not be inserted again");
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
});

for (const precedingRemovals of [0, 128, 1024]) {
test(`deleting a reserved URL after ${precedingRemovals} other removals cancels it before insertion`, async (t) => {
  const h = await harness(t);
  const second = { eventId: "queued-second", sequence: 2, url: "https://example.com/queued-second" };
  let queue = [h.event, second];
  h.visits.set(second.url, [{ visitId: "old", visitTime: Date.now() - 10000 }]);
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async (host, message) => {
    if (message.operation === "pull") {
      return { type: "page", events: structuredClone(queue), capabilities: ["cloud-delivery-v1"] };
    }
    if (message.operation === "ack") {
      queue = queue.filter((event) => event.sequence > message.throughSequence);
      return { type: "receipt", status: "ACKNOWLEDGED", throughSequence: message.throughSequence };
    }
    if (message.operation === "cloudRemoval") {
      queue = queue.filter((event) => !message.removedURLs.includes(event.url));
    }
    return native(host, message);
  };
  await h.worker.exchange();
  h.visits.set(second.url, []);
  const removed = Array.from({ length: precedingRemovals }, (_, index) => `https://example.com/removed-${index}`);
  removed.push(second.url);
  await h.listeners.removed({ allHistory: false, urls: removed });
  h.due();
  await h.worker.verifyEvidence();
  await h.worker.exchange();
  const removals = h.requests.filter((request) => request.operation === "cloudRemoval");
  assert.deepEqual(removals.flatMap((request) => request.removedURLs), removed);
  assert.deepEqual(h.stored[runtimeKey].removalEvents, []);
  assert.equal(h.adds, 1, "the deleted queued URL never reaches the writer");
});
}

test("removal cutoff is the notification time even when the worker queue is blocked", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  const originalNow = Date.now;
  t.after(() => { Date.now = originalNow; });
  const base = originalNow();
  let now = base;
  Date.now = () => now;
  let release;
  let entered;
  const gate = new Promise((resolve) => { release = resolve; });
  const began = new Promise((resolve) => { entered = resolve; });
  const get = chrome.storage.local.get;
  chrome.storage.local.get = async (key) => { entered(); await gate; return get(key); };
  const earlier = h.listeners.visited({ url: "https://example.com/queue-blocker" });
  await began;
  const removal = h.listeners.removed({ allHistory: false, urls: [h.event.url] });
  now = base + 1000;
  release();
  await earlier;
  await removal;
  await h.worker.exchange();
  assert.equal(h.requests.find((request) => request.operation === "cloudRemoval").removedAt, base);
});

test("an upgraded worker drains a legacy pending ACK before negotiating cloud tracking", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  delete h.stored[runtimeKey].agentCloudTracking;
  h.due();
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async (host, message) => {
    if (message.operation === "ack") {
      // A capable client may still ACK an untracked event from the previous Agent.
      assert.equal(message.localReceipts, undefined);
    }
    return native(host, message);
  };
  const restarted = await h.restart();
  await restarted.exchange();
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
  assert.equal(h.stored[runtimeKey].agentCloudTracking, true, "a subsequent pull negotiates the new receipt format");
  assert.equal(h.adds, 1);
});

test("a still-queued delivery retries, but Agent errors preserve it without another write", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.visits.set(h.event.url, []);
  const pending = h.stored[runtimeKey].pendingEvidence[h.event.eventId];
  pending.attempt = 5;
  pending.dueAt = 0;
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async () => ({ type: "error", code: "PROFILE_NOT_ACTIVE" });
  await h.worker.verifyEvidence();
  assert.equal(h.adds, 1);
  assert.ok(h.stored[runtimeKey].pendingEvidence[h.event.eventId]);
  chrome.runtime.sendNativeMessage = native;
  await h.worker.verifyEvidence();
  assert.equal(h.adds, 2);
  assert.equal(h.requests.at(-1).operation, "pull");
  assert.equal(h.requests.at(-1).afterSequence, h.event.sequence - 1);
  assert.equal(h.requests.at(-1).limit, 1);
  h.due();
  await h.worker.verifyEvidence();
  assert.deepEqual(h.stored[runtimeKey].pendingEvidence, {});
});

test("evidence arriving during retry authorization prevents a duplicate browser visit", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.visits.set(h.event.url, []);
  const pending = h.stored[runtimeKey].pendingEvidence[h.event.eventId];
  pending.attempt = 5;
  pending.dueAt = 0;
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async (host, message) => {
    if (message.operation === "pull") {
      h.visits.set(h.event.url, [{ visitId: "late-first-write", visitTime: Date.now() }]);
    }
    return native(host, message);
  };
  await h.worker.verifyEvidence();
  await h.worker.verifyEvidence();
  assert.equal(h.adds, 1);
  assert.equal(h.requests.find((request) => request.operation === "ack").localReceipts[0].visitId, "late-first-write");
});

test("removal notifications cover queued URLs in bounded native messages", async (t) => {
  const h = await harness(t, { noImport: true });
  await h.worker.exchange();
  const urls = Array.from({ length: 130 }, (_, index) => `https://example.com/${index}/` + "x".repeat(7000));
  await h.listeners.removed({ allHistory: false, urls });
  for (let page = 0; page < 3; page++) await h.worker.exchange();
  const removals = h.requests.filter((request) => request.operation === "cloudRemoval");
  assert.deepEqual(removals.flatMap((request) => request.removedURLs), urls);
  for (const removal of removals) {
    assert.ok(removal.removedURLs.length <= 128);
    assert.ok(new TextEncoder().encode(JSON.stringify(removal)).length < 512 * 1024);
  }
});

test("unacknowledged removal batches block exchanges and evidence retries until they are delivered", async (t) => {
  const h = await harness(t);
  await h.worker.exchange();
  h.visits.set(h.event.url, []);
  const pending = h.stored[runtimeKey].pendingEvidence[h.event.eventId];
  pending.attempt = 5;
  pending.dueAt = 0;
  await h.listeners.removed({ allHistory: false, urls: ["https://example.com/queued-elsewhere"] });
  const native = chrome.runtime.sendNativeMessage;
  chrome.runtime.sendNativeMessage = async (host, message) => message.operation === "cloudRemoval"
    ? { type: "error", code: "UNAVAILABLE" } : native(host, message);
  const pulls = h.requests.filter((request) => request.operation === "pull").length;
  await h.worker.verifyEvidence();
  await h.worker.exchange();
  assert.equal(h.adds, 1, "neither callback nor exchange may write past pending cancellations");
  assert.equal(h.requests.filter((request) => request.operation === "pull").length, pulls);
  assert.equal(h.stored[runtimeKey].removalEvents.length, 1);
  chrome.runtime.sendNativeMessage = native;
  await h.worker.exchange();
  assert.deepEqual(h.stored[runtimeKey].removalEvents, []);
  assert.equal(h.adds, 2, "a still-current retry resumes once cancellation reporting recovers");
});

test("initial capability negotiation reports old removals and refetches before writing a page", async (t) => {
  const h = await harness(t);
  await h.listeners.removed({ allHistory: false, urls: ["https://example.com/previous-removal"] });
  await h.worker.exchange();
  assert.equal(h.adds, 0, "a page fetched before cancellation reporting must not be applied");
  assert.deepEqual(h.requests.map((request) => request.operation), ["pull", "cloudRemoval"]);
  await h.worker.exchange();
  assert.equal(h.adds, 1);
  assert.deepEqual(h.requests.map((request) => request.operation), ["pull", "cloudRemoval", "pull"]);
});
