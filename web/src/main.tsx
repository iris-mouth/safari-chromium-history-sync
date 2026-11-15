import { english } from "./language";
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";

type Row = {
  id: number;
  title: string;
  url: string;
  time: string;
  day: string;
  site: string | null;
  device: string | null;
  browser_type: string;
  profile_name: string;
};
type View = { start: string; end: string; q: string };
type Saved = {
  key: string;
  view: View;
  ids: number[];
  cursor: string | null;
  scroll: number;
  focus?: number;
  offset?: number;
};
type Page = {
  items: Row[];
  valid: Row[];
  cursor: string | null;
  icons: Record<string, string>;
};
type Source = {
  id: string;
  browser_type: string;
  profile_name: string;
  state: string;
  last_success: number | null;
  count: number;
  error: string | null;
};
type Status = {
  sources?: Source[];
  collection_enabled?: boolean;
  day: string;
  today: string;
  timezone: string;
  empty: boolean;
  latest_time: string | null;
};
async function api<T>(url: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(url, { signal, cache: "no-store" });
  const body = await response.json();
  if (!response.ok)
    throw new Error(
      typeof body.detail === "string"
        ? body.detail
        : "入力条件を確認してください。",
    );
  return body;
}
function fromUrl(): View {
  const p = new URLSearchParams(location.search);
  return {
    start: p.get("start") || "",
    end: p.get("end") || "",
    q: p.get("q") || "",
  };
}
function urlFor(v: View) {
  const p = new URLSearchParams({ start: v.start, end: v.end });
  if (v.q) p.set("q", v.q);
  return "/?" + p;
}
function shift(day: string, delta: number) {
  const d = new Date(day + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}
function firstVisibleRow(rows: Row[]) {
  for (const row of rows) {
    const element = document.getElementById("row-" + row.id);
    const rect = element?.getBoundingClientRect();
    if (rect && rect.bottom > 0) return { row, top: rect.top };
  }
}
function SiteIcon({ source }: { source?: string }) {
  const [failed, setFailed] = useState(false);
  return source && !failed ? (
    <img
      className="favicon"
      src={source}
      alt=""
      width="20"
      height="20"
      loading="lazy"
      decoding="async"
      onError={() => setFailed(true)}
    />
  ) : (
    <span className="favicon fallback" aria-hidden="true">
      ◇
    </span>
  );
}
function App() {
  const [preference, setPreference] = useState(() => {
    try {
      return localStorage.getItem("viewerLanguage") || "auto";
    } catch {
      return "auto";
    }
  });
  const lang =
    preference === "en" || preference === "ja"
      ? preference
      : navigator.languages
          .map((v) => v.split("-")[0])
          .find((v) => v === "en" || v === "ja") || "en";
  const t = (s: string) => (lang === "ja" ? s : (english[s] ?? s));
  useLayoutEffect(() => {
    document.documentElement.lang = lang;
    document.title = t("履歴") + " | Safari Chromium History Sync";
  }, [lang]);
  const dialog = useRef<HTMLDialogElement>(null);
  const [readyForSearch, setReadyForSearch] = useState(false);
  const invoker = useRef<HTMLElement | null>(null);
  const [view, setView] = useState<View>(fromUrl),
    [input, setInput] = useState(fromUrl().q),
    [rows, setRows] = useState<Row[]>([]);
  const [cursor, setCursor] = useState<string | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const [zone, setZone] = useState("Asia/Tokyo"),
    [empty, setEmpty] = useState(false),
    [detail, setDetail] = useState<Row | null>(null);
  const [icons, setIcons] = useState<Record<string, string>>({});
  const [pageSize, setPageSize] = useState(200);
  const [sources, setSources] = useState<Source[] | null>(null);
  const [collectionEnabled, setCollectionEnabled] = useState(true);
  const [today, setToday] = useState("");
  const [latest, setLatest] = useState<string | null>(null);
  const entryKey = useRef("");
  if (!entryKey.current)
    entryKey.current = history.state?.key || crypto.randomUUID();
  const entries = useRef(new Map<string, Saved>());
  const scrollTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  );
  const composing = useRef(false),
    timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined),
    controller = useRef<AbortController | null>(null);
  const serial = useRef(0),
    state = useRef({ view, rows, cursor }),
    restore = useRef<Saved | null>(null);
  const pendingPosition = useRef<{
    rows: Row[];
    complete: () => void;
  } | null>(null);
  const detailSerial = useRef(0),
    detailController = useRef<AbortController | null>(null);
  state.current = { view, rows, cursor };
  function save(s = state.current, write = true) {
    clearTimeout(scrollTimer.current);
    if (!s.rows.length) return;
    const visible = firstVisibleRow(s.rows);
    const saved: Saved = {
      key: entryKey.current,
      view: s.view,
      ids: s.rows.map((r) => r.id),
      cursor: s.cursor,
      scroll: scrollY,
      focus: visible?.row.id,
      offset: visible?.top,
    };
    entries.current.set(saved.key, saved);
    if (entries.current.size > 64)
      entries.current.delete(entries.current.keys().next().value!);
    if (write) history.replaceState(saved, "", urlFor(s.view));
  }
  function closeDetail() {
    detailSerial.current++;
    detailController.current?.abort();
    detailController.current = null;
    setDetail(null);
    if (dialog.current?.open) {
      dialog.current.close();
      invoker.current?.focus({ preventScroll: true });
    }
  }
  function invalidateRequests() {
    clearTimeout(timer.current);
    controller.current?.abort();
    pendingPosition.current = null;
    const request = ++serial.current;
    closeDetail();
    setBusy(false);
    return request;
  }
  function navigate(next: View, replace = false) {
    save();
    invalidateRequests();
    setError("");
    setRows([]);
    setCursor(null);
    entryKey.current = crypto.randomUUID();
    history[replace ? "replaceState" : "pushState"](
      { key: entryKey.current, view: next, ids: [], cursor: null, scroll: 0 },
      "",
      urlFor(next),
    );
    setView(next);
    setInput(next.q);
  }
  useEffect(() => {
    const abort = new AbortController();
    api<Status>("/api/status", abort.signal)
      .then((s) => {
        setSources(s.sources ?? null);
        setCollectionEnabled(s.collection_enabled ?? true);
        setZone(s.timezone);
        setEmpty(s.empty);
        setToday(s.today);
        setLatest(s.latest_time);
        if (!state.current.view.start) {
          const next = { start: s.day, end: s.day, q: state.current.view.q };
          history.replaceState(
            {
              key: entryKey.current,
              view: next,
              ids: [],
              cursor: null,
              scroll: 0,
            },
            "",
            urlFor(next),
          );
          setView(next);
        }
      })
      .catch((e) => {
        if (e.name !== "AbortError") setError(e.message);
      });
    return () => abort.abort();
  }, []);
  useEffect(() => {
    function pop(e: PopStateEvent) {
      // The browser has already selected the destination entry. Retain the
      // outgoing scroll position in memory instead of overwriting that entry.
      save(state.current, false);
      invalidateRequests();
      const stored = e.state as Saved | null;
      const saved = (stored?.key && entries.current.get(stored.key)) || stored;
      entryKey.current = saved?.key || crypto.randomUUID();
      restore.current = saved;
      const next = saved?.view || fromUrl();
      setRows([]);
      setCursor(null);
      setView(next);
      setInput(next.q);
    }
    addEventListener("popstate", pop);
    history.scrollRestoration = "manual";
    return () => removeEventListener("popstate", pop);
  }, []);
  useEffect(() => {
    if (!view.start) return;
    const saved = restore.current;
    restore.current = null;
    void load(false, saved);
  }, [view, pageSize]);
  useEffect(() => {
    const onScroll = () => {
      clearTimeout(scrollTimer.current);
      scrollTimer.current = setTimeout(() => save(), 250);
    };
    addEventListener("scroll", onScroll, { passive: true });
    return () => {
      clearTimeout(scrollTimer.current);
      removeEventListener("scroll", onScroll);
    };
  }, []);
  useLayoutEffect(() => {
    const pending = pendingPosition.current;
    if (!pending || pending.rows !== rows) return;
    pendingPosition.current = null;
    pending.complete();
  }, [rows]);
  async function load(more: boolean, saved: Saved | null = null) {
    const request = invalidateRequests();
    const ac = new AbortController();
    controller.current = ac;
    const current = state.current;
    const v = current.view;
    setBusy(true);
    setError("");
    const old = more ? current.rows : [];
    const savedIds = saved?.ids || [];
    const ids = more ? old.map((r) => r.id) : savedIds;
    const firstVisible = firstVisibleRow(old);
    try {
      // Revalidate in bounded chunks, never trust saved row content.
      let valid: Row[] = [];
      const pageIcons: Record<string, string> = {};
      let offset = 0;
      for (; offset + 1000 < ids.length; offset += 1000) {
        const p = new URLSearchParams({
          start: v.start,
          end: v.end,
          q: v.q,
          ids: ids.slice(offset, offset + 1000).join(","),
          limit: "1",
        });
        const result = await api<Page>("/api/records?" + p, ac.signal);
        valid.push(...result.valid);
        Object.assign(pageIcons, result.icons);
      }
      const p = new URLSearchParams({
        start: v.start,
        end: v.end,
        q: v.q,
        limit: String(pageSize),
      });
      if (ids.length) p.set("ids", ids.slice(offset).join(","));
      if (more && current.cursor) p.set("cursor", current.cursor);
      const result = await api<Page>("/api/records?" + p, ac.signal);
      valid.push(...result.valid);
      Object.assign(pageIcons, result.icons);
      if (request !== serial.current) return;
      let next: Row[];
      let nextCursor: string | null;
      if (saved && savedIds.length) {
        const map = new Map(valid.map((r) => [r.id, r]));
        next = savedIds.flatMap((id) => (map.has(id) ? [map.get(id)!] : []));
        if (!next.length) next = result.items;
        nextCursor = next.length && valid.length ? saved.cursor : result.cursor;
      } else if (more) {
        const map = new Map(valid.map((r) => [r.id, r]));
        next = old.flatMap((r) => (map.has(r.id) ? [map.get(r.id)!] : []));
        const seen = new Set(next.map((r) => r.id));
        next.push(...result.items.filter((r) => !seen.has(r.id)));
        nextCursor = result.cursor;
      } else {
        next = result.items;
        nextCursor = result.cursor;
      }
      setCursor(nextCursor);
      setIcons((previous) =>
        Object.fromEntries(
          [
            ...new Set(
              next.map((r) => r.site).filter((site): site is string => !!site),
            ),
          ].flatMap((site) => {
            const icon = pageIcons[site] || previous[site];
            return icon ? [[site, icon]] : [];
          }),
        ),
      );
      const snapshot = { view: v, rows: next, cursor: nextCursor };
      // A frame can precede React's commit. Position and save only once these
      // exact rows exist in the DOM, including short lists that never scroll.
      pendingPosition.current = {
        rows: next,
        complete: () => {
          if (request !== serial.current) return;
          if (saved) {
            const id =
              saved.focus && next.some((r) => r.id === saved.focus)
                ? saved.focus
                : next.find(
                    (r) =>
                      savedIds.indexOf(r.id) >=
                      savedIds.indexOf(saved.focus || 0),
                  )?.id;
            const el = id ? document.getElementById("row-" + id) : null;
            if (el)
              scrollBy(0, el.getBoundingClientRect().top - (saved.offset ?? 0));
            else scrollTo(0, saved.scroll);
          } else if (more && firstVisible) {
            const remaining =
              next.find((r) => r.id === firstVisible.row.id) ||
              next.find(
                (r) =>
                  old.findIndex((o) => o.id === r.id) >=
                  old.indexOf(firstVisible.row),
              ) ||
              next[0];
            const el =
              remaining && document.getElementById("row-" + remaining.id);
            if (el)
              scrollBy(0, el.getBoundingClientRect().top - firstVisible.top);
          } else scrollTo(0, 0);
          save(snapshot);
        },
      };
      setRows(next);
    } catch (e) {
      if ((e as Error).name !== "AbortError" && request === serial.current) {
        setError((e as Error).message);
        setRows([]);
        setCursor(null);
      }
    } finally {
      if (request === serial.current) {
        setBusy(false);
        setReadyForSearch(true);
      }
    }
  }
  function search(value: string) {
    clearTimeout(timer.current);
    const q = value.trim();
    if (q === state.current.view.q) {
      void load(false);
      return;
    }
    if (!q) {
      // Search retains its original date/range in this history entry's view.
      navigate({ ...state.current.view, q: "" }, true);
      return;
    }
    const replace = Boolean(state.current.view.q);
    navigate({ ...state.current.view, q }, replace);
  }
  function typing(value: string) {
    save();
    setInput(value);
    invalidateRequests();
    setRows([]);
    setCursor(null);
    if (!composing.current)
      timer.current = setTimeout(() => search(value), 300);
  }
  async function open(row: Row) {
    closeDetail();
    invoker.current = document.querySelector<HTMLElement>(
      "#row-" + row.id + " button",
    );
    setError("");
    const generation = detailSerial.current;
    const ac = new AbortController();
    detailController.current = ac;
    try {
      const item = await api<Row>("/api/records/" + row.id, ac.signal);
      if (generation === detailSerial.current) setDetail(item);
    } catch (e) {
      if (
        (e as Error).name !== "AbortError" &&
        generation === detailSerial.current
      ) {
        setError((e as Error).message);
        setDetail(null);
      }
    } finally {
      if (generation === detailSerial.current) detailController.current = null;
    }
  }
  useEffect(() => {
    if (!detail) return;
    const node = dialog.current;
    node?.showModal();
    return () => node?.close();
  }, [detail]);
  const safeUrl =
    detail && /^https?:\/\//i.test(detail.url) ? detail.url : null;
  return (
    <>
      <main>
        <header className="mast">
          <h1>{t("履歴")}</h1>
          <label>
            {lang === "ja" ? "表示言語" : "Language"}{" "}
            <select
              value={preference}
              onChange={(e) => {
                const v = e.target.value;
                setPreference(v);
                try {
                  localStorage.setItem("viewerLanguage", v);
                } catch {}
              }}
            >
              <option value="auto">
                {lang === "ja" ? "自動" : "Automatic"}
              </option>
              <option value="ja">日本語</option>
              <option value="en">English</option>
            </select>
          </label>
        </header>
        <section className="controls" aria-label={t("履歴の条件")}>
          <label className="search">
            {t("全期間を検索")}
            <input
              type="search"
              disabled={!readyForSearch}
              placeholder={t("タイトルやURLから探す")}
              value={input}
              onChange={(e) => typing(e.target.value)}
              onCompositionStart={() => {
                composing.current = true;
                invalidateRequests();
              }}
              onCompositionEnd={(e) => {
                composing.current = false;
                typing(e.currentTarget.value);
              }}
              onKeyDown={(e) => {
                if (
                  e.key === "Enter" &&
                  !e.nativeEvent.isComposing &&
                  e.nativeEvent.keyCode !== 229 &&
                  !composing.current
                ) {
                  e.preventDefault();
                  search(e.currentTarget.value);
                }
              }}
            />
          </label>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              const data = new FormData(e.currentTarget);
              const next = {
                start: String(data.get("start")),
                end: String(data.get("end")),
                q: "",
              };
              navigate(next);
            }}
            key={view.start + view.end}
          >
            <div className="date-fields">
              <label>
                {t("開始日")}
                <input
                  aria-label={t("開始日")}
                  type="date"
                  name="start"
                  defaultValue={view.start}
                  required
                />
              </label>
              <span>—</span>
              <label>
                {t("終了日")}
                <input
                  aria-label={t("終了日")}
                  type="date"
                  name="end"
                  defaultValue={view.end}
                  required
                />
              </label>
              <button type="submit">{t("表示")}</button>
            </div>
          </form>
          <div className="data-status">
            {latest
              ? `${lang === "ja" ? "取り込み済みの最新" : "Latest visit"}: ${latest.slice(0, 10)} ${latest.slice(11, 16)}`
              : t("取り込み済みの履歴なし")}
          </div>
          {sources && (
            <details className="source-status">
              <summary>
                {t("収集状態")} {collectionEnabled ? "" : t("（一時停止中）")}
              </summary>
              {sources.length === 0 ? (
                <p>{t("保存対象が未設定です。")}</p>
              ) : (
                <ul>
                  {sources.map((source) => (
                    <li key={source.id}>
                      {source.browser_type} {source.profile_name}：
                      {source.state === "complete"
                        ? t("取得完了")
                        : source.state === "collecting"
                          ? t("取り込み中")
                          : source.state === "waiting"
                            ? t("ブラウザの履歴を読み取れるまで待機中")
                            : source.state === "failed"
                              ? t("取得失敗")
                              : t("未完了")}
                      ({lang === "ja" ? "保存件数" : "Saved visits"}{" "}
                      {source.count},{" "}
                      {lang === "ja" ? "最終成功" : "Last collected"}{" "}
                      {source.last_success
                        ? new Date(source.last_success * 1000).toLocaleString(
                            lang,
                            { timeZone: "Asia/Tokyo" },
                          )
                        : t("なし")}
                      )
                    </li>
                  ))}
                </ul>
              )}
            </details>
          )}
          <nav aria-label={t("日付移動")}>
            <button
              disabled={!view.start}
              onClick={() =>
                navigate({
                  start: shift(view.start, -1),
                  end: shift(view.start, -1),
                  q: "",
                })
              }
            >
              {t("← 前日")}
            </button>
            <button
              disabled={!today}
              onClick={() => navigate({ start: today, end: today, q: "" })}
            >
              {t("今日")}
            </button>
            <span>{zone}</span>
            <button
              disabled={!view.start}
              onClick={() =>
                navigate({
                  start: shift(view.start, 1),
                  end: shift(view.start, 1),
                  q: "",
                })
              }
            >
              {t("翌日 →")}
            </button>
          </nav>
        </section>
        <section aria-label={t("履歴一覧")} aria-busy={busy}>
          <div className="list-heading">
            <h2>
              {view.q
                ? lang === "ja"
                  ? `「${view.q}」の検索結果`
                  : `Results for “${view.q}”`
                : view.start === view.end
                  ? view.start
                  : `${view.start} — ${view.end}`}
            </h2>
            <label className="page-size">
              {t("件数")}
              <select
                aria-label={t("1回の表示件数")}
                value={pageSize}
                onChange={(e) => {
                  save();
                  setPageSize(Number(e.target.value));
                }}
              >
                <option value="100">100</option>
                <option value="200">200</option>
                <option value="500">500</option>
              </select>
            </label>
            <button
              onClick={() => {
                api<Status>("/api/status")
                  .then((s) => {
                    setSources(s.sources ?? null);
                    setCollectionEnabled(s.collection_enabled ?? true);
                    setLatest(s.latest_time);
                    setToday(s.today);
                    setEmpty(s.empty);
                  })
                  .catch(() => {});
                void load(false);
              }}
            >
              {t("再読み込み")}
            </button>
          </div>
          {error && (
            <div role="alert" className="error">
              {t(error)}
            </div>
          )}
          {!busy && !error && !rows.length && (
            <div className="empty">
              {empty
                ? sources?.length === 0
                  ? t("保存対象が未設定です")
                  : !collectionEnabled
                    ? t("取り込みは一時停止中です")
                    : sources?.some((s) => s.state !== "complete")
                      ? t("取り込みは完了していません")
                      : t("参照できる履歴がありません")
                : !view.q && view.start === today && view.end === today
                  ? t("今日の履歴はまだ取り込まれていません")
                  : t("該当する履歴がありません")}
            </div>
          )}
          <ol className="records">
            {rows.map((row) => (
              <li id={"row-" + row.id} key={row.id}>
                <button className="record" onClick={() => void open(row)}>
                  <time dateTime={row.time}>
                    {view.q || view.start !== view.end ? (
                      <small>{row.day}</small>
                    ) : null}
                    {row.time.slice(11, 19)}
                  </time>
                  <SiteIcon
                    key={icons[row.site || ""] || row.site || ""}
                    source={icons[row.site || ""]}
                  />
                  <span className="record-text">
                    <strong>{row.title || t("（タイトルなし）")}</strong>
                    <span>{row.site || t("サイト情報なし")}</span>
                  </span>
                  <span aria-hidden="true">›</span>
                </button>
              </li>
            ))}
          </ol>
          {busy && (
            <p role="status" className="empty">
              {t("読み込み中…")}
            </p>
          )}
          {cursor && !busy && (
            <button className="more" onClick={() => void load(true)}>
              {t("さらに読み込む")}
            </button>
          )}
        </section>
      </main>
      {detail && (
        <dialog
          ref={dialog}
          onCancel={closeDetail}
          onClick={(e) => {
            if (e.target === e.currentTarget) {
              const b = e.currentTarget.getBoundingClientRect();
              if (
                e.clientX < b.left ||
                e.clientX > b.right ||
                e.clientY < b.top ||
                e.clientY > b.bottom
              )
                closeDetail();
            }
          }}
          className="details"
          role="dialog"
          aria-modal="true"
          aria-label={t("履歴の詳細")}
        >
          <button autoFocus className="close" onClick={closeDetail}>
            {t("閉じる ×")}
          </button>
          <h2>{detail.title || t("（タイトルなし）")}</h2>
          <dl>
            <dt>{t("日時")}</dt>
            <dd>
              {detail.day} {detail.time.slice(11, 19)} ({zone})
            </dd>
            <dt>{t("ブラウザ")}</dt>
            <dd>
              {detail.browser_type} {detail.profile_name}
            </dd>
            <dt>{t("端末")}</dt>
            <dd>{detail.device || t("端末情報なし")}</dd>
            <dt>URL</dt>
            <dd>
              {safeUrl ? (
                <a href={safeUrl} target="_blank" rel="noopener noreferrer">
                  {detail.url} ↗
                </a>
              ) : (
                detail.url
              )}
            </dd>
          </dl>
        </dialog>
      )}
    </>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
