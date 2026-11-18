import type { KeyValueStore, SubscriberToken } from "@esuiss/relay-react-native";

const memory = new Map<string, string>();

export const storage: KeyValueStore = {
  getItem: async (key) => memory.get(key) ?? null,
  setItem: async (key, value) => {
    memory.set(key, value);
  },
  removeItem: async (key) => {
    memory.delete(key);
  },
};

export const myBackend = {
  async relaySubscriberToken(options: { forceRefresh: boolean }): Promise<SubscriberToken> {
    return { token: options.forceRefresh ? "fresh" : "cached", expiresAt: Date.now() + 900_000 };
  },
};

export function openInbox(): void {}
