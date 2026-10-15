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
} from "./visit_resolution.js";

const HOST = "io.github.irismouth.safari_chromium_history_sync";
const RESOLVE_ALARM = "resolve-browser-history";
const EXCHANGE_ALARM = "exchange-history";
const RUNTIME_KEY = "browser_runtime_v1";
const EVIDENCE_DELAYS = [1_000, 3_000, 8_000, 18_000, 30_000];
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
    const visits = orderedRecentVisits(await chrome.history.getVisits({ url }));
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
    await applySafariPage(state, page);
  }
}

export async function verifyEvidence() {
  const state = await runtimeState();
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
      if (!hasVisitNewerThan(visits, evidence)) delete state.dirtyUrls[pending.url];
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
      pending.preVisitIds = (await recentVisits(pending.url))
        .map((visit) => String(visit.visitId));
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

async function recordRemoval(details) {
  const state = await runtimeState();
  state.removalEvents ??= [];
  const removedAt = Date.now();
  const urls = new Set(details.urls ?? []);
  const pendingUrls = new Set(Object.values(state.pendingEvidence).map((entry) => entry.url));
  for (const pending of Object.values(state.pendingEvidence)) {
    if (details.allHistory || urls.has(pending.url)) pending.removed = true;
  }
  if (details.allHistory) {
    state.removalEvents = [{ all: true, urls: [], removedAt }];
    state.visitMarkers = {};
    state.dirtyUrls = {};
    state.cloudOwnedUrls = {};
  } else {
    const owned = [...urls].filter((url) => state.cloudOwnedUrls?.[url] || pendingUrls.has(url));
    for (let offset = 0; offset < owned.length; offset += 128) {
      state.removalEvents.push({ all: false, urls: owned.slice(offset, offset + 128), removedAt });
    }
    for (const url of urls) {
      delete state.visitMarkers[url];
      delete state.dirtyUrls[url];
      if (state.cloudOwnedUrls) delete state.cloudOwnedUrls[url];
    }
  }
  await saveRuntime(state);
}

async function reportRemovals(state) {
  if (!state.agentCloudTracking) return;
  const removal = state.removalEvents?.[0];
  if (!removal) return;
  const response = await sendNative({
    version: PROTOCOL_VERSION, operation: "cloudRemoval", profileId: state.profileId,
    allHistoryRemoved: removal.all, removedURLs: removal.urls, removedAt: removal.removedAt,
  });
  if (isReceipt(response, "REMOVAL_RECORDED")) {
    state.removalEvents.shift();
    await saveRuntime(state);
  }
}

export async function exchange() {
  const state = await runtimeState();
  await reportRemovals(state);
  await resolveDirtyVisits();
  await verifyEvidence();
  await pushBrowserPage(state);
  // The evidence/removal helpers persist a fresh state; don't overwrite it with the old snapshot.
  await pullSafariPage(await runtimeState());
}

chrome.history.onVisited.addListener((item) => {
  return exclusively(() => markDirty(item)).catch(console.error);
});
chrome.history.onVisitRemoved.addListener((details) =>
  exclusively(() => recordRemoval(details)).catch(console.error));

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
