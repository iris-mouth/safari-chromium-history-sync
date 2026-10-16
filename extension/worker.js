import { createChromeGenerationStore } from "./chrome_generation_store.js";
import { PROTOCOL_VERSION, isReceipt, isWebUrl } from "./protocol.js";
import { createSyncController } from "./sync_controller.js";
import {
  hasPendingImport,
  hasVisitNewerThan,
  dirtyVisitDetails,
  importedVisitEvidence,
  orderedRecentVisits,
  unseenVisitsAfterMarker,
  visitSort,
} from "./visit_resolution.js";

const HOST = "io.github.irismouth.safari_chromium_history_sync";
const RESOLVE_ALARM = "resolve-browser-history";
const EXCHANGE_ALARM = "exchange-history";
const RUNTIME_KEY = "browser_runtime_v1";
const EVIDENCE_DELAYS = [1_000, 3_000, 8_000, 18_000, 30_000];
const REMOVAL_BATCHES_PER_EXCHANGE = 8;
const controller = createSyncController({
  store: createChromeGenerationStore(chrome.storage.local),
});

let serial = Promise.resolve();
function exclusively(work) {
  const result = serial.then(work);
  serial = result.catch(() => {});
  return result;
}

function browserFamily() {
  return navigator.userAgent.includes("Edg/") ? "edge" : "chrome";
}

async function runtimeState() {
  const stored = (await chrome.storage.local.get(RUNTIME_KEY))[RUNTIME_KEY];
  if (stored?.profileId) return stored;
  const created = {
    profileId: `${browserFamily()}:${crypto.randomUUID()}`,
    dirtyUrls: {},
    visitMarkers: {},
    pendingEvidence: {},
  };
  await chrome.storage.local.set({ [RUNTIME_KEY]: created });
  return created;
}

async function saveRuntime(state) {
  for (const [url, observedAt] of Object.entries(state.cloudOwnedUrls ?? {})) {
    if (observedAt < Date.now() - 7 * 24 * 60 * 60 * 1_000) delete state.cloudOwnedUrls[url];
  }
  await chrome.storage.local.set({ [RUNTIME_KEY]: state });
}

async function markDirty(item) {
  if (!isWebUrl(item?.url)) return;
  const state = await runtimeState();
  state.dirtyUrls[item.url] = dirtyVisitDetails(item);
  await saveRuntime(state);
}

async function resolveDirtyVisits() {
  const state = await runtimeState();
  for (const url of Object.keys(state.dirtyUrls)) {
    if (hasPendingImport(state.pendingEvidence, url)) continue;
    // A persisted import marker may be older than the bounded outcome-evidence window.
    const visits = [...await chrome.history.getVisits({ url })].sort(visitSort);
    const marker = state.visitMarkers[url];
    const dirty = state.dirtyUrls[url];
    const title = dirty && typeof dirty === "object" ? dirty.title : undefined;
    const unseen = unseenVisitsAfterMarker(visits, marker);
    for (const visit of unseen.reverse()) {
      await controller.browserExchange({
        version: PROTOCOL_VERSION,
        operation: "publish",
        profileId: state.profileId,
        events: [{
          eventId: crypto.randomUUID(),
          sourceKey: `${url}\n${visit.visitId}`,
          url,
          ...(title ? { title } : {}),
          visitId: String(visit.visitId),
        }],
      });
    }
    if (visits[0]) state.visitMarkers[url] = String(visits[0].visitId);
    delete state.dirtyUrls[url];
  }
  await saveRuntime(state);
}

function sendNative(message) {
  return chrome.runtime.sendNativeMessage(HOST, {
    ...message,
    browserFamily: browserFamily(),
    extensionVersion: chrome.runtime.getManifest().version,
    capabilities: ["cloud-delivery-v1"],
  });
}

function isCancelled(response) {
  return response?.type === "error" && response.code === "CLOUD_DELIVERY_CANCELLED";
}

async function pushBrowserPage(state) {
  const page = await controller.browserExchange({
    version: PROTOCOL_VERSION,
    operation: "pull",
    stream: "browserToSafari",
    profileId: state.profileId,
    afterSequence: 0,
    limit: 128,
  });
  if (page.type !== "page" || page.events.length === 0) return;
  const events = [];
  let pageBytes = 1_024;
  for (const event of page.events) {
    const size = new TextEncoder().encode(JSON.stringify(event)).length + 1;
    if (pageBytes + size > 512 * 1024) {
      if (!events.length) throw new Error("History event exceeds native transport limit");
      break;
    }
    events.push(event);
    pageBytes += size;
  }
  const response = await sendNative({
    version: PROTOCOL_VERSION,
    operation: "publish",
    stream: "browserToSafari",
    profileId: state.profileId,
    events,
  });
  if (response?.type === "receipt" && Number.isSafeInteger(response.throughSequence)) {
    await controller.browserExchange({
      version: PROTOCOL_VERSION,
      operation: "ack",
      stream: "browserToSafari",
      profileId: state.profileId,
      throughSequence: response.throughSequence,
    });
  }
}

async function recentVisits(url) {
  return orderedRecentVisits(await chrome.history.getVisits({ url }));
}

async function applySafariPage(state, page) {
  const event = page.events?.[0];
  if (!event || !isWebUrl(event.url)) return;
  const preVisitIds = (await recentVisits(event.url)).map((visit) => String(visit.visitId));
  const requestedAt = Date.now();
  state.pendingEvidence[event.eventId] = {
    ...event,
    requestedAt,
    preVisitIds,
    attempt: 1,
    deliveryAttempt: 1,
    dueAt: requestedAt + EVIDENCE_DELAYS[0],
  };
  state.cloudOwnedUrls ??= {};
  state.cloudOwnedUrls[event.url] = requestedAt;
  // Persist the request intent before invoking the non-idempotent browser writer.
  await saveRuntime(state);
  try {
    await chrome.history.addUrl({ url: event.url });
  } catch {
    // A rejected request is still resolved by fresh history evidence below.
  }
  if (Object.keys(state.pendingEvidence).length) {
    setTimeout(() => exclusively(() => verifyEvidence()).catch(console.error), 1_000);
  }
}

async function pullSafariPage(state) {
  if (Object.keys(state.pendingEvidence).length) return;
  const page = await sendNative({
    version: PROTOCOL_VERSION,
    operation: "pull",
    stream: "safariToBrowser",
    profileId: state.profileId,
    afterSequence: 0,
    limit: 128,
  });
  if (page?.type === "page") {
    state.agentCloudTracking = page.capabilities?.includes("cloud-delivery-v1") === true;
    await saveRuntime(state);
    if (state.agentCloudTracking && state.removalEvents?.length) {
      // Negotiation may have just enabled cancellation reporting. Discard this
      // page and fetch it again only after the Agent has processed the cutoffs.
      await reportRemovals(state);
      return;
    }
    await applySafariPage(state, page);
  }
}

export async function verifyEvidence() {
  const state = await runtimeState();
  if (!await reportRemovals(state)) return;
  const now = Date.now();
  for (const [eventId, pending] of Object.entries(state.pendingEvidence)) {
    if (pending.dueAt > now && !pending.localReceipt && !pending.removed) continue;
    const allVisits = await chrome.history.getVisits({ url: pending.url });
    const visits = orderedRecentVisits(allVisits);
    const evidence = pending.localReceipt
      ? allVisits.find((visit) => String(visit.visitId) === pending.localReceipt.visitId
        && visit.visitTime === pending.localReceipt.visitTime)
      : importedVisitEvidence(visits, pending);
    if (pending.removed || (pending.localReceipt && !evidence)) {
      pending.removed = true;
      await saveRuntime(state);
      const response = await sendNative(state.agentCloudTracking ? {
        version: PROTOCOL_VERSION, operation: "outcome", profileId: state.profileId,
        eventId, outcome: "LOCAL_REMOVED",
      } : {
        version: PROTOCOL_VERSION, operation: "ack", stream: "safariToBrowser",
        profileId: state.profileId, throughSequence: pending.sequence,
      });
      if (isCancelled(response) || isReceipt(response, state.agentCloudTracking ? "RECOVERY_RECORDED" : "ACKNOWLEDGED")) {
        delete state.pendingEvidence[eventId];
      }
      continue;
    }
    if (evidence) {
      state.visitMarkers[pending.url] = String(evidence.visitId);
      if (!hasVisitNewerThan(allVisits, evidence)) delete state.dirtyUrls[pending.url];
      pending.localReceipt = {
        eventId, sequence: pending.sequence,
        visitId: String(evidence.visitId), visitTime: evidence.visitTime,
      };
      // Keep both the exact receipt and echo marker across a lost ACK response/restart.
      await saveRuntime(state);
      const response = await sendNative({
        version: PROTOCOL_VERSION,
        operation: "ack",
        stream: "safariToBrowser",
        profileId: state.profileId,
        throughSequence: pending.sequence,
        ...(state.agentCloudTracking ? { localReceipts: [pending.localReceipt] } : {}),
      });
      if (isReceipt(response, "ACKNOWLEDGED") || isCancelled(response)) delete state.pendingEvidence[eventId];
    } else if (pending.attempt < EVIDENCE_DELAYS.length) {
      pending.attempt += 1;
      pending.dueAt = pending.requestedAt + EVIDENCE_DELAYS[pending.attempt - 1];
    } else if (pending.deliveryAttempt < 2) {
      // Re-read the exact stream position before another non-idempotent write.
      // Rebind/removal can cancel an intent while its first evidence cycle is pending.
      const page = await sendNative({
        version: PROTOCOL_VERSION, operation: "pull", stream: "safariToBrowser",
        profileId: state.profileId, afterSequence: pending.sequence - 1, limit: 1,
      });
      if (page?.type !== "page" || !Array.isArray(page.events)) continue;
      if (!page.events.some((event) => event.eventId === eventId
        && event.sequence === pending.sequence && event.url === pending.url)) {
        delete state.pendingEvidence[eventId];
        continue;
      }
      state.agentCloudTracking = page.capabilities?.includes("cloud-delivery-v1") === true;
      const freshVisits = await recentVisits(pending.url);
      if (importedVisitEvidence(freshVisits, pending)) continue;
      pending.preVisitIds = freshVisits.map((visit) => String(visit.visitId));
      pending.deliveryAttempt = 2;
      pending.attempt = 1;
      pending.requestedAt = now;
      pending.dueAt = now + EVIDENCE_DELAYS[0];
      await saveRuntime(state);
      try {
        await chrome.history.addUrl({ url: pending.url });
      } catch {
        // The following evidence cycle decides the outcome after a rejected call.
      }
    } else {
      const response = await sendNative({
        version: PROTOCOL_VERSION,
        operation: "outcome",
        profileId: state.profileId,
        eventId,
        outcome: "FINALIZED_UNCONFIRMED",
      });
      if (isReceipt(response, "RECOVERY_RECORDED") || isCancelled(response)) delete state.pendingEvidence[eventId];
    }
  }
  await saveRuntime(state);
}

async function recordRemoval(details, removedAt) {
  const state = await runtimeState();
  state.removalEvents ??= [];
  const urls = new Set(details.urls ?? []);
  for (const pending of Object.values(state.pendingEvidence)) {
    if (pending.requestedAt <= removedAt && (details.allHistory || urls.has(pending.url))) pending.removed = true;
  }
  if (details.allHistory) {
    state.removalEvents = [{ all: true, urls: [], removedAt }];
    state.visitMarkers = {};
    state.dirtyUrls = {};
    state.cloudOwnedUrls = {};
  } else {
    // Only the Agent knows every reserved queued/recovery URL, including events
    // beyond the first item in a fetched page. It filters these against its journal.
    let batch = [];
    let bytes = 1024;
    for (const url of urls) {
      if (!isWebUrl(url)) continue;
      const size = new TextEncoder().encode(JSON.stringify(url)).length + 1;
      if (batch.length === 128 || bytes + size > 512 * 1024) {
        state.removalEvents.push({ all: false, urls: batch, removedAt });
        batch = [];
        bytes = 1024;
      }
      batch.push(url);
      bytes += size;
    }
    if (batch.length) state.removalEvents.push({ all: false, urls: batch, removedAt });
    for (const url of urls) {
      delete state.visitMarkers[url];
      delete state.dirtyUrls[url];
      if (state.cloudOwnedUrls) delete state.cloudOwnedUrls[url];
    }
  }
  await saveRuntime(state);
}

async function reportRemovals(state) {
  if (!state.agentCloudTracking) return true;
  // Bound each turn's IPC work, but never let another writer overtake any
  // remaining cancellation batch, including a failed or lost response.
  for (let sent = 0; sent < REMOVAL_BATCHES_PER_EXCHANGE && state.removalEvents?.length; sent++) {
    const removal = state.removalEvents[0];
    const response = await sendNative({
      version: PROTOCOL_VERSION, operation: "cloudRemoval", profileId: state.profileId,
      allHistoryRemoved: removal.all, removedURLs: removal.urls, removedAt: removal.removedAt,
    });
    if (!isReceipt(response, "REMOVAL_RECORDED")) return false;
    state.removalEvents.shift();
    await saveRuntime(state);
  }
  return !state.removalEvents?.length;
}

export async function exchange() {
  const state = await runtimeState();
  if (!await reportRemovals(state)) return;
  await resolveDirtyVisits();
  await verifyEvidence();
  await pushBrowserPage(state);
  // The evidence/removal helpers persist a fresh state; don't overwrite it with the old snapshot.
  await pullSafariPage(await runtimeState());
}

chrome.history.onVisited.addListener((item) => {
  return exclusively(() => markDirty(item)).catch(console.error);
});
chrome.history.onVisitRemoved.addListener((details) => {
  const removedAt = Date.now();
  return exclusively(() => recordRemoval(details, removedAt)).catch(console.error);
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RESOLVE_ALARM || alarm.name === EXCHANGE_ALARM) {
    exclusively(exchange).catch(console.error);
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(RESOLVE_ALARM, { periodInMinutes: 0.5 });
  chrome.alarms.create(EXCHANGE_ALARM, { periodInMinutes: 1 });
  exclusively(exchange).catch(console.error);
});
chrome.runtime.onStartup.addListener(() => exclusively(exchange).catch(console.error));
