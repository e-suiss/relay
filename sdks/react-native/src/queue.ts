import type { KeyValueStore } from './ports';

/** A list persisted as JSON under one key; every change is written through before it resolves. */
export class DurableList<T> {
  private items: T[] | null = null;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly store: KeyValueStore,
    private readonly key: string,
  ) {}

  async all(): Promise<readonly T[]> {
    await this.chain;
    return [...(await this.load())];
  }

  update(change: (items: T[]) => T[]): Promise<readonly T[]> {
    const next = this.chain.then(async () => {
      const updated = change([...(await this.load())]);
      this.items = updated;
      if (updated.length === 0) await this.store.removeItem(this.key);
      else await this.store.setItem(this.key, JSON.stringify(updated));
      return [...updated];
    });
    this.chain = next.catch(() => undefined);
    return next;
  }

  private async load(): Promise<T[]> {
    if (this.items !== null) return this.items;
    const raw = await this.store.getItem(this.key);
    let parsed: unknown = [];
    if (raw !== null) {
      try {
        parsed = JSON.parse(raw);
      } catch {
        parsed = [];
      }
    }
    this.items = Array.isArray(parsed) ? (parsed as T[]) : [];
    return this.items;
  }
}
