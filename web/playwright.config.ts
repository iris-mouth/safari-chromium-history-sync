import { defineConfig, devices } from "@playwright/test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
process.env.HISTORY_WEB_TEST_DIR ??= mkdtempSync(join(tmpdir(), "history-web-test-"));
export default defineConfig({
  testDir: "tests",
  workers: 1,
  fullyParallel: false,
  use: { baseURL: "http://127.0.0.1:18766", extraHTTPHeaders: { "Tailscale-User-Login": "owner@example.test" }, trace: "retain-on-failure" },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
    {
      name: "mobile",
      use: { ...devices["iPhone 13"], defaultBrowserType: "chromium" },
    },
  ],
  webServer: {
    command: "./scripts/test-server.sh",
    url: "http://127.0.0.1:18766",
    reuseExistingServer: false,
  },
});
