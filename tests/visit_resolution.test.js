import assert from "node:assert/strict";
import test from "node:test";

import {
  hasPendingImport,
  hasVisitNewerThan,
  importedVisitEvidence,
  orderedRecentVisits,
  unseenVisitsAfterMarker,
} from "../extension/visit_resolution.js";

test("a Safari-imported browser visit is not echoed back to Safari", () => {
  const pending = {
    url: "https://example.com/imported",
    requestedAt: 10_000,
    preVisitIds: ["40"],
  };
  const visits = orderedRecentVisits([
    { visitId: "40", visitTime: 9_000 },
    { visitId: "41", visitTime: 10_050 },
  ]);
  const evidence = importedVisitEvidence(visits, pending);

  assert.equal(hasPendingImport({ event: pending }, pending.url), true);
  assert.equal(evidence.visitId, "41");
  assert.equal(hasVisitNewerThan(visits, evidence), false);
  assert.deepEqual(unseenVisitsAfterMarker(visits, evidence.visitId), []);
});

test("a real browser visit after an import remains outbound", () => {
  const pending = {
    url: "https://example.com/imported",
    requestedAt: 10_000,
    preVisitIds: ["40"],
  };
  const visits = orderedRecentVisits([
    { visitId: "40", visitTime: 9_000 },
    { visitId: "41", visitTime: 10_050 },
    { visitId: "42", visitTime: 11_000 },
  ]);
  const evidence = importedVisitEvidence(visits, pending);

  assert.equal(evidence.visitId, "41");
  assert.equal(hasVisitNewerThan(visits, evidence), true);
  assert.deepEqual(
    unseenVisitsAfterMarker(visits, evidence.visitId).map((visit) => visit.visitId),
    ["42"],
  );
});
