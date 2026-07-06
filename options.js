const DEFAULTS = {
  paused: false,
  direction: "bidirectional",
  syncHistory: true,
  syncReadingList: true,
  syncTabGroups: true,
  syncOpenTabs: true,
  openTabsFolderName: "Open Tabs",
  tabGroupsFolderName: "Tab Groups",
};

const form = document.getElementById("optionsForm");
const statusEl = document.getElementById("saveStatus");
const fields = {
  direction: document.getElementById("direction"),
  syncHistory: document.getElementById("syncHistory"),
  syncReadingList: document.getElementById("syncReadingList"),
  syncTabGroups: document.getElementById("syncTabGroups"),
  syncOpenTabs: document.getElementById("syncOpenTabs"),
  openTabsFolderName: document.getElementById("openTabsFolderName"),
  tabGroupsFolderName: document.getElementById("tabGroupsFolderName"),
  resetDefaults: document.getElementById("resetDefaults"),
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

function setStatus(text, isError = false) {
  statusEl.textContent = text;
  statusEl.style.color = isError ? "#b91c1c" : "";
}

function render(settings) {
  const next = { ...DEFAULTS, ...(settings || {}) };
  fields.direction.value = next.direction;
  fields.syncHistory.checked = Boolean(next.syncHistory);
  fields.syncReadingList.checked = Boolean(next.syncReadingList);
  fields.syncTabGroups.checked = Boolean(next.syncTabGroups);
  fields.syncOpenTabs.checked = Boolean(next.syncOpenTabs);
  fields.openTabsFolderName.value = next.openTabsFolderName;
  fields.tabGroupsFolderName.value = next.tabGroupsFolderName;
}

function collect() {
  return {
    direction: fields.direction.value,
    syncHistory: fields.syncHistory.checked,
    syncReadingList: fields.syncReadingList.checked,
    syncTabGroups: fields.syncTabGroups.checked,
    syncOpenTabs: fields.syncOpenTabs.checked,
    openTabsFolderName: fields.openTabsFolderName.value.trim() || DEFAULTS.openTabsFolderName,
    tabGroupsFolderName: fields.tabGroupsFolderName.value.trim() || DEFAULTS.tabGroupsFolderName,
  };
}

async function load() {
  const response = await sendMessage({ action: "getDashboard" });
  if (!response?.ok) throw new Error(response?.error || "Options failed");
  render(response.dashboard.settings);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  setStatus("Saving");
  try {
    const response = await sendMessage({
      action: "saveSettings",
      settings: collect(),
    });
    if (!response?.ok) throw new Error(response?.error || "Save failed");
    render(response.dashboard.settings);
    setStatus("Saved");
  } catch (e) {
    setStatus(e.message, true);
  }
});

fields.resetDefaults.addEventListener("click", async () => {
  setStatus("Saving");
  try {
    const response = await sendMessage({
      action: "saveSettings",
      settings: { ...DEFAULTS },
    });
    if (!response?.ok) throw new Error(response?.error || "Reset failed");
    render(response.dashboard.settings);
    setStatus("Defaults restored");
  } catch (e) {
    setStatus(e.message, true);
  }
});

load().catch((e) => setStatus(e.message, true));
