import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const manifest = JSON.parse(await readFile(
  new URL("../manifest.json", import.meta.url),
  "utf8",
));

function extensionId(key) {
  const digest = createHash("sha256")
    .update(Buffer.from(key, "base64"))
    .digest()
    .subarray(0, 16);
  return [...digest].map((byte) =>
    String.fromCharCode(97 + (byte >> 4)) +
    String.fromCharCode(97 + (byte & 0x0f))).join("");
}

test("manifest public key keeps the unpacked extension ID stable", () => {
  assert.equal(extensionId(manifest.key), "bkjoeemebkhfbhodbelkdnlifhlgonka");
});

test("manifest exposes no popup and keeps permissions minimal", () => {
  assert.equal(manifest.action, undefined);
  assert.deepEqual(manifest.permissions, [
    "history",
    "nativeMessaging",
    "storage",
    "alarms",
  ]);
});
