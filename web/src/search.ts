export type Scope =
  { kind: "all" } | { kind: "range"; start: string | null; end: string | null };
export type View = { scope: Scope; q: string };
export type Draft = { start: string; end: string; q: string };
export const firstDay = "0001-01-01";
export const lastDay = "9999-12-30";
export function isDay(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
    value < firstDay ||
    value > lastDay
  )
    return false;
  const date = new Date(`${value}T00:00:00Z`);
  return (
    Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
  );
}
export function rangeScope(start: unknown, end: unknown): Scope | null {
  if ((start !== null && !isDay(start)) || (end !== null && !isDay(end)))
    return null;
  if (start === null && end === null) return null;
  if (start !== null && end !== null && start > end) return null;
  return { kind: "range", start, end };
}
export function dayView(day: string, q = ""): View {
  return { scope: { kind: "range", start: day, end: day }, q };
}
export function draftFor(view: View): Draft {
  return {
    start: view.scope.kind === "range" ? (view.scope.start ?? "") : "",
    end: view.scope.kind === "range" ? (view.scope.end ?? "") : "",
    q: view.q,
  };
}
export function viewFor(draft: Draft): View | null {
  const scope: Scope | null =
    draft.start || draft.end
      ? rangeScope(draft.start || null, draft.end || null)
      : { kind: "all" };
  return scope && { scope, q: draft.q.trim() };
}
export function sameView(a: View, b: View) {
  return (
    a.q === b.q &&
    (a.scope.kind === "all"
      ? b.scope.kind === "all"
      : b.scope.kind === "range" &&
        a.scope.start === b.scope.start &&
        a.scope.end === b.scope.end)
  );
}
export function shift(day: string, delta: number) {
  const date = new Date(`${day}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}
export function todayInTokyo() {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const value = (type: string) => parts.find((p) => p.type === type)!.value;
  return `${value("year")}-${value("month")}-${value("day")}`;
}
export function scopeLabel(scope: Scope, locale: string) {
  if (scope.kind === "all") return locale === "ja" ? "全期間" : "All time";
  const { start, end } = scope;
  if (start && end) return start === end ? start : `${start} – ${end}`;
  if (start) return locale === "ja" ? `${start} 以降` : `From ${start}`;
  return locale === "ja" ? `${end} まで` : `Through ${end}`;
}
