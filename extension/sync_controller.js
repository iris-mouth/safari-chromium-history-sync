import {
  MAX_PAGE_EVENTS,
  PROTOCOL_VERSION,
  isWebUrl,
  typedError,
  validateEnvelope,
} from "./protocol.js";

const DEFAULT_STATE = Object.freeze({
  schemaVersion: 2,
  generation: 0,
  nextBrowserToSafariSequence: 1,
  nextSafariToBrowserSequence: 1,
  browserToSafari: [],
  safariToBrowser: [],
  seenBrowserEventIds: [],
  seenBrowserSourceKeys: [],
  recoveryCount: 0,
  unrecoverableCount: 0,
});
const MAX_SEEN_SOURCE_EVENTS = 50_000;

function initialState(raw) {
  if (!raw || (raw.schemaVersion !== 1 && raw.schemaVersion !== 2)) {
    return structuredClone(DEFAULT_STATE);
  }
  const legacyProfileId = typeof raw.activeProfileId === "string"
    ? raw.activeProfileId
    : null;
  const scoped = (value) => legacyProfileId ? scopedKey(legacyProfileId, value) : value;
  return {
    ...structuredClone(DEFAULT_STATE),
    generation: Number.isSafeInteger(raw.generation) ? raw.generation : 0,
    nextBrowserToSafariSequence: Number.isSafeInteger(raw.nextBrowserToSafariSequence)
      ? raw.nextBrowserToSafariSequence
      : 1,
    nextSafariToBrowserSequence: Number.isSafeInteger(raw.nextSafariToBrowserSequence)
      ? raw.nextSafariToBrowserSequence
      : 1,
    browserToSafari: Array.isArray(raw.browserToSafari)
      ? raw.browserToSafari.map((event) => ({
        ...event,
        profileId: event.profileId ?? legacyProfileId,
      }))
      : [],
    safariToBrowser: Array.isArray(raw.safariToBrowser)
      ? raw.safariToBrowser.map((event) => ({
        ...event,
        profileId: event.profileId ?? legacyProfileId,
      }))
      : [],
    seenBrowserEventIds: Array.isArray(raw.seenBrowserEventIds)
      ? raw.seenBrowserEventIds.map(raw.schemaVersion === 1 ? scoped : String)
      : [],
    seenBrowserSourceKeys: Array.isArray(raw.seenBrowserSourceKeys)
      ? raw.seenBrowserSourceKeys.map(raw.schemaVersion === 1 ? scoped : String)
      : [],
    recoveryCount: Number.isSafeInteger(raw.recoveryCount) ? raw.recoveryCount : 0,
    unrecoverableCount: Number.isSafeInteger(raw.unrecoverableCount) ? raw.unrecoverableCount : 0,
  };
}

function scopedKey(profileId, value) {
  return `${profileId.length}:${profileId}${value}`;
}

function safeLimit(value) {
  if (!Number.isInteger(value) || value < 1) return MAX_PAGE_EVENTS;
  return Math.min(value, MAX_PAGE_EVENTS);
}

export function createSyncController({ store }) {
  if (!store?.load || !store?.replace) {
    throw new TypeError("store must implement load() and replace()");
  }

  let serial = Promise.resolve();
  const transact = (body) => {
    const next = serial.then(async () => {
      const current = initialState(await store.load());
      const draft = structuredClone(current);
      const result = await body(draft);
      draft.generation = current.generation + 1;
      await store.replace(draft);
      return result;
    });
    serial = next.catch(() => {});
    return next;
  };

  async function status() {
    await serial;
    const state = initialState(await store.load());
    return {
      protocolVersion: PROTOCOL_VERSION,
      pendingBrowserToSafari: state.browserToSafari.filter((event) => !event.acked).length,
      pendingSafariToBrowser: state.safariToBrowser.filter((event) => !event.acked).length,
      recoveryCount: state.recoveryCount,
      unrecoverableCount: state.unrecoverableCount,
    };
  }

  async function browserExchange(message) {
    const envelopeError = validateEnvelope(message);
    if (envelopeError) return envelopeError;

    return transact((state) => {
      if (message.operation === "publish") {
        if (!Array.isArray(message.events) || message.events.length > MAX_PAGE_EVENTS) {
          return typedError("INVALID_PAGE");
        }
        if (message.events.some((event) =>
          !event || typeof event.eventId !== "string" ||
          (event.sourceKey !== undefined && typeof event.sourceKey !== "string") ||
          !isWebUrl(event.url))) {
          return typedError("INVALID_EVENT");
        }
        const seen = new Set(state.seenBrowserEventIds);
        const seenSources = new Set(state.seenBrowserSourceKeys);
        const accepted = [];
        for (const event of message.events) {
          const eventKey = scopedKey(message.profileId, event.eventId);
          const sourceKey = event.sourceKey
            ? scopedKey(message.profileId, event.sourceKey)
            : null;
          if (seen.has(eventKey) || (sourceKey && seenSources.has(sourceKey))) continue;
          const queued = {
            sequence: state.nextBrowserToSafariSequence++,
            eventId: event.eventId,
            url: event.url,
            profileId: message.profileId,
            acked: false,
          };
          if (event.sourceKey) queued.sourceKey = event.sourceKey;
          state.browserToSafari.push(queued);
          state.seenBrowserEventIds.push(eventKey);
          if (sourceKey) {
            state.seenBrowserSourceKeys.push(sourceKey);
            seenSources.add(sourceKey);
          }
          seen.add(eventKey);
          accepted.push({ eventId: queued.eventId, sequence: queued.sequence });
        }
        if (state.seenBrowserEventIds.length > MAX_SEEN_SOURCE_EVENTS) {
          state.seenBrowserEventIds = state.seenBrowserEventIds.slice(-MAX_SEEN_SOURCE_EVENTS);
        }
        if (state.seenBrowserSourceKeys.length > MAX_SEEN_SOURCE_EVENTS) {
          state.seenBrowserSourceKeys = state.seenBrowserSourceKeys.slice(-MAX_SEEN_SOURCE_EVENTS);
        }
        return { type: "receipt", accepted };
      }

      if (message.operation === "pull") {
        const stream = message.stream === "browserToSafari"
          ? "browserToSafari"
          : "safariToBrowser";
        const source = stream === "browserToSafari"
          ? state.browserToSafari
          : state.safariToBrowser;
        const after = Number.isSafeInteger(message.afterSequence) ? message.afterSequence : 0;
        const events = source
          .filter((event) =>
            event.profileId === message.profileId && event.sequence > after && !event.acked)
          .slice(0, safeLimit(message.limit));
        return {
          type: "page",
          stream,
          events,
          hasMore: source.some(
            (event) => event.profileId === message.profileId &&
              event.sequence > (events.at(-1)?.sequence ?? after) && !event.acked,
          ),
        };
      }

      if (message.operation === "ack") {
        if (!Number.isSafeInteger(message.throughSequence) || message.throughSequence < 0) {
          return typedError("INVALID_RECEIPT");
        }
        const source = message.stream === "browserToSafari"
          ? state.browserToSafari
          : state.safariToBrowser;
        for (const event of source) {
          if (event.profileId === message.profileId &&
              event.sequence <= message.throughSequence) event.acked = true;
        }
        if (message.stream === "browserToSafari") {
          state.browserToSafari = state.browserToSafari.filter((event) => !event.acked);
        } else {
          state.safariToBrowser = state.safariToBrowser.filter((event) => !event.acked);
        }
        return { type: "receipt", throughSequence: message.throughSequence };
      }

      return typedError("OUTCOME_NOT_FOUND", true);
    });
  }

  return { browserExchange, status };
}
