export function visitSort(a, b) {
  if (b.visitTime !== a.visitTime) return b.visitTime - a.visitTime;
  return String(b.visitId).localeCompare(String(a.visitId), undefined, { numeric: true });
}

export function orderedRecentVisits(visits) {
  return [...visits].sort(visitSort).slice(0, 64);
}

export function unseenVisitsAfterMarker(visits, marker) {
  const markerIndex = visits.findIndex((visit) => String(visit.visitId) === String(marker));
  return marker ? visits.slice(0, markerIndex < 0 ? 1 : markerIndex) : visits.slice(0, 1);
}

export function hasPendingImport(pendingEvidence, url) {
  return Object.values(pendingEvidence).some((pending) => pending.url === url);
}

export function importedVisitEvidence(visits, pending) {
  const before = new Set(pending.preVisitIds);
  const candidates = visits.filter((visit) =>
    !before.has(String(visit.visitId)) && visit.visitTime >= pending.requestedAt - 1_000);
  return candidates.sort((a, b) => -visitSort(a, b))[0] ?? null;
}

export function hasVisitNewerThan(visits, evidence) {
  const evidenceIndex = visits.findIndex((visit) =>
    String(visit.visitId) === String(evidence.visitId));
  return evidenceIndex > 0;
}
