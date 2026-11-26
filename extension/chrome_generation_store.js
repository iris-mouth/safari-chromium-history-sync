const HEAD_KEY = "sync_state_head";
const PREFIX = "sync_state_generation_";

export function createChromeGenerationStore(storage) {
  if (!storage?.get || !storage?.set) throw new TypeError("storage.local is required");
  return {
    async load() {
      const head = (await storage.get(HEAD_KEY))[HEAD_KEY];
      if (!Number.isSafeInteger(head)) return null;
      const key = `${PREFIX}${head}`;
      return (await storage.get(key))[key] ?? null;
    },
    async replace(state) {
      const generation = state.generation;
      if (!Number.isSafeInteger(generation) || generation < 1) {
        throw new TypeError("state generation must be a positive integer");
      }
      await storage.set({ [`${PREFIX}${generation}`]: structuredClone(state) });
      await storage.set({ [HEAD_KEY]: generation });
      if (storage.remove && generation > 2) {
        await storage.remove(`${PREFIX}${generation - 2}`);
      }
    },
  };
}

export async function discardUnverifiableLegacyVisits(storage) {
  const keys = (await storage.getKeys()).filter(key => /^sync_state_generation_\d+$/.test(key));
  for (const key of keys) {
    const state = (await storage.get(key))[key];
    if (![1, 2].includes(state?.schemaVersion)) continue;
    const pending = state.browserToSafari;
    const held = state.heldBrowserVisits;
    const retained = Array.isArray(pending) ? pending.filter(event => event?.sourceKey) : pending;
    if (retained?.length === pending?.length && !held?.length) continue;
    const updated = { ...state, heldBrowserVisits: [] };
    if (Array.isArray(retained)) updated.browserToSafari = retained;
    await storage.set({ [key]: updated });
  }
}
