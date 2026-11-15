const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
const japanese = navigator.language.startsWith("ja");
document.documentElement.lang = japanese ? "ja" : "en";
const response = await chrome.runtime.sendMessage({ operation: "connectPair", token }).catch(() => null);
document.querySelector("p").textContent = response?.state === "connected"
  ? (japanese ? "このプロファイルを接続しました。このタブを閉じられます。" : "Profile connected. You can close this tab.")
  : (japanese ? "Mac の設定からプロファイルを接続し直してください。" : "Reconnect the profile from Settings on your Mac.");
