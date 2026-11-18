import { fullJitter } from '../backoff';
import type { TokenManager } from '../http';
import type { Clock, Logger, Random, TimerHandle } from '../ports';
import type { RealtimeEnvelope } from '../types';
import type { CloseInfo, RealtimeTransport, TransportName } from './transport';

export type ConnectionState = 'idle' | 'connecting' | 'open' | 'waiting' | 'stopped';

export interface ConnectionEvents {
  onOpen(transport: TransportName): void;
  onEnvelope(envelope: RealtimeEnvelope): void;
  onStateChange?(state: ConnectionState): void;
  onFatal?(detail: string | null): void;
}

export interface ConnectionOptions {
  readonly transports: readonly RealtimeTransport[];
  readonly tokens: TokenManager;
  readonly clock: Clock;
  readonly random: Random;
  readonly logger: Logger;
  readonly cursor: () => string | null;
  readonly deviceId: () => Promise<string | null>;
  readonly failuresBeforeFallback?: number;
  readonly upgradeAfterMs?: number;
}

const REFRESH_BEFORE_MS = 60_000;
const REFRESH_UNKNOWN_MS = 600_000;

// IN-23
// IN-34
// IN-52
/** Keeps one realtime connection: WebSocket first, then SSE, then long-poll after repeated failures; full-jitter reconnects; token refresh on the open WebSocket. */
export class RealtimeConnection {
  private index = 0;
  private attempt = 0;
  private failures = 0;
  private authRetried = false;
  private timer: TimerHandle | null = null;
  private refreshTimer: TimerHandle | null = null;
  private upgradeTimer: TimerHandle | null = null;
  private active: RealtimeTransport | null = null;
  private state: ConnectionState = 'idle';
  private generation = 0;

  constructor(
    private readonly options: ConnectionOptions,
    private readonly events: ConnectionEvents,
  ) {}

  get current(): ConnectionState {
    return this.state;
  }

  get transport(): TransportName | null {
    return this.active?.name ?? null;
  }

  /** Opens the stream, starting again from the first transport. */
  start(): void {
    this.stopTimers();
    this.closeActive();
    this.index = 0;
    this.attempt = 0;
    this.failures = 0;
    this.authRetried = false;
    this.generation += 1;
    void this.open(this.generation, false);
  }

  /** Closes the stream; nothing reconnects until `start`. */
  stop(): void {
    this.generation += 1;
    this.stopTimers();
    this.closeActive();
    this.setState('stopped');
  }

  private async open(generation: number, forceToken: boolean): Promise<void> {
    if (generation !== this.generation) return;
    const transport = this.options.transports[this.index];
    if (!transport) return;
    this.setState('connecting');
    let token: string;
    let deviceId: string | null;
    try {
      token = (await this.options.tokens.get(forceToken)).token;
      deviceId = await this.options.deviceId();
    } catch {
      if (generation === this.generation) this.retry(generation, null);
      return;
    }
    if (generation !== this.generation) return;
    this.active = transport;
    transport.connect(
      { token, cursor: this.options.cursor(), deviceId },
      {
        onOpen: () => {
          if (generation !== this.generation) return;
          this.attempt = 0;
          this.failures = 0;
          this.authRetried = false;
          this.setState('open');
          this.scheduleRefresh(generation);
          this.scheduleUpgrade(generation);
          this.events.onOpen(transport.name);
        },
        onEnvelope: (envelope) => {
          if (generation === this.generation) this.events.onEnvelope(envelope);
        },
        onClose: (info) => {
          if (generation === this.generation) this.closed(generation, info);
        },
      },
    );
  }

  private closed(generation: number, info: CloseInfo): void {
    this.active = null;
    this.stopTimers();
    this.options.logger.debug('relay.realtime.closed', {
      reason: info.reason,
      detail: info.detail,
    });
    switch (info.reason) {
      case 'closed':
        return;
      case 'fatal':
        this.generation += 1;
        this.setState('stopped');
        this.events.onFatal?.(info.detail);
        return;
      case 'auth_expired':
        if (!this.authRetried) {
          this.authRetried = true;
          void this.open(generation, true);
          return;
        }
        this.retry(generation, null);
        return;
      case 'overloaded':
        this.retry(generation, info.retryAfterMs);
        return;
      case 'error': {
        this.failures += 1;
        const threshold = this.options.failuresBeforeFallback ?? 2;
        if (this.failures >= threshold && this.index < this.options.transports.length - 1) {
          this.index += 1;
          this.failures = 0;
        }
        this.retry(generation, null);
        return;
      }
    }
  }

  private retry(generation: number, atLeastMs: number | null): void {
    const delay = Math.max(atLeastMs ?? 0, fullJitter(this.attempt, this.options.random));
    this.attempt += 1;
    this.setState('waiting');
    this.timer = this.options.clock.setTimeout(() => {
      this.timer = null;
      void this.open(generation, false);
    }, delay);
  }

  private scheduleRefresh(generation: number): void {
    const transport = this.active;
    if (!transport?.refreshToken) return;
    const pending = this.options.tokens.get(false).then((current) => {
      if (generation !== this.generation) return;
      const wait =
        current.expiresAt === undefined
          ? REFRESH_UNKNOWN_MS
          : Math.max(1_000, current.expiresAt - REFRESH_BEFORE_MS - this.options.clock.now());
      this.refreshTimer = this.options.clock.setTimeout(() => {
        void this.options.tokens
          .get(true)
          .then((fresh) => {
            if (generation !== this.generation || this.active !== transport) return;
            transport.refreshToken?.(fresh.token);
            this.scheduleRefresh(generation);
          })
          .catch(() => undefined);
      }, wait);
    });
    pending.catch(() => undefined);
  }

  private scheduleUpgrade(generation: number): void {
    if (this.index === 0) return;
    this.upgradeTimer = this.options.clock.setTimeout(() => {
      if (generation !== this.generation) return;
      this.start();
    }, this.options.upgradeAfterMs ?? 600_000);
  }

  private closeActive(): void {
    const transport = this.active;
    this.active = null;
    transport?.close();
  }

  private stopTimers(): void {
    for (const handle of [this.timer, this.refreshTimer, this.upgradeTimer]) {
      if (handle !== null) this.options.clock.clearTimeout(handle);
    }
    this.timer = null;
    this.refreshTimer = null;
    this.upgradeTimer = null;
  }

  private setState(state: ConnectionState): void {
    if (this.state === state) return;
    this.state = state;
    this.events.onStateChange?.(state);
  }
}
