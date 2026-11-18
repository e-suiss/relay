import { RelayError, RelayRateLimitError } from './errors';
import type { RelayHttp } from './http';
import type { Clock, Logger, TimerHandle } from './ports';
import type { DeviceStatus, DeviceStatusList } from './types';

export const DEVICE_SIGNALS = ['worn', 'locked', 'headphones', 'focus', 'break'] as const;

export type DeviceSignalName = (typeof DEVICE_SIGNALS)[number];

export type DeviceSignals = Partial<Record<DeviceSignalName, boolean>>;

const MIN_TTL_S = 1;
const DEFAULT_TTL_S = 300;
const MAX_TTL_S = 900;
const MIN_INTERVAL_MS = 1_000;

/** Clamps a time to live in seconds to the dictionary bounds (PT1S to PT15M) and writes it as an ISO 8601 duration. */
export function statusTtl(seconds: number = DEFAULT_TTL_S): string {
  const whole = Math.round(Number.isFinite(seconds) ? seconds : DEFAULT_TTL_S);
  return `PT${String(Math.min(MAX_TTL_S, Math.max(MIN_TTL_S, whole)))}S`;
}

/** Keeps only dictionary v1 keys with boolean values. */
export function validSignals(signals: Readonly<Record<string, unknown>>): DeviceSignals {
  const valid: DeviceSignals = {};
  for (const name of DEVICE_SIGNALS) {
    const value = signals[name];
    if (typeof value === 'boolean') valid[name] = value;
  }
  return valid;
}

/** Writes the short-lived status signals of this device with `presence:write`. Values are never stored, queued or logged; a lost write only lowers freshness. */
export class DeviceStatusWriter {
  private pending: DeviceSignals = {};
  private pendingTtl = DEFAULT_TTL_S;
  private lastWriteAt = Number.NEGATIVE_INFINITY;
  private timer: TimerHandle | null = null;
  private inFlight: Promise<void> | null = null;

  constructor(
    private readonly http: RelayHttp,
    private readonly deviceId: () => Promise<string | null>,
    private readonly clock: Clock,
    private readonly logger: Logger,
  ) {}

  // IN-47
  // IN-48
  // IN-53
  /** Queues changed signals; at most one write per second, later changes in the same second are merged into the next write. */
  update(signals: Readonly<Record<string, unknown>>, ttlSeconds: number = DEFAULT_TTL_S): void {
    Object.assign(this.pending, validSignals(signals));
    this.pendingTtl = ttlSeconds;
    this.schedule();
  }

  /** The status of the subscriber's devices; signals that expired or cannot be read are `unknown`. */
  async read(): Promise<DeviceStatusList> {
    const { body } = await this.http.request<DeviceStatusList>({
      method: 'GET',
      path: '/v1/subscriber/devices/status',
    });
    return body;
  }

  stop(): void {
    if (this.timer !== null) this.clock.clearTimeout(this.timer);
    this.timer = null;
    this.pending = {};
  }

  private schedule(): void {
    if (this.timer !== null || this.inFlight !== null) return;
    if (Object.keys(this.pending).length === 0) return;
    const wait = Math.max(0, this.lastWriteAt + MIN_INTERVAL_MS - this.clock.now());
    this.timer = this.clock.setTimeout(() => {
      this.timer = null;
      this.inFlight = this.write().finally(() => {
        this.inFlight = null;
        this.schedule();
      });
    }, wait);
  }

  private async write(): Promise<void> {
    const signals = this.pending;
    const ttl = statusTtl(this.pendingTtl);
    this.pending = {};
    const id = await this.deviceId();
    if (id === null) return;
    this.lastWriteAt = this.clock.now();
    try {
      await this.http.request<DeviceStatus>({
        method: 'PATCH',
        path: '/v1/subscriber/devices/{device_id}/status',
        params: { device_id: id },
        body: { version: 'v1', signals, ttl },
        retry: false,
      });
      this.logger.debug('relay.presence.written');
    } catch (error) {
      if (error instanceof RelayRateLimitError) {
        this.pending = { ...signals, ...this.pending };
      }
      this.logger.debug('relay.presence.write_failed', {
        code: error instanceof RelayError ? error.code : null,
      });
    }
  }
}
