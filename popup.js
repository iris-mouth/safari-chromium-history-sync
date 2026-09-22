const elements = {
  state: document.getElementById("statePill"),
  detail: document.getElementById("statusDetail"),
  activeProfile: document.getElementById("activeProfile"),
  switchState: document.getElementById("switchState"),
  toSafari: document.getElementById("toSafari"),
  toBrowser: document.getElementById("toBrowser"),
  error: document.getElementById("errorBox"),
  syncNow: document.getElementById("syncNow"),
};

function request(message) {
  return chrome.runtime.sendMessage(message);
}

function render(status) {
  elements.state.textContent = status.switchState === "STABLE" ? "Ready" : "Switching";
  elements.state.className = `pill ${status.switchState === "STABLE" ? "ok" : "syncing"}`;
  elements.detail.textContent = "Safari ↔ Chrome / Edge";
  elements.activeProfile.textContent = status.activeProfileId ?? "None";
  elements.switchState.textContent = status.switchState;
  elements.toSafari.textContent = String(status.pendingBrowserToSafari);
  elements.toBrowser.textContent = String(status.pendingSafariToBrowser);
  elements.error.hidden = true;
}

async function refresh(action = "status") {
  elements.syncNow.disabled = true;
  try {
    const response = await request({ action });
    if (!response?.ok) throw new Error(response?.error ?? "Request failed");
    render(response.result);
  } catch (error) {
    elements.state.textContent = "Error";
    elements.state.className = "pill error";
    elements.error.hidden = false;
    elements.error.textContent = String(error?.message ?? error);
  } finally {
    elements.syncNow.disabled = false;
  }
}

elements.syncNow.addEventListener("click", () => refresh("syncNow"));
refresh();
