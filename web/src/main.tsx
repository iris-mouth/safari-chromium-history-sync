import { english } from "./language";
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";

function DateField({ label, value, min, onChange }: {
  label: string;
  value: string;
  min?: string;
  onChange: (value: string) => void;
}) {
  return (
    <label>
      {label}
      <span className="date-control">
        <span className="compact-date" aria-hidden="true">{value.replaceAll("-", "/") || "—"}</span>
        <input type="date" value={value} min={min} max="9999-12-30"
          onChange={event => onChange(event.currentTarget.value)} required />
      </span>
    </label>
  );
}

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
type Scope = { kind: "all" } | { kind: "range"; start: string; end: string };
type View = { scope: Scope; q: string };
type Saved = {
  key: string;
  view: View;
  ids: number[];
  cursor: string | null;
  scroll: number;
  focus?: number;
  offset?: number;
};
type Restoration = { kind: "history" | "reload"; entry: Saved };
type Page = {
  items: Row[];
  valid: Row[];
  cursor?: string;
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
  latest_time?: string;
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
function rangeScope(start: unknown, end: unknown): Scope | null {
  return isDay(start) && isDay(end) && start <= end ? { kind: "range", start, end } : null;
}
function isDay(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value > "9999-12-30") return false;
  const day = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(day.getTime()) && day.toISOString().slice(0, 10) === value;
}
function legacyView(): View | null {
  const p = new URLSearchParams(location.search);
  const q = p.get("q")?.trim() ?? "";
  if (q) return { scope: { kind: "all" }, q };
  const scope = rangeScope(p.get("start"), p.get("end"));
  return scope && { scope, q };
}
function readSaved(value: unknown): Saved | null {
  if (typeof value !== "object" || value === null || !("view" in value) ||
      !("key" in value) || typeof value.key !== "string" ||
      !("ids" in value) || !Array.isArray(value.ids) ||
      !("cursor" in value) || (value.cursor !== null && typeof value.cursor !== "string") ||
      !("scroll" in value) || typeof value.scroll !== "number") return null;
  const view = value.view;
  if (typeof view !== "object" || view === null || !("scope" in view) ||
      !("q" in view) || typeof view.q !== "string") return null;
  const scope = view.scope;
  if (typeof scope !== "object" || scope === null || !("kind" in scope)) return null;
  const parsedScope: Scope | null = scope.kind === "all" ? { kind: "all" } :
    scope.kind === "range" && "start" in scope && "end" in scope ? rangeScope(scope.start, scope.end) : null;
  if (!parsedScope) return null;
  return {
    key: value.key,
    view: { scope: parsedScope, q: view.q },
    ids: value.ids.filter((id): id is number => typeof id === "number" && Number.isSafeInteger(id) && id > 0),
    cursor: value.cursor,
    scroll: value.scroll,
    focus: "focus" in value && typeof value.focus === "number" ? value.focus : undefined,
    offset: "offset" in value && typeof value.offset === "number" ? value.offset : undefined,
  };
}
const reloadPositionKey = "viewerReloadPosition";
function reloadPosition(saved: Saved | null): Saved | null {
  if (!saved) return null;
  try {
    const position: unknown = JSON.parse(sessionStorage.getItem(reloadPositionKey) ?? "null");
    if (Array.isArray(position) && position[0] === saved.key && typeof position[1] === "number") {
      return {
        ...saved,
        scroll: position[1],
        focus: typeof position[2] === "number" ? position[2] : undefined,
        offset: typeof position[3] === "number" ? position[3] : undefined,
      };
    }
  } catch {}
  return saved;
}
function blankEntry(key: string, view: View): Saved {
  return { key, view, ids: [], cursor: null, scroll: 0 };
}
function recordsParams({ scope, q }: View, limit: number) {
  const p = new URLSearchParams({ scope: scope.kind, limit: String(limit) });
  if (scope.kind === "range") {
    p.set("start", scope.start);
    p.set("end", scope.end);
  }
  if (q) p.set("q", q);
  return p;
}
function dayView(day: string, q = ""): View {
  return { scope: { kind: "range", start: day, end: day }, q };
}
function sameView(a: View, b: View) {
  return a.q === b.q && (a.scope.kind === "all"
    ? b.scope.kind === "all"
    : b.scope.kind === "range" && a.scope.start === b.scope.start && a.scope.end === b.scope.end);
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
function SearchForm({ view, day, t, onSearch }: {
  view: View;
  day: string;
  t: (value: string) => string;
  onSearch: (view: View) => void;
}) {
  const [kind, setKind] = useState(view.scope.kind);
  const [start, setStart] = useState(view.scope.kind === "range" ? view.scope.start : day);
  const [end, setEnd] = useState(view.scope.kind === "range" ? view.scope.end : day);
  const composing = useRef(false);
  return (
    <form role="search" onSubmit={(event) => {
      event.preventDefault();
      if (composing.current) return;
      const keyword = new FormData(event.currentTarget).get("q");
      if (typeof keyword !== "string") return;
      const scope: Scope | null = kind === "range" ? rangeScope(start, end) : { kind: "all" };
      if (scope) onSearch({ scope, q: keyword.trim() });
    }}>
      <fieldset className="search-scope">
        <legend>{t("検索範囲")}</legend>
        <label>
          <input type="radio" name="scope" checked={kind === "all"} onChange={() => setKind("all")} />
          {t("全期間")}
        </label>
        <label>
          <input type="radio" name="scope" checked={kind === "range"} onChange={() => setKind("range")} />
          {t("期間指定")}
        </label>
      </fieldset>
      <label>
        {t("キーワード（任意）")}
        <input
          type="search"
          name="q"
          enterKeyHint="search"
          defaultValue={view.q}
          placeholder={t("タイトルやURLから探す")}
          onCompositionStart={() => { composing.current = true; }}
          onCompositionEnd={() => { composing.current = false; }}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (composing.current || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229)) {
              event.preventDefault();
            }
          }}
        />
      </label>
      <div className={`date-fields ${kind === "all" ? "all-time" : ""}`}>
        {kind === "range" && <>
          <DateField label={t("開始日")} value={start} onChange={setStart} />
          <DateField label={t("終了日")} value={end} min={start} onChange={setEnd} />
        </>}
        <button type="submit">{t("検索")}</button>
      </div>
    </form>
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
  const invoker = useRef<HTMLElement | null>(null);
  const [initial] = useState(() => {
    const saved = reloadPosition(readSaved(history.state));
    const timing = performance.getEntriesByType("navigation")[0];
    const fromHistory = timing && "type" in timing && timing.type === "back_forward";
    return {
      saved,
      key: saved?.key ?? crypto.randomUUID(),
      view: saved?.view ?? legacyView(),
      restoration: saved && { kind: fromHistory ? "history" : "reload", entry: saved } satisfies Restoration,
    };
  });
  const [view, setView] = useState(initial.view),
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
  const [defaultDay, setDefaultDay] = useState("");
  const [formRevision, setFormRevision] = useState(0);
  const [latest, setLatest] = useState<string | null>(null);
  const entryKey = useRef(initial.key);
  const entries = useRef(new Map<string, Saved>());
  const scrollTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  );
  const controller = useRef<AbortController | null>(null);
  const serial = useRef(0),
    state = useRef({ view, rows, cursor }),
    restore = useRef(initial.restoration);
  const pendingPosition = useRef<{
    rows: Row[];
    complete: () => void;
  } | null>(null);
  const detailSerial = useRef(0),
    detailController = useRef<AbortController | null>(null);
  state.current = { view, rows, cursor };
  function save(s = state.current, write = true) {
    clearTimeout(scrollTimer.current);
    scrollTimer.current = undefined;
    if (!s.view || !s.rows.length) return;
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
    if (write) history.replaceState(saved, "", "/");
    return saved;
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
    controller.current?.abort();
    pendingPosition.current = null;
    const request = ++serial.current;
    closeDetail();
    setBusy(false);
    return request;
  }
  function navigate(next: View) {
    const current = state.current.view;
    if (current && sameView(current, next)) {
      void load(false);
      return;
    }
    save();
    invalidateRequests();
    setError("");
    setRows([]);
    setCursor(null);
    entryKey.current = crypto.randomUUID();
    history.pushState(blankEntry(entryKey.current, next), "", "/");
    setView(next);
  }
  function browseDay(day: string) {
    setFormRevision((revision) => revision + 1);
    navigate(dayView(day, state.current.view?.q));
  }
  function applyStatus(s: Status) {
    setSources(s.sources ?? null);
    setCollectionEnabled(s.collection_enabled ?? true);
    setZone(s.timezone);
    setEmpty(s.empty);
    setToday(s.today);
    setDefaultDay(s.day);
    setLatest(s.latest_time ?? null);
    if (!state.current.view) {
      const next = dayView(s.day);
      history.replaceState(blankEntry(entryKey.current, next), "", "/");
      setView(next);
    }
  }
  useLayoutEffect(() => {
    history.scrollRestoration = "manual";
    const saved = initial.saved ?? (initial.view && blankEntry(initial.key, initial.view));
    history.replaceState(saved, "", "/");
    try { sessionStorage.removeItem(reloadPositionKey); } catch {}
  }, []);
  useEffect(() => {
    const abort = new AbortController();
    api<Status>("/api/status", abort.signal)
      .then(applyStatus)
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
      const stored = readSaved(e.state);
      const saved = (stored?.key && entries.current.get(stored.key)) || stored;
      entryKey.current = saved?.key || crypto.randomUUID();
      restore.current = saved && { kind: "history", entry: saved };
      const next = saved?.view ?? legacyView() ?? (defaultDay ? dayView(defaultDay) : null);
      if (!stored) history.replaceState(next && blankEntry(entryKey.current, next), "", "/");
      setRows([]);
      setCursor(null);
      setView(next);
      setFormRevision((revision) => revision + 1);
    }
    addEventListener("popstate", pop);
    return () => removeEventListener("popstate", pop);
  }, [defaultDay]);
  useEffect(() => {
    if (!view) return;
    const restoration = restore.current;
    restore.current = null;
    void load(false, restoration);
  }, [view, pageSize]);
  useEffect(() => {
    const onScroll = () => {
      clearTimeout(scrollTimer.current);
      scrollTimer.current = setTimeout(() => save(), 250);
    };
    const onPageHide = () => {
      const saved = save(state.current, false);
      if (!saved) return;
      // Chromium may already have captured history.state for the reload.
      try {
        sessionStorage.setItem(reloadPositionKey, JSON.stringify([saved.key, saved.scroll, saved.focus, saved.offset]));
      } catch {}
    };
    addEventListener("scroll", onScroll, { passive: true });
    addEventListener("pagehide", onPageHide);
    return () => {
      clearTimeout(scrollTimer.current);
      removeEventListener("scroll", onScroll);
      removeEventListener("pagehide", onPageHide);
    };
  }, []);
  useLayoutEffect(() => {
    const pending = pendingPosition.current;
    if (!pending || pending.rows !== rows) return;
    pendingPosition.current = null;
    pending.complete();
  }, [rows]);
  async function load(more: boolean, restoration: Restoration | null = null) {
    const current = state.current;
    const v = current.view;
    if (!v) return;
    const request = invalidateRequests();
    const ac = new AbortController();
    controller.current = ac;
    setBusy(true);
    setError("");
    const old = more ? current.rows : [];
    const saved = restoration?.entry;
    const savedIds = saved?.ids || [];
    const ids = more ? old.map((r) => r.id) : savedIds;
    const firstVisible = firstVisibleRow(old);
    try {
      // Revalidate in bounded chunks, never trust saved row content.
      let valid: Row[] = [];
      const pageIcons: Record<string, string> = {};
      let offset = 0;
      for (; offset + 1000 < ids.length; offset += 1000) {
        const p = recordsParams(v, 1);
        p.set("ids", ids.slice(offset, offset + 1000).join(","));
        const result = await api<Page>("/api/records?" + p, ac.signal);
        valid.push(...result.valid);
        Object.assign(pageIcons, result.icons);
      }
      const p = recordsParams(v, pageSize);
      if (ids.length) p.set("ids", ids.slice(offset).join(","));
      if (more && current.cursor) p.set("cursor", current.cursor);
      const result = await api<Page>("/api/records?" + p, ac.signal);
      valid.push(...result.valid);
      Object.assign(pageIcons, result.icons);
      if (request !== serial.current) return;
      let next: Row[];
      let nextCursor = result.cursor ?? null;
      if (restoration?.kind === "reload" && saved && valid.length) {
        next = result.items;
        const seen = new Set(next.map((row) => row.id));
        const retained = new Map(valid.map((row) => [row.id, row]));
        const anchorIndex = Math.max(0, savedIds.indexOf(saved.focus ?? 0));
        const anchorId = savedIds.slice(anchorIndex).find((id) => retained.has(id));
        const anchor = anchorId === undefined ? undefined : retained.get(anchorId);
        // The anchor can disappear after revalidation. Stop after passing its time.
        let oldest = Date.parse(next.at(-1)?.time ?? "");
        const anchorTime = Date.parse(anchor?.time ?? "");
        while (nextCursor && (next.length < retained.size || (anchor && !seen.has(anchor.id) && oldest >= anchorTime))) {
          const p = recordsParams(v, pageSize);
          p.set("cursor", nextCursor);
          const page = await api<Page>("/api/records?" + p, ac.signal);
          if (request !== serial.current) return;
          for (const row of page.items) {
            if (!seen.has(row.id)) next.push(row);
            seen.add(row.id);
          }
          Object.assign(pageIcons, page.icons);
          nextCursor = page.cursor ?? null;
          oldest = Date.parse(page.items.at(-1)?.time ?? "");
        }
      } else if (saved && savedIds.length) {
        const map = new Map(valid.map((r) => [r.id, r]));
        next = savedIds.flatMap((id) => (map.has(id) ? [map.get(id)!] : []));
        if (!next.length) next = result.items;
        if (valid.length) nextCursor = saved.cursor;
      } else if (more) {
        const map = new Map(valid.map((r) => [r.id, r]));
        next = old.flatMap((r) => (map.has(r.id) ? [map.get(r.id)!] : []));
        const seen = new Set(next.map((r) => r.id));
        next.push(...result.items.filter((r) => !seen.has(r.id)));
      } else {
        next = result.items;
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
      }
    }
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
  const scope = view?.scope;
  const range = scope?.kind === "range" ? scope : null;
  const singleDay = range && range.start === range.end ? range.start : null;
  const scopeLabel = range
    ? range.start === range.end ? range.start : `${range.start} – ${range.end}`
    : scope ? t("全期間") : "";
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
          {view && defaultDay && <SearchForm key={formRevision} view={view} day={defaultDay} t={t} onSearch={navigate} />}
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
              disabled={!singleDay}
              onClick={() => singleDay && browseDay(shift(singleDay, -1))}
            >
              {t("← 前日")}
            </button>
            <button
              disabled={!today}
              onClick={() => browseDay(today)}
            >
              {t("今日")}
            </button>
            <span>{zone}</span>
            <button
              disabled={!singleDay}
              onClick={() => singleDay && browseDay(shift(singleDay, 1))}
            >
              {t("翌日 →")}
            </button>
          </nav>
        </section>
        <section aria-label={t("履歴一覧")} aria-busy={busy}>
          <div className="list-heading">
            <h2>
              {view?.q
                ? lang === "ja"
                  ? `「${view.q}」の検索結果`
                  : `Results for “${view.q}”`
                : scopeLabel}
              {view?.q && <small className="result-scope">{scopeLabel}</small>}
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
                  .then(applyStatus)
                  .catch((e) => { if (!state.current.view) setError(e.message); });
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
          {view && !busy && !error && !rows.length && (
            <div className="empty">
              {empty
                ? sources?.length === 0
                  ? t("保存対象が未設定です")
                  : !collectionEnabled
                    ? t("取り込みは一時停止中です")
                    : sources?.some((s) => s.state !== "complete")
                      ? t("取り込みは完了していません")
                      : t("参照できる履歴がありません")
                : !view.q && singleDay === today
                  ? t("今日の履歴はまだ取り込まれていません")
                  : t("該当する履歴がありません")}
            </div>
          )}
          <ol className="records">
            {rows.map((row) => (
              <li id={"row-" + row.id} key={row.id}>
                <button className="record" onClick={() => void open(row)}>
                  <time dateTime={row.time}>
                    {view?.q || !singleDay ? (
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
