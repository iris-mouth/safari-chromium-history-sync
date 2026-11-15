import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { test, expect } from "@playwright/test";

test.use({ timezoneId: "America/Los_Angeles" });
const fixturePath = join(process.env.HISTORY_WEB_TEST_DIR!, "history.sqlite");
test.beforeEach(() => {
  execFileSync("python3", ["scripts/browser-fixture.py", fixturePath]);
});
function mutate(sql: string) {
  execFileSync("python3", ["-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit(); c.close()", fixturePath, sql]);
}
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function showDay(page, start: string, end = start) {
  await page.getByLabel("開始日").fill(start);
  await page.getByLabel("終了日").fill(end);
  await page.getByRole("button", { name: "表示", exact: true }).click();
}

test("200件の密な一覧・ローカルアイコン・件数選択・日付移動", async ({
  page,
}) => {
  const external: string[] = [];
  page.on("request", (r) => {
    if (new URL(r.url()).hostname !== "127.0.0.1") external.push(r.url());
  });
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(
    page.getByRole("heading", { name: "2026-11-10", exact: true }),
  ).toBeVisible();
  expect(
    await page
      .locator(".record")
      .first()
      .evaluate((e) => e.getBoundingClientRect().height),
  ).toBeLessThan(60);
  await expect(page.locator("img.favicon").first()).toBeVisible();
  await expect
    .poll(() =>
      page
        .locator("img.favicon")
        .first()
        .evaluate((e: HTMLImageElement) => e.naturalWidth),
    )
    .toBe(1);
  await expect(page.getByText("履歴を振り返る", { exact: true })).toHaveCount(
    0,
  );
  await expect(
    page.getByText("日付から、言葉から。あの日の流れをもう一度。", {
      exact: true,
    }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "この日の前後を見る" }),
  ).toHaveCount(0);
  const calls: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("/api/records?")) calls.push(r.url());
  });
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(400);
  expect(calls).toHaveLength(1);
  await page.getByLabel("1回の表示件数").selectOption("500");
  await expect(page.locator(".records li")).toHaveCount(500);
  await page.getByLabel("1回の表示件数").selectOption("100");
  await expect(page.locator(".records li")).toHaveCount(100);
  await page.locator(".record").first().click();
  await expect(page.getByRole("dialog")).toContainText("端末情報なし");
  await expect(page.getByRole("dialog").getByRole("link")).toHaveAttribute(
    "target",
    "_blank",
  );
  await page.getByRole("button", { name: "閉じる" }).click();
  await page.getByRole("button", { name: "翌日" }).click();
  await expect(page.locator(".records li")).toHaveCount(0);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  expect(external).toEqual([]);
});

test("正規化検索・日付表示との往復・位置復元・再読み込み", async ({ page }) => {
  await page.goto("/");
  const search = page.getByRole("searchbox");
  await search.fill("abc がっこう 1 kg");
  await expect(page.locator(".records li")).toHaveCount(1);
  await expect(page.locator(".records")).toContainText("ＡＢＣ ｶﾞｯｺｳ ① ㎏");
  await search.fill("かたかな");
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(
    page.getByRole("button", { name: "この日の前後を見る" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(400);
  await page.locator(".records li").nth(300).scrollIntoViewIfNeeded();
  const focus = await page
    .locator(".records li")
    .evaluateAll(
      (es) => es.find((e) => e.getBoundingClientRect().bottom > 0)?.id,
    );
  // Submit the public HTML form without scrolling the reading position away first.
  await page
    .locator("form")
    .evaluate((form: HTMLFormElement) => form.requestSubmit());
  await expect(search).toHaveValue("");
  await expect(page.locator(".records li")).toHaveCount(200);
  await page.goBack();
  await expect(search).toHaveValue("かたかな");
  await expect(page.locator(".records li")).toHaveCount(400);
  await expect
    .poll(() =>
      page
        .locator(".records li")
        .evaluateAll(
          (es) => es.find((e) => e.getBoundingClientRect().bottom > 0)?.id,
        ),
    )
    .toBe(focus);
  await page.goForward();
  await expect(search).toHaveValue("");
  await expect(page.locator(".records li")).toHaveCount(200);
  await page.reload();
  await expect(page.locator(".records li").first()).toHaveAttribute(
    "id",
    "row-1",
  );
});

test("描画前にフレームが進んでも戻る位置を復元する", async ({ page }) => {
  await page.goto("/?start=2026-11-10&end=2026-11-10&q=かたかな");
  await expect(page.locator(".records li")).toHaveCount(200);
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(400);
  await page.locator(".records li").nth(300).scrollIntoViewIfNeeded();
  const focus = await page
    .locator(".records li")
    .evaluateAll(
      (es) => es.find((e) => e.getBoundingClientRect().bottom > 0)?.id,
    );
  await page
    .locator("form")
    .evaluate((form: HTMLFormElement) => form.requestSubmit());
  await expect(page.getByRole("searchbox")).toHaveValue("");
  await expect(page.locator(".records li")).toHaveCount(200);
  // Force a frame before React's scheduled commit, as observed on a busy runner.
  await page.evaluate(() => {
    window.requestAnimationFrame = (callback) => {
      queueMicrotask(() => callback(performance.now()));
      return 0;
    };
  });
  await page.goBack();
  await expect(page.locator(".records li")).toHaveCount(400);
  await expect
    .poll(() =>
      page
        .locator(".records li")
        .evaluateAll(
          (es) => es.find((e) => e.getBoundingClientRect().bottom > 0)?.id,
        ),
    )
    .toBe(focus);
});

test("IME・古い検索応答・検索クリア", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  const search = page.getByRole("searchbox");
  const queries: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("/api/records?"))
      queries.push(new URL(r.url()).searchParams.get("q") || "");
  });
  await search.dispatchEvent("compositionstart");
  await search.fill("がっこう");
  await page.waitForTimeout(400);
  expect(queries).not.toContain("がっこう");
  await search.dispatchEvent("compositionend");
  await expect(page.locator(".records li")).toHaveCount(1);
  const received = deferred(),
    gate = deferred(),
    completed = deferred();
  await page.route("**/api/records?**", async (route) => {
    if (new URL(route.request().url()).searchParams.get("q") !== "slow") {
      await route.continue();
      return;
    }
    received.resolve();
    await gate.promise;
    try {
      await route.fulfill({
        json: { items: [], valid: [], cursor: null, icons: {} },
      });
    } finally {
      completed.resolve();
    }
  });
  try {
    await search.fill("slow");
    await received.promise;
    await search.fill("がっこう");
    await search.press("Enter");
    await expect(page.locator(".records li")).toHaveCount(1);
    gate.resolve();
    await completed.promise;
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".records")).toContainText("ＡＢＣ");
    await search.fill(" ");
    await expect(page).not.toHaveURL(/[?&]q=/);
    await expect(page.locator(".records li")).toHaveCount(200);
  } finally {
    gate.resolve();
  }
});

test("保存文字列を実行せずDB・設定を配信しない", async ({ page, request }) => {
  await page.goto("/");
  await page.getByRole("searchbox").fill("script");
  await expect(page.locator(".records li")).toHaveCount(1);
  await expect(page.locator(".records")).toContainText("</script>");
  await page.locator(".record").first().click();
  await expect(page.getByRole("dialog").getByRole("link")).toHaveCount(0);
  expect(await page.evaluate(() => Object.hasOwn(window, "pwned"))).toBe(false);
  for (const path of [
    "/history.db",
    "/favicons.db",
    "/config.toml",
    "/tests/fixtures/writer-1.4.0-empty.sqlite",
  ])
    expect((await request.get(path)).status()).toBe(404);
});

test("未対応のSVGアイコンを配信せず外部画像にも接続しない", async ({ page }) => {
  mutate("UPDATE icons SET mime='image/svg+xml', image=X'3C7376673E' WHERE site='example.test'");
  const remote: string[] = [];
  page.on("request", (r) => { if (new URL(r.url()).hostname === "example.invalid") remote.push(r.url()); });
  await page.goto("/");
  await expect(page.locator(".favicon.fallback").first()).toBeVisible();
  await page.waitForLoadState("networkidle");
  expect(await page.evaluate(() => Object.hasOwn(window, "pwned"))).toBe(false);
  expect(remote).toEqual([]);
});

test("追加取得と戻るで条件不一致・削除を再確認する", async ({
  page,
}) => {
  await page.goto("/");
  const search = page.getByRole("searchbox");
  await search.fill("かたかな");
  await expect(page.locator(".records li")).toHaveCount(200);
  mutate(
    "DELETE FROM visits WHERE id=1; UPDATE visits SET title='別の内容',norm_title='別の内容' WHERE id=2;",
  );
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(398);
  await expect(page.locator("#row-1")).toHaveCount(0);
  await expect(page.locator("#row-2")).toHaveCount(0);
  await showDay(page, "2026-11-10");
  await expect(search).toHaveValue("");
  await expect(page.locator(".records li")).toHaveCount(200);
  mutate("DELETE FROM visits WHERE id=100;");
  await page.goBack();
  await expect(search).toHaveValue("かたかな");
  await expect(page.locator(".records li")).toHaveCount(397);
  await expect(page.locator("#row-100")).toHaveCount(0);
});

for (const start of ["2026-11-08", "2026-11-07"]) {
  test(`${start}の検索前の日付・期間は履歴ごとに復元する`, async ({ page }) => {
    await page.goto(`/?start=${start}&end=2026-11-08`);
    await expect(page.getByText("該当する履歴がありません")).toBeVisible();
    const search = page.getByRole("searchbox");
    await search.fill("かたかな");
    await expect(page.locator(".records li")).toHaveCount(200);
    await showDay(page, "2026-11-10");
    await expect(search).toHaveValue("");
    await expect(page.locator(".records li")).toHaveCount(200);
    await search.fill("abc");
    await expect(page.locator(".records li")).toHaveCount(1);
    await page.goBack();
    await expect(search).toHaveValue("");
    await expect(page.locator(".records li")).toHaveCount(200);
    await page.goBack();
    await expect(search).toHaveValue("かたかな");
    await expect(page.locator(".records li")).toHaveCount(200);
    await search.fill(" ");
    await expect(page).not.toHaveURL(/[?&]q=/);
    await expect(page.getByLabel("開始日")).toHaveValue(start);
    await expect(page.getByLabel("終了日")).toHaveValue("2026-11-08");
  });
}

for (const status of [200, 404]) {
  test(`詳細の遅い${status}応答は最後の選択を上書きしない`, async ({
    page,
  }) => {
    await page.goto("/");
    await expect(page.locator(".records li")).toHaveCount(200);
    const received = deferred(),
      gate = deferred(),
      completed = deferred();
    await page.route("**/api/records/1", async (route) => {
      const response = await route.fetch();
      received.resolve();
      await gate.promise;
      try {
        if (status === 200) await route.fulfill({ response });
        else
          await route.fulfill({
            status: 404,
            json: { detail: "古い詳細のエラー" },
          });
      } finally {
        completed.resolve();
      }
    });
    try {
      await page.locator("#row-1 .record").click();
      await received.promise;
      await page.locator("#row-2 .record").click();
      const dialog = page.getByRole("dialog");
      await expect(dialog.getByRole("heading")).toHaveText("調べ物 カタカナ 2");
      gate.resolve();
      await completed.promise;
      await page.waitForLoadState("networkidle");
      await expect(dialog.getByRole("heading")).toHaveText("調べ物 カタカナ 2");
      await expect(page.getByRole("alert")).toHaveCount(0);
    } finally {
      gate.resolve();
    }
  });
}

test("今日をアプリのタイムゾーンで選び、同期後の再読み込みで新しい行を取得する", async ({
  page,
  request,
}) => {
  const status = await (await request.get("/api/status")).json();
  const now = Date.parse(status.today + "T00:10:00+09:00") / 1000;
  mutate(
    `DELETE FROM visits; INSERT INTO visits(id,source_id,generation,native_id,url,title,visit_seconds,visit_fraction,norm_title,norm_url) VALUES(1,'fixture','fixture',1,'https://example.test/old','前日の履歴',${now - 86400},0,'前日の履歴','https://example.test/old');`,
  );
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(1);
  await page.getByRole("button", { name: "今日", exact: true }).click();
  await expect(page.getByLabel("開始日")).toHaveValue(status.today);
  await expect(
    page.getByText("今日の履歴はまだ取り込まれていません"),
  ).toBeVisible();
  mutate(
    `INSERT INTO visits(id,source_id,generation,native_id,url,title,visit_seconds,visit_fraction,norm_title,norm_url) VALUES(2,'fixture','fixture',2,'https://example.test/new','今日のテスト履歴',${now},0,'今日のてすと履歴','https://example.test/new');`,
  );
  await page.getByRole("button", { name: "再読み込み" }).click();
  await expect(page.locator("#row-2")).toContainText("今日のテスト履歴");
  await expect(page.locator(".data-status")).toContainText(status.today);
});

test("連続スクロールで履歴保存とレイアウト測定を繰り返さない", async ({
  page,
}) => {
  await page.addInitScript(() => {
    (window as any).scrollProbe = { writes: 0, rects: 0 };
    const replace = history.replaceState.bind(history);
    history.replaceState = (...args) => {
      (window as any).scrollProbe.writes++;
      return replace(...args);
    };
    const rect = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function () {
      (window as any).scrollProbe.rects++;
      return rect.call(this);
    };
  });
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  await page.getByLabel("1回の表示件数").selectOption("500");
  await expect(page.locator(".records li")).toHaveCount(500);
  await page.evaluate(() => scrollTo(0, 0));
  await page.waitForTimeout(350);
  const result = await page.evaluate(async () => {
    (window as any).scrollProbe = { writes: 0, rects: 0 };
    for (let i = 0; i < 90; i++) {
      scrollBy(0, 80);
      await new Promise(requestAnimationFrame);
    }
    await new Promise((r) => setTimeout(r, 350));
    return (window as any).scrollProbe;
  });
  expect(result.writes).toBeLessThanOrEqual(3);
  expect(result.rects).toBeLessThan(500);
});

test("収集停止・失敗・未設定を正常な空結果と区別する", async ({ page }) => {
  mutate("UPDATE collection_settings SET value='0' WHERE key='enabled'; UPDATE sources SET state='failed',error='synthetic failure'");
  await page.goto("/");
  await page.getByText("収集状態", { exact: false }).click();
  await expect(page.getByText(/一時停止中/)).toBeVisible();
  await expect(page.getByText(/取得失敗/)).toBeVisible();
  await expect(page.locator(".records li")).toHaveCount(200);
  mutate("DELETE FROM visits; DELETE FROM sources; UPDATE collection_settings SET value='1' WHERE key='enabled'");
  await page.reload();
  await expect(page.getByText("保存対象が未設定です", { exact: true })).toBeVisible();
});
