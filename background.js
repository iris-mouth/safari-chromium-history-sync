// v5.9: reconciliation loop plus popup/options status controls and per-visit history sync.
const HOST = "com.local.safari_bookmark_sync";
const CANON_BAR = "BAR";
const CANON_OTHER = "OTHER";
const SEND_INTERVAL_MS = 10;
const TICK_ALARM = "sync-tick";
const TICK_PERIOD_MIN = 0.5;
const HISTORY_LIMIT = 50;
const HISTORY_RECENT_MAX_RESULTS = 5000;
const HISTORY_BACKFILL_PAGE_SIZE = 2000;
const HISTORY_SCAN_OVERLAP_MS = 2 * 60 * 1000;
const SAFARI_HISTORY_ECHO_WINDOW_MS = 15000;
const HISTORY_BACKFILLED_URL_KEYS_LIMIT = 50000;

const STORAGE_KEYS = {
  SETTINGS: "sync_settings",
  STATUS: "sync_status",
  HISTORY: "sync_activity",
  CHROME_SNAPSHOT: "chrome_snapshot",
  FOLDER_ORDER: "folder_order",
  HISTORY_RECENT_CURSOR: "history_recent_cursor",
  HISTORY_BACKFILL_BEFORE: "history_backfill_before",
  HISTORY_BACKFILL_DONE: "history_backfill_done",
  HISTORY_BACKFILLED_URL_KEYS: "history_backfilled_url_keys",
};

const DEFAULT_SETTINGS = Object.freeze({
  paused: false,
  direction: "bidirectional",
  syncHistory: true,
  syncReadingList: true,
  syncTabGroups: true,
  syncOpenTabs: true,
  openTabsFolderName: "Open Tabs",
  tabGroupsFolderName: "Tab Groups",
});

const VALID_DIRECTIONS = new Set([
  "bidirectional",
  "chrome_to_safari",
  "safari_to_chrome",
]);

let port = null;
let reconnectTimer = null;
const sendQueue = [];
let sending = false;
let ticking = false;
let pendingTick = false;
let cachedBrowserLabel = null;
let cachedSettings = { ...DEFAULT_SETTINGS };
let lastStatus = {};
const safariHistoryEchoes = new Map();
let folderMutationLock = Promise.resolve();

// --- URL normalization (mirrors migrate.py) ---
const TRACKING = new Set([
  "utm_source","utm_medium","utm_campaign","utm_term","utm_content",
  "fbclid","gclid","msclkid","mc_eid","mc_cid","igshid",
  "_ga","_gl","yclid","dclid","wbraid","gbraid",
  "ref","ref_src","ref_url","source","via",
  "_hsenc","_hsmi","hsa_acc","hsa_cam",
  "itm_source","itm_medium","itm_campaign",
  "itmmeta","itmprp","_skw",
  "_trkparms","_trksid","amdata","__cf_chl_tk",
]);

function normalizeUrl(raw) {
  if (!raw) return raw;
  try {
    const u = new URL(raw.trim());
    u.protocol = u.protocol.toLowerCase();
    let host = u.hostname.toLowerCase();
    if (host.startsWith("www.")) host = host.slice(4);
    u.hostname = host;
    if ((u.protocol === "http:" && u.port === "80") ||
        (u.protocol === "https:" && u.port === "443")) u.port = "";
    u.pathname = u.pathname.replace(/\/+$/, "") || "/";
    const kept = [];
    for (const [k, v] of u.searchParams) {
      if (!TRACKING.has(k.toLowerCase())) kept.push([k, v]);
    }
    kept.sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0);
    const sp = new URLSearchParams();
    for (const [k, v] of kept) sp.append(k, v);
    u.search = sp.toString() ? "?" + sp.toString() : "";
    u.hash = "";
    return u.toString();
  } catch {
    return String(raw).trim().toLowerCase();
  }
}

function nowIso() {
  return new Date().toISOString();
}

function messageForError(error) {
  if (!error) return "";
  if (typeof error === "string") return error;
  return error.message || String(error);
}

function cleanFolderName(value, fallback) {
  const text = String(value || "").trim();
  return text || fallback;
}

function sanitizeSettings(raw = {}) {
  const merged = { ...DEFAULT_SETTINGS, ...raw };
  return {
    paused: Boolean(merged.paused),
    direction: VALID_DIRECTIONS.has(merged.direction)
      ? merged.direction
      : DEFAULT_SETTINGS.direction,
    syncHistory: merged.syncHistory !== false,
    syncReadingList: merged.syncReadingList !== false,
    syncTabGroups: merged.syncTabGroups !== false,
    syncOpenTabs: merged.syncOpenTabs !== false,
    openTabsFolderName: cleanFolderName(
      merged.openTabsFolderName,
      DEFAULT_SETTINGS.openTabsFolderName,
    ),
    tabGroupsFolderName: cleanFolderName(
      merged.tabGroupsFolderName,
      DEFAULT_SETTINGS.tabGroupsFolderName,
    ),
  };
}

async function getSettings() {
  const data = await chrome.storage.local.get([STORAGE_KEYS.SETTINGS]);
  cachedSettings = sanitizeSettings(data[STORAGE_KEYS.SETTINGS]);
  return cachedSettings;
}

async function saveSettingsPatch(patch) {
  const current = await getSettings();
  const next = sanitizeSettings({ ...current, ...patch });
  cachedSettings = next;
  await chrome.storage.local.set({ [STORAGE_KEYS.SETTINGS]: next });
  await updateStatus({ paused: next.paused, direction: next.direction });

  if (next.paused) {
    sendQueue.length = 0;
    disconnectNative();
  } else {
    connect();
    sendConfigToNative(next);
  }

  await refreshBadge(next);
  return next;
}

async function readStatus() {
  const data = await chrome.storage.local.get([STORAGE_KEYS.STATUS]);
  lastStatus = data[STORAGE_KEYS.STATUS] || {};
  return lastStatus;
}

async function updateStatus(patch) {
  const current = await readStatus();
  const next = {
    ...current,
    ...patch,
    nativeConnected: Boolean(port),
    queueLength: sendQueue.length,
    updatedAt: nowIso(),
  };
  lastStatus = next;
  await chrome.storage.local.set({ [STORAGE_KEYS.STATUS]: next });
  await refreshBadge(cachedSettings, next);
  return next;
}

async function getHistory() {
  const data = await chrome.storage.local.get([STORAGE_KEYS.HISTORY]);
  return Array.isArray(data[STORAGE_KEYS.HISTORY]) ? data[STORAGE_KEYS.HISTORY] : [];
}

async function addActivity(type, message, details = {}) {
  const history = await getHistory();
  history.unshift({
    type,
    message,
    details,
    at: nowIso(),
  });
  await chrome.storage.local.set({
    [STORAGE_KEYS.HISTORY]: history.slice(0, HISTORY_LIMIT),
  });
}

async function refreshBadge(settings = cachedSettings, status = lastStatus) {
  if (!chrome.action) return;
  let text = "OFF";
  let color = "#6b7280";

  if (settings.paused) {
    text = "PAUS";
    color = "#6b7280";
  } else if (status.lastError) {
    text = "ERR";
    color = "#dc2626";
  } else if (status.syncing) {
    text = "SYNC";
    color = "#2563eb";
  } else if (port) {
    text = "OK";
    color = "#16a34a";
  }

  try {
    await chrome.action.setBadgeText({ text });
    await chrome.action.setBadgeBackgroundColor({ color });
  } catch {}
}

function settingsForNative(settings = cachedSettings) {
  return {
    paused: Boolean(settings.paused),
    direction: settings.direction,
    syncHistory: Boolean(settings.syncHistory),
    syncReadingList: Boolean(settings.syncReadingList),
    syncOpenTabs: Boolean(settings.syncOpenTabs),
    syncTabGroups: Boolean(settings.syncTabGroups),
    openTabsFolderName: settings.openTabsFolderName,
    tabGroupsFolderName: settings.tabGroupsFolderName,
  };
}

function shouldSendChromeToSafari(settings) {
  return !settings.paused && settings.direction !== "safari_to_chrome";
}

function shouldApplySafariToChrome(settings) {
  return !settings.paused && settings.direction !== "chrome_to_safari";
}

function shouldSendChromeHistoryToSafari(settings) {
  return shouldSendChromeToSafari(settings) && settings.syncHistory && chrome.history;
}

function shouldApplySafariHistoryToChrome(settings) {
  return shouldApplySafariToChrome(settings) && settings.syncHistory && chrome.history;
}

function isSyncableHistoryUrl(url) {
  if (!url) return false;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function hashString(value, seed = 2166136261) {
  let hash = seed >>> 0;
  const text = String(value || "");
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash.toString(36);
}

function historyUrlKey(url) {
  const normalized = normalizeUrl(url || "");
  return [
    normalized.length,
    hashString(normalized),
    hashString(normalized, 2166136261 ^ 2654435769),
  ].join(":");
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function storedStringSet(value) {
  return new Set(
    Array.isArray(value)
      ? value.filter(item => typeof item === "string" && item)
      : [],
  );
}

function boundedSetArray(value, limit) {
  return Array.from(value).slice(-limit);
}

function rememberSafariHistoryEcho(url) {
  if (!url) return;
  const norm = normalizeUrl(url);
  safariHistoryEchoes.set(norm, Date.now());
  setTimeout(() => {
    if (Date.now() - (safariHistoryEchoes.get(norm) || 0) >= SAFARI_HISTORY_ECHO_WINDOW_MS) {
      safariHistoryEchoes.delete(norm);
    }
  }, SAFARI_HISTORY_ECHO_WINDOW_MS + 1000);
}

function shouldSkipSafariHistoryEcho(url) {
  const norm = normalizeUrl(url);
  const seenAt = safariHistoryEchoes.get(norm);
  if (!seenAt) return false;
  if (Date.now() - seenAt > SAFARI_HISTORY_ECHO_WINDOW_MS) {
    safariHistoryEchoes.delete(norm);
    return false;
  }
  return true;
}

function isGeneratedPath(path, settings) {
  return Array.isArray(path) &&
    path[0] === CANON_OTHER &&
    (
      path[1] === settings.openTabsFolderName ||
      path[1] === settings.tabGroupsFolderName ||
      path[1] === DEFAULT_SETTINGS.openTabsFolderName ||
      path[1] === DEFAULT_SETTINGS.tabGroupsFolderName
    );
}

function shouldSkipRemovalForDisabledFeature(prev, settings) {
  if (prev.kind === "reading_list" && !settings.syncReadingList) return true;
  if (Array.isArray(prev.path) && isGeneratedPath(prev.path, settings)) {
    if (prev.path[1] === settings.openTabsFolderName ||
        prev.path[1] === DEFAULT_SETTINGS.openTabsFolderName) {
      return false;
    }
    if (prev.path[1] === settings.tabGroupsFolderName ||
        prev.path[1] === DEFAULT_SETTINGS.tabGroupsFolderName) {
      return false;
    }
  }
  return false;
}

async function browserLabel() {
  if (cachedBrowserLabel) return cachedBrowserLabel;

  const ua = navigator.userAgent || "";
  const brands = (navigator.userAgentData?.brands || [])
    .map(b => b.brand)
    .join(" ");
  const browserText = `${brands} ${ua}`;

  if (/Helium/i.test(browserText)) {
    cachedBrowserLabel = "Helium";
  } else if (/Edg\//.test(browserText) || /Microsoft Edge/i.test(browserText)) {
    cachedBrowserLabel = "Microsoft Edge";
  } else if (/Brave/i.test(browserText)) {
    cachedBrowserLabel = "Brave";
  } else if (/Arc/i.test(browserText)) {
    cachedBrowserLabel = "Arc";
  } else {
    try {
      const rootIds = await getCanonicalRootIds();
      cachedBrowserLabel = rootIds[CANON_OTHER] === "27" ? "Helium" : "Google Chrome";
    } catch {
      cachedBrowserLabel = "Google Chrome";
    }
  }

  return cachedBrowserLabel;
}

// --- Native host connection ---
function connect() {
  if (port || cachedSettings.paused) return;
  reconnectTimer = null;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    console.error("connectNative failed:", e);
    updateStatus({
      lastError: messageForError(e),
      lastDisconnectedAt: nowIso(),
    });
    addActivity("error", "Native host connection failed", { error: messageForError(e) });
    scheduleReconnect(60000);
    return;
  }
  port.onMessage.addListener(handleFromNative);
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    port = null;
    updateStatus({
      lastDisconnectedAt: nowIso(),
      lastError: err ? err.message : "",
    });
    if (err?.message?.includes("not found")) {
      console.error("Safari Sync: native host not found");
      addActivity("error", "Native host not found");
      scheduleReconnect(60000);
    } else if (!cachedSettings.paused) {
      scheduleReconnect(2000);
    }
  });
  updateStatus({
    lastConnectedAt: nowIso(),
    lastError: "",
  });
  pumpQueue();
}

function disconnectNative() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (!port) return;
  const oldPort = port;
  port = null;
  try {
    oldPort.disconnect();
  } catch {}
  updateStatus({
    lastDisconnectedAt: nowIso(),
    syncing: false,
  });
}

function scheduleReconnect(delay) {
  if (reconnectTimer || cachedSettings.paused) return;
  reconnectTimer = setTimeout(connect, delay);
}

function sendConfigToNative(settings = cachedSettings) {
  if (settings.paused) return;
  send({
    action: "config",
    settings: settingsForNative(settings),
  });
}

function send(msg) {
  if (cachedSettings.paused && msg.action !== "config") return;
  sendQueue.push(msg);
  pumpQueue();
}

async function pumpQueue() {
  if (sending) return;
  sending = true;
  try {
    while (sendQueue.length) {
      if (!port) {
        connect();
        if (!port) break;
      }
      const msg = sendQueue.shift();
      try {
        port.postMessage(msg);
      } catch (e) {
        console.error("post error:", e);
        sendQueue.unshift(msg);
        port = null;
        updateStatus({
          lastError: messageForError(e),
          lastDisconnectedAt: nowIso(),
        });
        addActivity("error", "Native host post failed", { error: messageForError(e) });
        scheduleReconnect(2000);
        break;
      }
      await new Promise(r => setTimeout(r, SEND_INTERVAL_MS));
    }
  } finally {
    sending = false;
    updateStatus({ queueLength: sendQueue.length });
  }
}

// --- Build canonical snapshot of Chrome state ---
async function buildChromeSnapshot(settings = cachedSettings) {
  const out = {};
  const byFolder = {};
  const currentBrowser = await browserLabel();

  function walk(node, path, rootKey = null) {
    if (node.url) return;
    let nextPath = path;
    if (rootKey) {
      if (rootKey === "bookmark_bar") nextPath = [CANON_BAR];
      else if (rootKey === "other") nextPath = [CANON_OTHER];
      else return;
    } else if (node.title) {
      const title = node.title;
      const isImportedOther =
        title === "Other Bookmarks" && path.includes("Imported from Google Chrome");
      nextPath = isImportedOther ? path : [...path, title];
    }

    if (nextPath.length > 0) {
      const key = JSON.stringify(nextPath);
      const ordered = [];
      let idx = 0;
      for (const c of node.children || []) {
        if (c.url) {
          if (c.url.startsWith("chrome://") || c.url.startsWith("chrome-extension://")) continue;
          const norm = normalizeUrl(c.url);
          if (!out[norm]) {
            out[norm] = {
              url: c.url,
              title: c.title || c.url,
              path: nextPath,
              kind: "bookmark",
              index: idx,
            };
            ordered.push(norm);
            idx++;
          }
        }
      }
      byFolder[key] = ordered;
    }

    for (const c of node.children || []) walk(c, nextPath);
  }

  function rootKey(root) {
    const title = (root.title || "").toLowerCase();
    if (root.id === "1" || title === "bookmarks bar" || title === "favorites") {
      return "bookmark_bar";
    }
    if (root.id === "2" || title === "other bookmarks") {
      return "other";
    }
    return null;
  }

  const tree = await chrome.bookmarks.getTree();
  const roots = tree[0]?.children || tree;
  for (const root of roots) {
    const key = rootKey(root);
    if (key) walk(root, [], key);
  }

  if (settings.syncReadingList && chrome.readingList) {
    try {
      const entries = await chrome.readingList.query({});
      let idx = 0;
      for (const e of entries) {
        const norm = normalizeUrl(e.url);
        if (!out[norm]) {
          out[norm] = {
            url: e.url,
            title: e.title || e.url,
            path: [],
            kind: "reading_list",
            index: idx++,
          };
        }
      }
    } catch {}
  }

  if (settings.syncTabGroups && chrome.tabGroups && chrome.tabs) {
    try {
      const groups = await chrome.tabGroups.query({});
      for (const g of groups) {
        const tabs = await chrome.tabs.query({ groupId: g.id });
        const groupName = g.title || `Group ${g.id}`;
        const groupPath = [CANON_OTHER, settings.tabGroupsFolderName, groupName];
        const key = JSON.stringify(groupPath);
        const ordered = [];
        let idx = 0;
        for (const t of tabs) {
          if (!t.url ||
              t.url.startsWith("chrome://") ||
              t.url.startsWith("chrome-extension://") ||
              t.url.startsWith("about:")) {
            continue;
          }
          const norm = normalizeUrl(t.url);
          const itemKey = `tabgroup:${g.id}:${t.id}:${norm}`;
          out[itemKey] = {
            url: t.url,
            title: t.title || t.url,
            path: groupPath,
            kind: "bookmark",
            index: idx++,
            allowDuplicate: true,
          };
          ordered.push(norm);
        }
        byFolder[key] = ordered;
      }
    } catch {}
  }

  if (settings.syncOpenTabs && chrome.tabs) {
    try {
      const tabs = await chrome.tabs.query({});
      const openTabsPath = [CANON_OTHER, settings.openTabsFolderName, currentBrowser];
      const key = JSON.stringify(openTabsPath);
      const ordered = [];
      let idx = 0;
      for (const t of tabs) {
        if (!t.url ||
            t.url.startsWith("chrome://") ||
            t.url.startsWith("chrome-extension://") ||
            t.url.startsWith("about:")) {
          continue;
        }
        const norm = normalizeUrl(t.url);
        out[`opentab:${currentBrowser}:${t.windowId}:${t.id}:${norm}`] = {
          url: t.url,
          title: t.title || t.url,
          path: openTabsPath,
          kind: "bookmark",
          index: idx++,
          allowDuplicate: true,
        };
        ordered.push(norm);
      }
      byFolder[key] = ordered;
    } catch {}
  }

  return { byUrl: out, byFolder };
}

async function getChromeHistoryVisits(item, options = {}) {
  if (!isSyncableHistoryUrl(item?.url)) {
    return { visits: [], fullyBackfilled: false };
  }

  const backfilledUrlKeys = options.backfilledUrlKeys instanceof Set
    ? options.backfilledUrlKeys
    : null;
  const urlKey = historyUrlKey(item.url);
  const wasBackfilled = backfilledUrlKeys?.has(urlKey) || false;
  if (options.skipKnownBackfilledUrls && wasBackfilled) {
    return { visits: [], fullyBackfilled: false };
  }

  const startTime = finiteNumber(options.startTime, 0);
  const endTime = finiteNumber(options.endTime, Number.MAX_SAFE_INTEGER);
  const fullBackfill = Boolean(backfilledUrlKeys && !wasBackfilled);
  const selected = [];
  const seen = new Set();
  let loadedVisits = false;

  try {
    const visits = await chrome.history.getVisits({ url: item.url });
    loadedVisits = true;
    for (const visit of visits || []) {
      const visitTime = Number(visit.visitTime);
      if (!Number.isFinite(visitTime)) continue;
      if (!fullBackfill && (visitTime < startTime || visitTime > endTime)) continue;
      const visitKey = `${visit.visitId || ""}:${visitTime}`;
      if (seen.has(visitKey)) continue;
      seen.add(visitKey);
      selected.push({
        visitTime,
        visitId: visit.visitId,
        transition: visit.transition,
      });
    }
  } catch (e) {
    console.warn("getVisits failed:", e);
  }

  if (!selected.length) {
    const fallbackVisitTime = Number(item.lastVisitTime);
    if (
      Number.isFinite(fallbackVisitTime) &&
      (fullBackfill || (fallbackVisitTime >= startTime && fallbackVisitTime <= endTime))
    ) {
      selected.push({ visitTime: fallbackVisitTime });
    }
  }

  if (fullBackfill && loadedVisits) {
    backfilledUrlKeys.add(urlKey);
  }

  selected.sort((a, b) => a.visitTime - b.visitTime);
  return { visits: selected, fullyBackfilled: fullBackfill && loadedVisits };
}

async function sendChromeHistoryItems(items, source, options = {}) {
  const currentBrowser = await browserLabel();
  const sorted = [...items].sort((a, b) => (a.lastVisitTime || 0) - (b.lastVisitTime || 0));
  const pending = [];

  for (const item of sorted) {
    if (!isSyncableHistoryUrl(item.url)) continue;
    if (source === "safari_echo" || shouldSkipSafariHistoryEcho(item.url)) continue;
    const { visits } = await getChromeHistoryVisits(item, options);
    for (const visit of visits) {
      pending.push({
        item,
        visit,
      });
    }
  }

  pending.sort((a, b) => a.visit.visitTime - b.visit.visitTime);
  for (const { item, visit } of pending) {
    send({
      action: "history_add",
      url: item.url,
      title: item.title || item.url,
      visitTime: visit.visitTime,
      visitId: visit.visitId,
      transition: visit.transition,
      browser: currentBrowser,
      source,
    });
  }

  return pending.length;
}

async function searchHistory(params) {
  if (!chrome.history) return [];
  return chrome.history.search({
    text: "",
    ...params,
  });
}

async function syncChromeHistory(settings = cachedSettings) {
  if (!shouldSendChromeHistoryToSafari(settings)) {
    return { historyCount: 0, historyBackfillRemaining: false };
  }

  const now = Date.now();
  const stored = await chrome.storage.local.get([
    STORAGE_KEYS.HISTORY_RECENT_CURSOR,
    STORAGE_KEYS.HISTORY_BACKFILL_BEFORE,
    STORAGE_KEYS.HISTORY_BACKFILL_DONE,
    STORAGE_KEYS.HISTORY_BACKFILLED_URL_KEYS,
  ]);

  let recentCursor = Number(stored[STORAGE_KEYS.HISTORY_RECENT_CURSOR]);
  if (!Number.isFinite(recentCursor) || recentCursor <= 0) recentCursor = now;
  let backfillBefore = Number(stored[STORAGE_KEYS.HISTORY_BACKFILL_BEFORE]);
  let backfillDone = Boolean(stored[STORAGE_KEYS.HISTORY_BACKFILL_DONE]);
  const storedBackfilledUrlKeys = Array.isArray(stored[STORAGE_KEYS.HISTORY_BACKFILLED_URL_KEYS])
    ? stored[STORAGE_KEYS.HISTORY_BACKFILLED_URL_KEYS]
    : [];
  const backfilledUrlKeys = storedStringSet(storedBackfilledUrlKeys);

  if (backfillDone && storedBackfilledUrlKeys.length === 0) {
    backfillDone = false;
    backfillBefore = now;
  }

  const recentStart = Math.max(0, recentCursor - HISTORY_SCAN_OVERLAP_MS);
  const recent = await searchHistory({
    startTime: recentStart,
    maxResults: HISTORY_RECENT_MAX_RESULTS,
  });
  const recentCount = await sendChromeHistoryItems(recent, "recent_scan", {
    startTime: recentStart,
    endTime: now,
    backfilledUrlKeys,
  });
  let maxRecent = recentCursor;
  for (const item of recent) {
    const t = Number(item.lastVisitTime) || 0;
    if (t > maxRecent) maxRecent = t;
  }

  let backfillCount = 0;

  if (!backfillDone) {
    if (!Number.isFinite(backfillBefore) || backfillBefore <= 0) backfillBefore = now;
    const backfill = await searchHistory({
      startTime: 0,
      endTime: backfillBefore,
      maxResults: HISTORY_BACKFILL_PAGE_SIZE,
    });
    backfillCount = await sendChromeHistoryItems(backfill, "backfill", {
      startTime: 0,
      endTime: backfillBefore,
      backfilledUrlKeys,
      skipKnownBackfilledUrls: true,
    });

    if (backfill.length < HISTORY_BACKFILL_PAGE_SIZE) {
      backfillDone = true;
      backfillBefore = 0;
    } else {
      const oldest = Math.min(...backfill.map(item => Number(item.lastVisitTime) || backfillBefore));
      backfillBefore = Math.max(0, oldest - 1);
    }
  }

  await chrome.storage.local.set({
    [STORAGE_KEYS.HISTORY_RECENT_CURSOR]: Math.max(maxRecent, now),
    [STORAGE_KEYS.HISTORY_BACKFILL_BEFORE]: backfillBefore,
    [STORAGE_KEYS.HISTORY_BACKFILL_DONE]: backfillDone,
    [STORAGE_KEYS.HISTORY_BACKFILLED_URL_KEYS]: boundedSetArray(
      backfilledUrlKeys,
      HISTORY_BACKFILLED_URL_KEYS_LIMIT,
    ),
  });

  return {
    historyCount: recentCount + backfillCount,
    historyBackfillRemaining: !backfillDone,
  };
}

// --- Safari to Chrome application ---
async function getCanonicalRootIds() {
  const tree = await chrome.bookmarks.getTree();
  const roots = tree[0]?.children || tree;
  let barId = null;
  let otherId = null;

  for (const root of roots) {
    const title = (root.title || "").toLowerCase();
    if (!barId && (root.id === "1" || title === "bookmarks bar" || title === "favorites")) {
      barId = root.id;
    }
    if (!otherId && (root.id === "2" || title === "other bookmarks")) {
      otherId = root.id;
    }
  }

  return {
    [CANON_BAR]: barId || "1",
    [CANON_OTHER]: otherId || "2",
  };
}

async function findOrCreateFolder(path) {
  const previous = folderMutationLock;
  let release;
  folderMutationLock = new Promise(resolve => { release = resolve; });
  await previous.catch(() => {});

  try {
    const rootIds = await getCanonicalRootIds();
    if (!path || !path.length) return rootIds[CANON_OTHER];
    const rootId = path[0] === CANON_BAR ? rootIds[CANON_BAR] : rootIds[CANON_OTHER];
    let curId = rootId;
    for (const part of path.slice(1)) {
      const children = await chrome.bookmarks.getChildren(curId);
      const existing = children.find(c => !c.url && c.title === part);
      curId = existing ? existing.id : (await chrome.bookmarks.create({ parentId: curId, title: part })).id;
    }
    return curId;
  } finally {
    release();
  }
}

async function boundedBookmarkIndex(parentId, requestedIndex, sameParent = false) {
  if (!Number.isFinite(requestedIndex) || requestedIndex < 0) return undefined;

  const children = await chrome.bookmarks.getChildren(parentId).catch(() => []);
  const requested = Math.floor(requestedIndex);
  const maxIndex = sameParent ? Math.max(0, children.length - 1) : children.length;
  return Math.min(requested, maxIndex);
}

async function moveBookmarkSafely(node, parentId, requestedIndex) {
  const moveArgs = { parentId };
  const safeIndex = await boundedBookmarkIndex(parentId, requestedIndex, node.parentId === parentId);
  if (safeIndex !== undefined) moveArgs.index = safeIndex;

  try {
    return await chrome.bookmarks.move(node.id, moveArgs);
  } catch (e) {
    if (moveArgs.index === undefined) return null;
    return chrome.bookmarks.move(node.id, { parentId }).catch(() => null);
  }
}

async function createBookmarkSafely(parentId, title, url, requestedIndex) {
  const createArgs = { parentId, title: title || url, url };
  const safeIndex = requestedIndex === undefined
    ? undefined
    : await boundedBookmarkIndex(parentId, requestedIndex, false);
  if (safeIndex !== undefined) createArgs.index = safeIndex;

  try {
    return await chrome.bookmarks.create(createArgs);
  } catch (e) {
    if (createArgs.index === undefined) throw e;
    delete createArgs.index;
    return chrome.bookmarks.create(createArgs);
  }
}

async function findExistingBookmarkForUrl(url) {
  const target = normalizeUrl(url);
  const tree = await chrome.bookmarks.getTree();
  const matches = [];

  function walk(node) {
    if (node.url && (node.url === url || normalizeUrl(node.url) === target)) {
      matches.push(node);
    }
    for (const child of node.children || []) walk(child);
  }

  for (const root of tree) walk(root);
  return matches.find(node => node.url === url) || matches[0] || null;
}

async function handleFromNative(msg) {
  try {
    const { action, url, title, path, kind, index, urls } = msg;
    if (!action) {
      if (msg.status === "error") {
        await updateStatus({ lastError: msg.message || "Native host error" });
        await addActivity("error", "Native host error", { message: msg.message || "" });
      }
      return;
    }

    const settings = await getSettings();
    if (!shouldApplySafariToChrome(settings)) return;
    if (kind === "reading_list" && !settings.syncReadingList) return;

    if (action === "history_add") {
      if (!shouldApplySafariHistoryToChrome(settings) || !isSyncableHistoryUrl(url)) return;
      rememberSafariHistoryEcho(url);
      await chrome.history.addUrl({ url });
      await addActivity("safari_to_chrome", "Added Chrome history visit", { url });
      await updateStatus({ lastSyncAt: nowIso(), lastSafariToChromeAt: nowIso(), lastError: "" });
    } else if (action === "add") {
      if (!url) return;
      if (kind === "reading_list") {
        if (chrome.readingList) {
          await chrome.readingList
            .addEntry({ url, title: title || url, hasBeenRead: false })
            .catch(() => {});
        }
      } else {
        const existing = await findExistingBookmarkForUrl(url);
        const parentId = await findOrCreateFolder(path || [CANON_OTHER]);
        if (existing) {
          await chrome.bookmarks.update(existing.id, { title: title || url }).catch(() => {});
          await moveBookmarkSafely(existing, parentId);
          await addActivity("safari_to_chrome", "Updated Chrome bookmark", { url, path });
          await updateStatus({ lastSyncAt: nowIso(), lastSafariToChromeAt: nowIso(), lastError: "" });
          return;
        }
        await createBookmarkSafely(parentId, title, url);
      }
      await addActivity("safari_to_chrome", "Added Chrome bookmark", { url, path, kind });
      await updateStatus({ lastSyncAt: nowIso(), lastSafariToChromeAt: nowIso(), lastError: "" });
    } else if (action === "remove") {
      if (!url) return;
      if (kind === "reading_list") {
        if (chrome.readingList) {
          await chrome.readingList.removeEntry({ url }).catch(() => {});
        }
      } else {
        const existing = await chrome.bookmarks.search({ url });
        for (const b of existing) await chrome.bookmarks.remove(b.id).catch(() => {});
      }
      await addActivity("safari_to_chrome", "Removed Chrome bookmark", { url, kind });
      await updateStatus({ lastSyncAt: nowIso(), lastSafariToChromeAt: nowIso(), lastError: "" });
    } else if (action === "reorder") {
      if (!Array.isArray(urls) || !Array.isArray(path)) return;
      const parentId = await findOrCreateFolder(path);
      const children = await chrome.bookmarks.getChildren(parentId);
      const byNorm = new Map();
      for (const c of children) {
        if (c.url) byNorm.set(normalizeUrl(c.url), c);
      }
      let target = 0;
      for (const norm of urls) {
        const node = byNorm.get(norm);
        if (node) {
          await moveBookmarkSafely(node, parentId, target);
          target++;
        }
      }
      await addActivity("safari_to_chrome", "Reordered Chrome folder", { path, count: urls.length });
      await updateStatus({ lastSyncAt: nowIso(), lastSafariToChromeAt: nowIso(), lastError: "" });
    }
  } catch (e) {
    console.error("handleFromNative:", e);
    await updateStatus({ lastError: messageForError(e) });
    await addActivity("error", "Safari to Chrome sync failed", { error: messageForError(e) });
  }
}

// --- Reconciliation tick ---
async function tickOnce(options = {}) {
  const manual = Boolean(options.manual);
  try {
    const settings = await getSettings();
    await updateStatus({
      paused: settings.paused,
      direction: settings.direction,
      lastTickAt: nowIso(),
    });

    if (settings.paused) {
      disconnectNative();
      return { skipped: "paused" };
    }

    connect();
    sendConfigToNative(settings);

    if (!shouldSendChromeToSafari(settings)) {
      return { skipped: "direction" };
    }

    await updateStatus({
      syncing: true,
      lastSyncStartedAt: nowIso(),
    });

    const { byUrl: current, byFolder: currentFolders } = await buildChromeSnapshot(settings);
    const storedState = await chrome.storage.local.get([
      STORAGE_KEYS.CHROME_SNAPSHOT,
      STORAGE_KEYS.FOLDER_ORDER,
    ]);
    const stored = storedState[STORAGE_KEYS.CHROME_SNAPSHOT] || {};
    const storedFolders = storedState[STORAGE_KEYS.FOLDER_ORDER] || {};

    let addCount = 0, removeCount = 0, reorderCount = 0, historyCount = 0;
    let historyBackfillRemaining = false;
    const changedDuplicateRemovals = [];

    const adds = [];
    for (const [norm, item] of Object.entries(current)) {
      const prev = stored[norm];
      const pathChanged = JSON.stringify(prev?.path) !== JSON.stringify(item.path);
      const changed = !prev ||
        prev.kind !== item.kind ||
        pathChanged ||
        prev.title !== item.title;
      if (changed) {
        if (prev?.allowDuplicate && pathChanged) changedDuplicateRemovals.push(prev);
        adds.push(item);
      }
    }
    adds.sort((a, b) => {
      const pa = JSON.stringify(a.path), pb = JSON.stringify(b.path);
      if (pa !== pb) return pa < pb ? -1 : 1;
      return (a.index ?? 0) - (b.index ?? 0);
    });
    for (const item of adds) {
      send({
        action: "add",
        kind: item.kind,
        url: item.url,
        title: item.title,
        path: item.path,
        index: item.index,
        allowDuplicate: item.allowDuplicate,
      });
      addCount++;
    }

    for (const prev of changedDuplicateRemovals) {
      send({
        action: "remove",
        kind: prev.kind,
        url: prev.url,
        path: prev.path,
        allowDuplicate: prev.allowDuplicate,
      });
      removeCount++;
    }

    for (const [norm, prev] of Object.entries(stored)) {
      if (!current[norm] && !shouldSkipRemovalForDisabledFeature(prev, settings)) {
        send({
          action: "remove",
          kind: prev.kind,
          url: prev.url,
          path: prev.path,
          allowDuplicate: prev.allowDuplicate,
        });
        removeCount++;
      }
    }

    for (const [key, ordered] of Object.entries(currentFolders)) {
      const prev = storedFolders[key];
      if (JSON.stringify(prev) !== JSON.stringify(ordered)) {
        send({
          action: "reorder",
          path: JSON.parse(key),
          urls: ordered,
        });
        reorderCount++;
      }
    }

    const historyResult = await syncChromeHistory(settings);
    historyCount = historyResult.historyCount || 0;
    historyBackfillRemaining = Boolean(historyResult.historyBackfillRemaining);

    await chrome.storage.local.set({
      [STORAGE_KEYS.CHROME_SNAPSHOT]: current,
      [STORAGE_KEYS.FOLDER_ORDER]: currentFolders,
    });

    const counts = { addCount, removeCount, reorderCount, historyCount, historyBackfillRemaining };
    await updateStatus({
      syncing: false,
      lastSyncAt: nowIso(),
      lastChromeToSafariAt: nowIso(),
      lastChromeToSafariCounts: counts,
      lastError: "",
    });

    if (addCount || removeCount || reorderCount || historyCount || manual) {
      const message = `Chrome to Safari: +${addCount} -${removeCount} ~${reorderCount} h${historyCount}`;
      console.log(`Safari Sync tick: +${addCount} -${removeCount} ~${reorderCount} h${historyCount}`);
      await addActivity("chrome_to_safari", message, counts);
    }

    return counts;
  } catch (e) {
    console.error("tick:", e);
    await updateStatus({
      syncing: false,
      lastError: messageForError(e),
    });
    await addActivity("error", "Chrome to Safari sync failed", { error: messageForError(e) });
    return { error: messageForError(e) };
  }
}

async function tick(options = {}) {
  if (ticking) {
    pendingTick = true;
    return { queued: true };
  }
  ticking = true;
  let result;
  try {
    do {
      pendingTick = false;
      result = await tickOnce(options);
      options = {};
    } while (pendingTick);
    return result;
  } finally {
    ticking = false;
    await updateStatus({ syncing: false });
  }
}

async function getDashboard() {
  const [settings, status, history] = await Promise.all([
    getSettings(),
    readStatus(),
    getHistory(),
  ]);
  let browser = "";
  try {
    browser = await browserLabel();
  } catch {}
  return {
    settings,
    status: {
      ...status,
      nativeConnected: Boolean(port),
      queueLength: sendQueue.length,
      syncing: Boolean(status.syncing || ticking),
    },
    history,
    browser,
  };
}

chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  (async () => {
    const action = request?.action;
    if (action === "getDashboard") {
      return { ok: true, dashboard: await getDashboard() };
    }
    if (action === "syncNow") {
      const result = await tick({ manual: true });
      return { ok: !result?.error, result, dashboard: await getDashboard() };
    }
    if (action === "setPaused") {
      const settings = await saveSettingsPatch({ paused: Boolean(request.paused) });
      if (!settings.paused) await tick({ manual: true });
      await addActivity(settings.paused ? "paused" : "resumed", settings.paused ? "Sync paused" : "Sync resumed");
      return { ok: true, dashboard: await getDashboard() };
    }
    if (action === "saveSettings") {
      const settings = await saveSettingsPatch(request.settings || {});
      if (!settings.paused) await tick({ manual: true });
      await addActivity("settings", "Sync settings updated");
      return { ok: true, dashboard: await getDashboard() };
    }
    if (action === "clearHistory") {
      await chrome.storage.local.set({ [STORAGE_KEYS.HISTORY]: [] });
      return { ok: true, dashboard: await getDashboard() };
    }
    return { ok: false, error: "unknown_action" };
  })()
    .then(sendResponse)
    .catch((e) => sendResponse({ ok: false, error: messageForError(e) }));
  return true;
});

async function boot() {
  const settings = await getSettings();
  await updateStatus({
    paused: settings.paused,
    direction: settings.direction,
    lastBootAt: nowIso(),
  });
  if (!settings.paused) {
    connect();
    tick();
  }
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes[STORAGE_KEYS.SETTINGS]) return;
  cachedSettings = sanitizeSettings(changes[STORAGE_KEYS.SETTINGS].newValue);
  refreshBadge(cachedSettings);
});

// --- Wiring ---
chrome.alarms.create(TICK_ALARM, { periodInMinutes: TICK_PERIOD_MIN, delayInMinutes: 0 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === TICK_ALARM) tick();
});

chrome.runtime.onStartup.addListener(() => { boot(); });
chrome.runtime.onInstalled.addListener(() => { boot(); });

// Fast path: also tick on events. The alarm is the safety net.
chrome.bookmarks.onCreated.addListener(() => tick());
chrome.bookmarks.onRemoved.addListener(() => tick());
chrome.bookmarks.onChanged.addListener(() => tick());
chrome.bookmarks.onMoved.addListener(() => tick());
if (chrome.tabs) {
  chrome.tabs.onCreated.addListener(() => tick());
  chrome.tabs.onRemoved.addListener(() => tick());
  chrome.tabs.onUpdated.addListener(() => tick());
  chrome.tabs.onMoved.addListener(() => tick());
  chrome.tabs.onAttached.addListener(() => tick());
  chrome.tabs.onDetached.addListener(() => tick());
  chrome.tabs.onReplaced?.addListener(() => tick());
}
if (chrome.windows) {
  chrome.windows.onRemoved.addListener(() => tick());
  chrome.windows.onCreated.addListener(() => tick());
}
if (chrome.readingList) {
  chrome.readingList.onEntryAdded?.addListener(() => tick());
  chrome.readingList.onEntryRemoved?.addListener(() => tick());
  chrome.readingList.onEntryUpdated?.addListener(() => tick());
}
if (chrome.history) {
  chrome.history.onVisited.addListener((item) => {
    (async () => {
      const settings = await getSettings();
      if (!shouldSendChromeHistoryToSafari(settings)) return;
      const visitTime = finiteNumber(item.lastVisitTime, Date.now());
      const historyCount = await sendChromeHistoryItems([item], "event", {
        startTime: Math.max(0, visitTime - 1000),
        endTime: visitTime + 1000,
      });
      if (historyCount) {
        await updateStatus({
          lastSyncAt: nowIso(),
          lastChromeToSafariAt: nowIso(),
          lastChromeToSafariHistoryCount: historyCount,
          lastError: "",
        });
        await addActivity("chrome_to_safari", "Chrome to Safari: history visit", { url: item.url });
      }
    })().catch((e) => {
      updateStatus({ lastError: messageForError(e) });
      addActivity("error", "Chrome history sync failed", { error: messageForError(e) });
    });
  });
}

boot();
