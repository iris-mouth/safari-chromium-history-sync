import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { test, expect, type Page } from "@playwright/test";

test.use({ timezoneId: "America/Los_Angeles" });
const fixturePath = join(process.env.HISTORY_WEB_TEST_DIR!, "history.sqlite");
test.beforeEach(() => {
  execFileSync("python3", ["scripts/browser-fixture.py", fixturePath]);
});
function mutate(sql: string) {
  execFileSync("python3", [
    "-c",
    "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit(); c.close()",
    fixturePath,
    sql,
  ]);
}
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function showDay(page: Page, start: string, end = start) {
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill(start);
  await page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"))
    .fill(end);
  await page.getByRole("searchbox").fill("");
  await page.getByRole("button", { name: "検索", exact: true }).click();
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
  await expect(page).toHaveURL("/");
  await expect(
    page.getByRole("heading", { name: "2026-11-10", exact: true }),
  ).toBeVisible();
  await expect(page.locator(".date-value")).toHaveText([
    "2026-11-10",
    "2026-11-10",
  ]);
  await expect(page.locator(".data-status")).toHaveText(
    "最新の履歴: 2026-11-10 09:00",
  );
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
  await expect(page.getByRole("dialog").locator("dd").first()).toHaveText(
    "2026-11-10 09:00:00 (Asia/Tokyo)",
  );
  await expect(page.getByRole("dialog").getByRole("link")).toHaveAttribute(
    "target",
    "_blank",
  );
  await page.getByRole("button", { name: "閉じる" }).click();
  await page
    .getByRole("group", { name: "開始日", exact: true })
    .getByRole("button", { name: "翌日", exact: true })
    .click();
  await page
    .getByRole("group", { name: "終了日", exact: true })
    .getByRole("button", { name: "翌日", exact: true })
    .click();
  await page.getByRole("button", { name: "検索", exact: true }).click();
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
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("");
  await page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"))
    .fill("");
  const search = page.getByRole("searchbox");
  await search.fill("abc がっこう 1 kg");
  await search.press("Enter");
  await expect(page.locator(".records li")).toHaveCount(1);
  await expect(page.locator(".records")).toContainText("ＡＢＣ ｶﾞｯｺｳ ① ㎏");
  await search.fill("かたかな");
  await search.press("Enter");
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(
    page.getByRole("button", { name: "この日の前後を見る" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(400);
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-10");
  await page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-10");
  await search.fill("");
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
  await expect(page).toHaveURL("/");
  await page.goBack();
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("");
  await expect(
    page.getByLabel("終了日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("");
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
  await page.goBack();
  await expect(page.locator(".records li")).toHaveCount(400);
  mutate(`
    INSERT INTO visits(id,source_id,generation,native_id,url,title,visit_seconds,visit_fraction,norm_title,norm_url)
    SELECT 1201,source_id,generation,1201,'https://example.test/new','カタカナ 新着',visit_seconds+60,0,'かたかな 新着','https://example.test/new'
    FROM visits WHERE id=1;
    INSERT INTO visits(id,source_id,generation,native_id,url,title,visit_seconds,visit_fraction,norm_title,norm_url)
    SELECT 1202,source_id,generation,1202,'https://example.test/late','カタカナ 遅着',visit_seconds,0.5,'かたかな 遅着','https://example.test/late'
    FROM visits WHERE id=250;
  `);
  const reloadFocus = await page.locator(".records li").evaluateAll((es) => {
    es[275].scrollIntoView();
    return es.find((e) => e.getBoundingClientRect().bottom > 0)?.id;
  });
  await page.reload();
  await expect(page).toHaveURL("/");
  await expect(search).toHaveValue("かたかな");
  await expect(page.locator(".records li")).toHaveCount(400);
  await expect(page.locator(".records li").first()).toHaveAttribute(
    "id",
    "row-1201",
  );
  await expect(page.locator("#row-1202")).toBeVisible();
  await expect
    .poll(() =>
      page
        .locator(".records li")
        .evaluateAll(
          (es) => es.find((e) => e.getBoundingClientRect().bottom > 0)?.id,
        ),
    )
    .toBe(reloadFocus);
});

test("描画前にフレームが進んでも戻る位置を復元する", async ({ page }) => {
  await page.goto("/?start=2026-11-10&end=2026-11-10&q=かたかな");
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(page).toHaveURL("/");
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("");
  await expect(
    page.getByLabel("終了日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("");
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await expect(page.locator(".records li")).toHaveCount(400);
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-10");
  await page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-10");
  await page.getByRole("searchbox").fill("");
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
  await search.press("Enter");
  await page.waitForTimeout(400);
  expect(queries).not.toContain("がっこう");
  await search.dispatchEvent("compositionend");
  expect(
    await search.evaluate((input) => {
      const event = new KeyboardEvent("keydown", {
        key: "Enter",
        keyCode: 229,
        bubbles: true,
        cancelable: true,
      });
      return input.dispatchEvent(event);
    }),
  ).toBe(false);
  expect(queries).not.toContain("がっこう");
  await search.press("Enter");
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
    await search.press("Enter");
    await received.promise;
    await search.fill("がっこう");
    await search.press("Enter");
    await expect(page.locator(".records li")).toHaveCount(1);
    gate.resolve();
    await completed.promise;
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".records")).toContainText("ＡＢＣ");
    await search.fill(" ");
    await expect(page.locator(".records li")).toHaveCount(1);
    await search.press("Enter");
    await expect(page).toHaveURL("/");
    await expect(page.locator(".records li")).toHaveCount(200);
  } finally {
    gate.resolve();
  }
});

test("保存文字列を実行せずDB・設定を配信しない", async ({ page, request }) => {
  await page.goto("/");
  await page.getByRole("searchbox").fill("script");
  await page.getByRole("searchbox").press("Enter");
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

test("未対応のSVGアイコンを配信せず外部画像にも接続しない", async ({
  page,
}) => {
  mutate(
    "UPDATE icons SET mime='image/svg+xml', image=X'3C7376673E' WHERE site='example.test'",
  );
  const remote: string[] = [];
  page.on("request", (r) => {
    if (new URL(r.url()).hostname === "example.invalid") remote.push(r.url());
  });
  await page.goto("/");
  await expect(page.locator(".favicon.fallback").first()).toBeVisible();
  await page.waitForLoadState("networkidle");
  expect(await page.evaluate(() => Object.hasOwn(window, "pwned"))).toBe(false);
  expect(remote).toEqual([]);
});

test("追加取得と戻るで条件不一致・削除を再確認する", async ({ page }) => {
  await page.goto("/");
  const search = page.getByRole("searchbox");
  await search.fill("かたかな");
  await search.press("Enter");
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

test("範囲指定とキーワードは独立し実行時にだけ適用される", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  const search = page.getByRole("searchbox");
  const run = page.getByRole("button", { name: "検索", exact: true });
  const requests: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("/api/records?")) requests.push(r.url());
  });

  await search.fill("かたかな 1200");
  await page.waitForTimeout(350);
  expect(requests).toHaveLength(0);
  await expect(page.locator(".records li")).toHaveCount(200);
  await run.click();
  await expect(page.getByText("該当する履歴がありません")).toBeVisible();

  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("");
  await page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"))
    .fill("");
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("");
  await expect(search).toHaveValue("かたかな 1200");
  await expect(page.getByText("該当する履歴がありません")).toBeVisible();
  await run.click();
  await expect(page.locator(".records li")).toHaveCount(1);
  await expect(page.locator("#row-1200")).toBeVisible();

  await search.fill(" ");
  await run.click();
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(
    page.getByRole("heading", { name: "全期間", exact: true }),
  ).toBeVisible();
  await expect(page).toHaveURL("/");
  expect(requests.map((url) => new URL(url).searchParams.get("scope"))).toEqual(
    ["range", "all", "all"],
  );
  expect(new URL(requests[2]).searchParams.has("q")).toBe(false);

  await page.goBack();
  await expect(search).toHaveValue("かたかな 1200");
  await expect(page.locator("#row-1200")).toBeVisible();
  await page.goBack();
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-10");
  await expect(page.getByText("該当する履歴がありません")).toBeVisible();
});

test("旧日付リンクを読み込み不正な期間は適用しない", async ({ page }) => {
  await page.goto("/?start=2026-11-07&end=2026-11-08");
  await expect(page).toHaveURL("/");
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-07");
  await expect(
    page.getByLabel("終了日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-08");
  await expect(page.getByText("該当する履歴がありません")).toBeVisible();
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-09");
  await page.getByRole("button", { name: "検索", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "2026-11-07 – 2026-11-08" }),
  ).toBeVisible();
  await page.reload();
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-07");
});

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
  await page
    .getByRole("group", { name: "開始日", exact: true })
    .getByRole("button", { name: "今日", exact: true })
    .click();
  await page
    .getByRole("group", { name: "終了日", exact: true })
    .getByRole("button", { name: "今日", exact: true })
    .click();
  await page.getByRole("button", { name: "検索", exact: true }).click();
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue(status.today);
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
  mutate(
    "UPDATE collection_settings SET value='0' WHERE key='enabled'; UPDATE sources SET state='failed',error='synthetic failure'",
  );
  await page.goto("/");
  await page.getByText("収集状態", { exact: false }).click();
  await expect(page.getByText(/一時停止中/)).toBeVisible();
  await expect(page.getByText(/取得失敗/)).toBeVisible();
  await expect(page.locator(".records li")).toHaveCount(200);
  mutate(
    "DELETE FROM visits; DELETE FROM sources; UPDATE collection_settings SET value='1' WHERE key='enabled'",
  );
  await page.reload();
  await expect(
    page.getByText("保存対象が未設定です", { exact: true }),
  ).toBeVisible();
});

test("changing language preserves the current view and restores focus after details", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".record").first()).toBeVisible();
  const location = page.url();
  await page.getByLabel("表示言語").selectOption("en");
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(
    page.getByLabel("Start date", { exact: true }).and(page.locator("input")),
  ).toBeVisible();
  expect(page.url()).toBe(location);
  const first = page.locator(".record").first();
  await first.focus();
  await first.press("Enter");
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(first).toBeFocused();
  await page.reload();
  await expect(page.getByLabel("Language")).toHaveValue("en");
});

test("日付の個別調整は編集のみで、解除は現在の全条件を適用する", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  const start = page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"));
  const end = page
    .getByLabel("終了日", { exact: true })
    .and(page.locator("input"));
  const keyword = page.getByRole("searchbox");
  const requests: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("/api/records?")) requests.push(r.url());
  });
  await page
    .getByRole("group", { name: "開始日", exact: true })
    .getByRole("button", { name: "前日", exact: true })
    .click();
  await expect(start).toHaveValue("2026-11-09");
  await expect(end).toHaveValue("2026-11-10");
  await keyword.fill("かたかな");
  await expect(
    page.getByText("条件変更あり・検索で反映", { exact: true }),
  ).toBeVisible();
  expect(requests).toHaveLength(0);
  await page.getByRole("button", { name: "終了日を解除", exact: true }).click();
  await expect(page.locator(".result-scope")).toHaveText("2026-11-09 以降");
  await expect(end).toHaveValue("");
  await expect(keyword).toHaveValue("かたかな");
  expect(new URL(requests.at(-1)!).searchParams.get("start")).toBe(
    "2026-11-09",
  );
  expect(new URL(requests.at(-1)!).searchParams.has("end")).toBe(false);
  await expect(
    page
      .getByRole("group", { name: "終了日", exact: true })
      .getByRole("button", { name: "翌日", exact: true }),
  ).toBeDisabled();
  await end.fill("2026-11-10");
  await page.getByRole("button", { name: "開始日を解除", exact: true }).click();
  await expect(page.locator(".result-scope")).toHaveText("2026-11-10 まで");
  await start.fill("2026-11-09");
  await page
    .getByRole("button", { name: "キーワードを解除", exact: true })
    .click();
  await expect(
    page.getByRole("heading", {
      name: "2026-11-09 – 2026-11-10",
      exact: true,
    }),
  ).toBeVisible();
  await expect(keyword).toHaveValue("");
  await expect(
    page.getByRole("button", { name: "検索", exact: true }),
  ).toBeFocused();
  await expect(page).toHaveURL("/");
});

test("不正な期間での解除は入力と前回結果を保持する", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-12");
  await page.getByRole("searchbox").fill("edit");
  await page
    .getByRole("button", { name: "キーワードを解除", exact: true })
    .click();
  await expect(page.getByRole("alert")).toHaveText(
    "終了日は開始日以降にしてください。",
  );
  await expect(
    page.getByLabel("終了日", { exact: true }).and(page.locator("input")),
  ).toBeFocused();
  await expect(page.getByRole("searchbox")).toHaveValue("");
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-12");
  await expect(page.locator(".records li")).toHaveCount(200);
  await expect(
    page.getByRole("heading", { name: "2026-11-10", exact: true }),
  ).toBeVisible();
});

test("検索中と失敗時は前回結果を保ち、追加入力を上書きしない", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  const before = await page.evaluate(() => history.length);
  const gate = deferred(),
    received = deferred();
  await page.route("**/api/records?**", async (route) => {
    const q = new URL(route.request().url()).searchParams.get("q");
    if (q === "failure") {
      await route.fulfill({
        status: 503,
        json: { detail: "履歴を読み取れません。" },
      });
      return;
    }
    if (q !== "がっこう") {
      await route.continue();
      return;
    }
    const response = await route.fetch();
    received.resolve();
    await gate.promise;
    await route.fulfill({ response });
  });
  const keyword = page.getByRole("searchbox");
  try {
    await keyword.fill("がっこう");
    await keyword.press("Enter");
    await received.promise;
    await expect(page.locator(".records li")).toHaveCount(200);
    await expect(
      page.getByRole("heading", { name: "2026-11-10", exact: true }),
    ).toBeVisible();
    await keyword.fill("次の入力");
    gate.resolve();
    await expect(page.locator(".records li")).toHaveCount(1);
    await expect(
      page.getByRole("heading", { name: /「がっこう」の検索結果/ }),
    ).toBeVisible();
    await expect(keyword).toHaveValue("次の入力");
    await expect(
      page.getByText("条件変更あり・検索で反映", { exact: true }),
    ).toBeVisible();
    await keyword.fill("failure");
    await keyword.press("Enter");
    await expect(page.getByRole("alert")).toHaveText("履歴を読み取れません。");
    await expect(page.locator(".records li")).toHaveCount(1);
    await expect(keyword).toHaveValue("failure");
    expect(await page.evaluate(() => history.length)).toBe(before + 1);
    await page.reload();
    await expect(keyword).toHaveValue("がっこう");
    await expect(page.locator(".records li")).toHaveCount(1);
  } finally {
    gate.resolve();
  }
});

test("空結果も履歴に残し、未検索の編集は復元しない", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  const keyword = page.getByRole("searchbox");
  await keyword.fill("no-match-635");
  await keyword.press("Enter");
  await expect(
    page.getByText("該当する履歴がありません", { exact: true }),
  ).toBeVisible();
  await keyword.fill("がっこう");
  await keyword.press("Enter");
  await expect(page.locator(".records li")).toHaveCount(1);
  await page.goBack();
  await expect(keyword).toHaveValue("no-match-635");
  await expect(
    page.getByText("該当する履歴がありません", { exact: true }),
  ).toBeVisible();
  await page
    .getByLabel("開始日", { exact: true })
    .and(page.locator("input"))
    .fill("2026-11-01");
  await keyword.fill("not-submitted");
  await page.reload();
  await expect(keyword).toHaveValue("no-match-635");
  await expect(
    page.getByLabel("開始日", { exact: true }).and(page.locator("input")),
  ).toHaveValue("2026-11-10");
  await expect(
    page.getByText("該当する履歴がありません", { exact: true }),
  ).toBeVisible();
});

test("日英・狭幅・文字拡大でも整列と操作領域を保つ", async ({
  page,
}, testInfo) => {
  await page.goto("/");
  await expect(page.locator(".records li")).toHaveCount(200);
  for (const lang of ["ja", "en"]) {
    await page.locator(".mast select").selectOption(lang);
    for (const [width, font] of [
      [390, 16],
      [430, 16],
      [320, 16],
      [390, 32],
      [1000, 16],
    ]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate((size) => {
        document.documentElement.style.fontSize = size + "px";
      }, font);
      const fields = page.locator(".date-field");
      const a = (await fields.nth(0).boundingBox())!,
        b = (await fields.nth(1).boundingBox())!;
      if (width >= 390 && font === 16) {
        expect(Math.abs(a.y - b.y)).toBeLessThan(1);
        expect(Math.abs(a.width - b.width)).toBeLessThan(1);
        for (const selector of ["label", ".date-steps", ".date-shell"]) {
          const c = (await fields.nth(0).locator(selector).boundingBox())!,
            d = (await fields.nth(1).locator(selector).boundingBox())!;
          expect(Math.abs(c.y - d.y)).toBeLessThan(1);
          expect(Math.abs(c.height - d.height)).toBeLessThan(1);
        }
      } else expect(b.y).toBeGreaterThanOrEqual(a.y + a.height);
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        `${lang}, width=${width}, font=${font}`,
      ).toBe(true);
      const targets = await page
        .locator(
          ".search-form button, .reload, .source-status summary, select, .search-form input",
        )
        .evaluateAll((elements) =>
          elements.map((element) => {
            const box = element.getBoundingClientRect();
            let top = box.top,
              bottom = box.bottom,
              width = box.width;
            if (element.matches("button, summary")) {
              const style = getComputedStyle(element),
                after = getComputedStyle(element, "::after");
              top = Math.min(
                top,
                box.top +
                  parseFloat(style.borderTopWidth) +
                  parseFloat(after.top),
              );
              bottom = Math.max(
                bottom,
                box.bottom -
                  parseFloat(style.borderBottomWidth) -
                  parseFloat(after.bottom),
              );
            } else if (element instanceof HTMLSelectElement) {
              const label = element.closest("label")!;
              const labelBox = label.getBoundingClientRect();
              top = labelBox.top;
              bottom = labelBox.bottom;
              width = labelBox.width;
            }
            const hitAt = (y: number) => {
              const hit = document.elementFromPoint(box.x + box.width / 2, y);
              return (
                !!hit &&
                (element.contains(hit) ||
                  (element instanceof HTMLSelectElement &&
                    element.closest("label")!.contains(hit)))
              );
            };
            return {
              name:
                element.getAttribute("aria-label") ||
                element.id ||
                element.textContent?.trim().slice(0, 24),
              width,
              height: bottom - top,
              hit: hitAt(top + 0.5) && hitAt(bottom - 0.5),
            };
          }),
        );
      const touch = await page.evaluate(
        () => matchMedia("(pointer: coarse)").matches,
      );
      for (const target of targets) {
        expect(target.width).toBeGreaterThanOrEqual(touch ? 43.99 : 23.99);
        expect(target.height).toBeGreaterThanOrEqual(touch ? 43.99 : 23.99);
        if (width === 390 && font === 16)
          expect(target.hit, target.name).toBe(true);
      }
      expect(
        await page
          .locator(".date-value > span")
          .evaluateAll((nodes) =>
            nodes.some((n) => n.scrollWidth > n.clientWidth),
          ),
      ).toBe(false);
      const firstInput = (await page.locator("#date-start").boundingBox())!;
      const clear = (await fields
        .nth(0)
        .locator(".field-clear")
        .boundingBox())!;
      expect(firstInput.x + firstInput.width).toBeLessThanOrEqual(clear.x + 1);
      if (width === 390 && font === 16) {
        expect((await page.locator(".records").boundingBox())!.y).toBeLessThan(
          440,
        );
        for (const control of await page
          .locator(
            ".date-shell, .keyword-shell, .search-submit, .date-steps button",
          )
          .all()) {
          expect((await control.boundingBox())!.height).toBeLessThanOrEqual(
            40.1,
          );
        }
        await page.screenshot({
          path: testInfo.outputPath(`form-${lang}.png`),
        });
      }
    }
  }
});
