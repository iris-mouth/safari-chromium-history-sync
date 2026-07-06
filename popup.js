const els = {
  statusDetail: document.getElementById("statusDetail"),
  statePill: document.getElementById("statePill"),
  nativeStatus: document.getElementById("nativeStatus"),
  lastSync: document.getElementById("lastSync"),
  lastCounts: document.getElementById("lastCounts"),
  queueLength: document.getElementById("queueLength"),
  errorBox: document.getElementById("errorBox"),
  historyList: document.getElementById("historyList"),
  syncNow: document.getElementById("syncNow"),
  pauseToggle: document.getElementById("pauseToggle"),
  optionsBtn: document.getElementById("optionsBtn"),
  clearHistory: document.getElementById("clearHistory"),
};

function sendMessage(payload) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(payload, (response) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message));
      } else {
        resolve(response);
      }
    });
  });
}

function formatTime(iso) {
  if (!iso) return "Never";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "Never";
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function setBusy(isBusy) {
  els.syncNow.disabled = isBusy;
  els.pauseToggle.disabled = isBusy;
  els.clearHistory.disabled = isBusy;
}

function stateFor(dashboard) {
  const settings = dashboard.settings || {};
  const status = dashboard.status || {};
  if (settings.paused) return { text: "Paused", cls: "paused" };
  if (status.lastError) return { text: "Error", cls: "error" };
  if (status.syncing) return { text: "Syncing", cls: "syncing" };
  if (status.nativeConnected) return { text: "OK", cls: "ok" };
  return { text: "Offline", cls: "" };
}

function renderHistory(history) {
  els.historyList.textContent = "";
  const entries = Array.isArray(history) ? history.slice(0, 8) : [];
  if (!entries.length) {
    const empty = document.createElement("li");
    empty.textContent = "No recent activity";
    els.historyList.append(empty);
    return;
  }

  for (const entry of entries) {
    const item = document.createElement("li");
    const message = document.createElement("span");
    const time = document.createElement("time");
    message.textContent = entry.message || entry.type || "Activity";
    time.textContent = formatTime(entry.at);
    item.append(message, time);
    els.historyList.append(item);
  }
}

function render(dashboard) {
  const settings = dashboard.settings || {};
  const status = dashboard.status || {};
  const state = stateFor(dashboard);
  const counts = status.lastChromeToSafariCounts || {};

  els.statePill.textContent = state.text;
  els.statePill.className = `pill ${state.cls}`.trim();
  els.statusDetail.textContent = `${dashboard.browser || "Browser"} - ${settings.direction || "bidirectional"}`;
  els.nativeStatus.textContent = status.nativeConnected ? "Connected" : "Disconnected";
  els.lastSync.textContent = formatTime(status.lastSyncAt);
  els.lastCounts.textContent = `+${counts.addCount || 0} -${counts.removeCount || 0} ~${counts.reorderCount || 0} h${counts.historyCount || 0}`;
  els.queueLength.textContent = String(status.queueLength || 0);
  els.pauseToggle.checked = Boolean(settings.paused);

  if (status.lastError) {
    els.errorBox.hidden = false;
    els.errorBox.textContent = status.lastError;
  } else {
    els.errorBox.hidden = true;
    els.errorBox.textContent = "";
  }

  renderHistory(dashboard.history || []);
}

async function refresh() {
  const response = await sendMessage({ action: "getDashboard" });
  if (!response?.ok) throw new Error(response?.error || "Dashboard failed");
  render(response.dashboard);
}

els.syncNow.addEventListener("click", async () => {
  setBusy(true);
  try {
    const response = await sendMessage({ action: "syncNow" });
    if (!response?.ok) throw new Error(response?.error || response?.result?.error || "Sync failed");
    render(response.dashboard);
  } catch (e) {
    els.errorBox.hidden = false;
    els.errorBox.textContent = e.message;
  } finally {
    setBusy(false);
  }
});

els.pauseToggle.addEventListener("change", async () => {
  setBusy(true);
  try {
    const response = await sendMessage({
      action: "setPaused",
      paused: els.pauseToggle.checked,
    });
    if (!response?.ok) throw new Error(response?.error || "Pause update failed");
    render(response.dashboard);
  } catch (e) {
    els.errorBox.hidden = false;
    els.errorBox.textContent = e.message;
  } finally {
    setBusy(false);
  }
});

els.clearHistory.addEventListener("click", async () => {
  setBusy(true);
  try {
    const response = await sendMessage({ action: "clearHistory" });
    if (!response?.ok) throw new Error(response?.error || "Clear failed");
    render(response.dashboard);
  } catch (e) {
    els.errorBox.hidden = false;
    els.errorBox.textContent = e.message;
  } finally {
    setBusy(false);
  }
});

els.optionsBtn.addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
});

refresh().catch((e) => {
  els.errorBox.hidden = false;
  els.errorBox.textContent = e.message;
});
