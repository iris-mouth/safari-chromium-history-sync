import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function source(path) {
  return readFile(new URL(`../${path}`, import.meta.url), "utf8");
}

test("product identifiers and bundle names remain consistent", async () => {
  const [identity, mainInfo, agentInfo, packaging, worker, setup, menu, agent, bridge, keychain] =
    await Promise.all([
      source("Sources/SafariSyncCore/ProductIdentity.swift"),
      source("Packaging/Info.plist"),
      source("Packaging/Agent-Info.plist"),
      source("scripts/package-app.sh"),
      source("extension/worker.js"),
      source("Sources/SafariSyncMenu/SetupCoordinator.swift"),
      source("Sources/SafariSyncMenu/SafariSyncMenuApp.swift"),
      source("Sources/SafariSyncAgent/main.swift"),
      source("Sources/SafariSyncBridge/main.swift"),
      source("Sources/SafariSyncCore/KeychainRootSecret.swift"),
    ]);

  assert.match(identity, /productName = "Safari Chromium History Sync"/);
  assert.match(identity, /menuBarLabel = "History Sync"/);
  assert.match(identity, /agentBundleName = "Safari Chromium History Sync Agent\.app"/);
  assert.match(identity, /agentExecutableName = "SafariSyncAgent"/);
  assert.match(identity, /applicationSupportDirectoryName = "Safari Chromium History Sync"/);
  assert.match(identity, /mainBundleIdentifier = "io\.github\.irismouth\.safari-chromium-history-sync"/);
  assert.match(identity, /agentBundleIdentifier = "io\.github\.irismouth\.safari-chromium-history-sync\.agent"/);
  assert.match(identity, /packageIdentifier = "io\.github\.irismouth\.safari-chromium-history-sync\.pkg"/);
  assert.match(identity, /keychainService = "io\.github\.irismouth\.safari-chromium-history-sync\.agent-state"/);
  assert.match(identity, /nativeMessagingHost = "io\.github\.irismouth\.safari_chromium_history_sync"/);

  assert.match(mainInfo, /<string>io\.github\.irismouth\.safari-chromium-history-sync<\/string>/);
  assert.match(agentInfo, /<string>io\.github\.irismouth\.safari-chromium-history-sync\.agent<\/string>/);
  assert.match(agentInfo, /<string>Safari Chromium History Sync Agent<\/string>/);
  assert.match(packaging, /Safari Chromium History Sync Agent\.app/);
  assert.match(packaging, /PACKAGE_IDENTIFIER="io\.github\.irismouth\.safari-chromium-history-sync\.pkg"/);
  assert.doesNotMatch(packaging, /NOTARY_PROFILE|INSTALLER_IDENTITY|CODESIGN_IDENTITY/);
  assert.match(worker, /const HOST = "io\.github\.irismouth\.safari_chromium_history_sync"/);
  assert.match(setup, /ProductIdentity\.nativeMessagingHost/);
  assert.match(menu, /ProductIdentity\.menuBarLabel/);
  assert.match(menu, /ProductIdentity\.agentBundleName/);
  assert.match(menu, /ProductIdentity\.applicationSupportDirectoryName/);
  assert.match(agent, /ProductIdentity\.agentBundleIdentifier/);
  assert.match(agent, /ProductIdentity\.applicationSupportDirectoryName/);
  assert.match(bridge, /ProductIdentity\.applicationSupportDirectoryName/);
  assert.match(keychain, /ProductIdentity\.keychainService/);
});

test("protocol version remains fixed at one", async () => {
  const protocol = await source("Sources/SafariSyncCore/Protocol.swift");
  assert.match(protocol, /safariSyncProtocolVersion = 1/);
});
