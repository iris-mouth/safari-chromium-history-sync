import React, { useRef, useState } from "react";
import {
  Draft,
  View,
  draftFor,
  firstDay,
  isDay,
  lastDay,
  sameView,
  shift,
  todayInTokyo,
  viewFor,
} from "./search";
import "./search-form.css";

type Translation = (value: string) => string;
type Field = keyof Draft;
type Validation = { field: Field; message: string };

function Clear({
  label,
  visible,
  onClick,
}: {
  label: string;
  visible: boolean;
  onClick: () => void;
}) {
  return visible ? (
    <button
      className="field-clear"
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
    >
      <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
        <path
          d="m6 6 12 12M18 6 6 18"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
        />
      </svg>
    </button>
  ) : (
    <span className="clear-slot" aria-hidden="true" />
  );
}

function DateField({
  name,
  value,
  error,
  t,
  onChange,
  onClear,
}: {
  name: "start" | "end";
  value: string;
  error?: Validation;
  t: Translation;
  onChange: (value: string) => void;
  onClear: () => void;
}) {
  const label = t(name === "start" ? "開始日" : "終了日");
  const id = `date-${name}`;
  return (
    <div className="date-field" role="group" aria-labelledby={`${id}-label`}>
      <label id={`${id}-label`} htmlFor={id}>
        {label}
      </label>
      <div className="date-steps">
        <button
          type="button"
          disabled={!isDay(value) || value <= firstDay}
          onClick={() => onChange(shift(value, -1))}
        >
          {t("前日")}
        </button>
        <button type="button" onClick={() => onChange(todayInTokyo())}>
          {t("今日")}
        </button>
        <button
          type="button"
          disabled={!isDay(value) || value >= lastDay}
          onClick={() => onChange(shift(value, 1))}
        >
          {t("翌日")}
        </button>
      </div>
      <div
        className={`field-shell date-shell ${error?.field === name ? "field-invalid" : ""}`}
      >
        <div className="date-picker">
          <span className="date-value" aria-hidden="true">
            <span>{value || t("指定なし")}</span>
          </span>
          <input
            id={id}
            name={name}
            type="date"
            min={firstDay}
            max={lastDay}
            value={value}
            aria-invalid={error?.field === name || undefined}
            aria-describedby={
              error?.field === name ? "filter-error" : undefined
            }
            onChange={(event) => onChange(event.currentTarget.value)}
          />
        </div>
        <Clear
          label={t(name === "start" ? "開始日を解除" : "終了日を解除")}
          visible={!!value}
          onClick={onClear}
        />
      </div>
    </div>
  );
}

export function SearchForm({
  initialView,
  displayed,
  pending,
  busy,
  failed,
  t,
  onSearch,
}: {
  initialView: View;
  displayed: View | null;
  pending: View | null;
  busy: boolean;
  failed: boolean;
  t: Translation;
  onSearch: (view: View) => void;
}) {
  const [draft, setDraft] = useState(() => draftFor(initialView));
  const [error, setError] = useState<Validation>();
  const form = useRef<HTMLFormElement>(null);
  const search = useRef<HTMLButtonElement>(null);
  const composing = useRef(false);
  function change(field: Field, value: string) {
    setDraft((previous) => ({ ...previous, [field]: value }));
    setError(undefined);
  }
  function submit(next: Draft, cleared?: Field) {
    if (composing.current) return;
    const normalized = { ...next, q: next.q.trim() };
    setDraft(normalized);
    let invalid: Validation | undefined;
    for (const field of ["start", "end"] as const) {
      const control = form.current?.elements.namedItem(
        field,
      ) as HTMLInputElement | null;
      if (
        (field !== cleared && control && !control.validity.valid) ||
        (next[field] && !isDay(next[field]))
      ) {
        invalid = { field, message: "日付が不正です。" };
        break;
      }
    }
    if (!invalid && next.start && next.end && next.start > next.end)
      invalid = { field: "end", message: "終了日は開始日以降にしてください。" };
    const view = viewFor(normalized);
    if (invalid || !view) {
      const problem = invalid ?? {
        field: "start" as const,
        message: "日付が不正です。",
      };
      setError(problem);
      (
        form.current?.elements.namedItem(
          problem.field,
        ) as HTMLInputElement | null
      )?.focus();
      return;
    }
    setError(undefined);
    onSearch(view);
    if (cleared) search.current?.focus({ preventScroll: true });
  }
  const parsed = viewFor(draft);
  const changed = !parsed || !displayed || !sameView(parsed, displayed);
  const editedDuringSearch = pending && (!parsed || !sameView(parsed, pending));
  return (
    <search>
      <form
        ref={form}
        className="search-form"
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          submit(draft);
        }}
      >
        <fieldset className="period-area">
          <legend className="sr-only">{t("期間")}</legend>
          <div className="period-grid">
            {(["start", "end"] as const).map((name) => (
              <DateField
                key={name}
                name={name}
                value={draft[name]}
                t={t}
                error={error}
                onChange={(value) => change(name, value)}
                onClear={() => submit({ ...draft, [name]: "" }, name)}
              />
            ))}
          </div>
        </fieldset>
        <div className="keyword-area">
          <label htmlFor="keyword">{t("キーワード（任意）")}</label>
          <div className="field-shell keyword-shell">
            <input
              id="keyword"
              type="search"
              name="q"
              value={draft.q}
              maxLength={1000}
              enterKeyHint="search"
              autoComplete="off"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              placeholder={t("タイトルやURLから探す")}
              onChange={(event) => change("q", event.currentTarget.value)}
              onCompositionStart={() => {
                composing.current = true;
              }}
              onCompositionEnd={() => {
                composing.current = false;
              }}
              onKeyDown={(event) => {
                if (
                  event.key === "Enter" &&
                  (composing.current ||
                    event.nativeEvent.isComposing ||
                    event.nativeEvent.keyCode === 229)
                )
                  event.preventDefault();
              }}
            />
            <Clear
              label={t("キーワードを解除")}
              visible={!!draft.q}
              onClick={() => submit({ ...draft, q: "" }, "q")}
            />
          </div>
        </div>
        <div className="search-actions">
          <button ref={search} className="search-submit" type="submit">
            {t("検索")}
          </button>
          <div
            className="search-state"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            {busy
              ? t(displayed ? "検索中・前回の結果を表示しています" : "検索中…")
              : failed
                ? t("検索に失敗しました")
                : changed
                  ? t("条件変更あり・検索で反映")
                  : t("入力条件を表示中")}
            {busy && editedDuringSearch && (
              <span>{t("条件変更あり・検索で反映")}</span>
            )}
          </div>
        </div>
        {error && (
          <p id="filter-error" className="filter-error" role="alert">
            {t(error.message)}
          </p>
        )}
      </form>
    </search>
  );
}
