// v4: reconciliation loop (no event-only dependency — reliable under MV3 SW suspension)
const HOST = "com.local.safari_bookmark_sync";
const CANON_BAR = "BAR";
const CANON_OTHER = "OTHER";
const SEND_INTERVAL_MS = 10;
const TICK_ALARM = "sync-tick";
const TICK_PERIOD_MIN = 0.5;

let port = null;
let reconnectTimer = null;
const sendQueue = [];
let sending = false;
let ticking = false;
let pendingTick = false;
let cachedBrowserLabel = null;

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
  if (port) return;
  reconnectTimer = null;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    console.error("connectNative failed:", e);
    scheduleReconnect(60000);
    return;
  }
  port.onMessage.addListener(handleFromNative);
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    port = null;
    if (err?.message?.includes("not found")) {
      console.error("Safari Sync: native host not found");
      scheduleReconnect(60000);
    } else {
      scheduleReconnect(2000);
    }
  });
  pumpQueue();
}

function scheduleReconnect(delay) {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(connect, delay);
}

function send(msg) {
  sendQueue.push(msg);
  pumpQueue();
}

async function pumpQueue() {
  if (sending) return;
  sending = true;
  try {
    while (sendQueue.length) {
      if (!port) { connect(); break; }
      const msg = sendQueue.shift();
      try {
        port.postMessage(msg);
      } catch (e) {
        console.error("post error:", e);
        sendQueue.unshift(msg);
        port = null;
        scheduleReconnect(2000);
        break;
      }
      await new Promise(r => setTimeout(r, SEND_INTERVAL_MS));
    }
  } finally {
    sending = false;
  }
}

// --- Build canonical snapshot of Chrome state ---
async function buildChromeSnapshot() {
  const out = {};          // normUrl -> {url, title, path, kind, index}
  const byFolder = {};     // pathKey -> [normUrls in order]
  const currentBrowser = await browserLabel();

  function walk(node, path, rootKey = null) {
    if (node.url) return; // leaves handled by parent loop below
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

    // Record ordered leaves for this folder (only real folders under canon roots)
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

  if (chrome.readingList) {
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

  if (chrome.tabGroups && chrome.tabs) {
    try {
      const groups = await chrome.tabGroups.query({});
      for (const g of groups) {
        const tabs = await chrome.tabs.query({ groupId: g.id });
        const groupName = g.title || `Group ${g.id}`;
        const groupPath = [CANON_OTHER, "Tab Groups", groupName];
        const key = JSON.stringify(groupPath);
        const ordered = [];
        let idx = 0;
        for (const t of tabs) {
          if (!t.url || t.url.startsWith("chrome://")) continue;
          const norm = normalizeUrl(t.url);
          const key = `tabgroup:${g.id}:${t.id}:${norm}`;
          out[key] = {
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

  if (chrome.tabs) {
    try {
      const tabs = await chrome.tabs.query({});
      const openTabsPath = [CANON_OTHER, "Open Tabs", currentBrowser];
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

// --- Safari → Chrome application ---
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
}

async function handleFromNative(msg) {
  try {
    const { action, url, title, path, kind, index, urls } = msg;
    if (action === "add") {
      if (!url) return;
      if (kind === "reading_list") {
        if (chrome.readingList) {
          await chrome.readingList
            .addEntry({ url, title: title || url, hasBeenRead: false })
            .catch(() => {});
        }
      } else {
        const existing = await chrome.bookmarks.search({ url });
        const parentId = await findOrCreateFolder(path || [CANON_OTHER]);
        if (existing.length) {
          const node = existing[0];
          await chrome.bookmarks.update(node.id, { title: title || url }).catch(() => {});
          const moveArgs = { parentId };
          if (typeof index === "number" && index >= 0) moveArgs.index = index;
          await chrome.bookmarks.move(node.id, moveArgs).catch(() => {});
          return;
        }
        const createArgs = { parentId, title: title || url, url };
        if (typeof index === "number" && index >= 0) createArgs.index = index;
        await chrome.bookmarks.create(createArgs);
      }
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
    } else if (action === "reorder") {
      if (!Array.isArray(urls) || !Array.isArray(path)) return;
      const parentId = await findOrCreateFolder(path);
      const children = await chrome.bookmarks.getChildren(parentId);
      // Map normalized URL -> bookmark node for leaves only
      const byNorm = new Map();
      for (const c of children) {
        if (c.url) byNorm.set(normalizeUrl(c.url), c);
      }
      let target = 0;
      for (const norm of urls) {
        const node = byNorm.get(norm);
        if (node) {
          await chrome.bookmarks.move(node.id, { parentId, index: target }).catch(() => {});
          target++;
        }
      }
    }
  } catch (e) {
    console.error("handleFromNative:", e);
  }
}

// --- Reconciliation tick ---
async function tickOnce() {
  try {
    if (!port) connect();

    const { byUrl: current, byFolder: currentFolders } = await buildChromeSnapshot();
    const storedState = await chrome.storage.local.get(["chrome_snapshot", "folder_order"]);
    const stored = storedState.chrome_snapshot || {};
    const storedFolders = storedState.folder_order || {};

    let addCount = 0, removeCount = 0, reorderCount = 0;

    // Adds (sorted by path + index so Safari applies them in the right order)
    const adds = [];
    for (const [norm, item] of Object.entries(current)) {
      const prev = stored[norm];
      const changed = !prev ||
        prev.kind !== item.kind ||
        JSON.stringify(prev.path) !== JSON.stringify(item.path) ||
        prev.title !== item.title;
      if (changed) adds.push(item);
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

    // Removes
    for (const [norm, prev] of Object.entries(stored)) {
      if (!current[norm]) {
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

    // Folder reorders
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

    await chrome.storage.local.set({
      chrome_snapshot: current,
      folder_order: currentFolders,
    });
    if (addCount || removeCount || reorderCount) {
      console.log(`Safari Sync tick: +${addCount} -${removeCount} ~${reorderCount}`);
    }
  } catch (e) {
    console.error("tick:", e);
  }
}

async function tick() {
  if (ticking) {
    pendingTick = true;
    return;
  }
  ticking = true;
  try {
    do {
      pendingTick = false;
      await tickOnce();
    } while (pendingTick);
  } finally {
    ticking = false;
  }
}

// --- Wiring ---
chrome.alarms.create(TICK_ALARM, { periodInMinutes: TICK_PERIOD_MIN, delayInMinutes: 0 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === TICK_ALARM) tick();
});

chrome.runtime.onStartup.addListener(() => { connect(); tick(); });
chrome.runtime.onInstalled.addListener(() => { connect(); tick(); });

// Fast path: also tick on events (the alarm is the safety net)
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
}

// Cold start
connect();
tick();
