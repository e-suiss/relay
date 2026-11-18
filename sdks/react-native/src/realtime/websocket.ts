import { REALTIME_WEBSOCKET_PATH } from '../boundary';
import type { Clock, TimerHandle } from '../ports';
import {
  asEnvelope,
  classifyClose,
  type ConnectOptions,
  type RealtimeTransport,
  type TransportHandlers,
} from './transport';

/** The subset of the WebSocket API the transport uses; React Native's global WebSocket fits. */
export interface WebSocketLike {
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: ((event: { code: number; reason: string }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

export type WebSocketFactory = (url: string, protocols: string[]) => WebSocketLike;

export const HEARTBEAT_MS = 15_000;

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Base64 without padding of an ASCII or UTF-8 text, as the Phoenix auth token subprotocol carries it. */
export function base64NoPadding(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i] ?? 0;
    const b = bytes[i + 1];
    const c = bytes[i + 2];
    const triple = (a << 16) | ((b ?? 0) << 8) | (c ?? 0);
    out += ALPHABET[(triple >> 18) & 63] ?? '';
    out += ALPHABET[(triple >> 12) & 63] ?? '';
    if (b !== undefined) out += ALPHABET[(triple >> 6) & 63] ?? '';
    if (c !== undefined) out += ALPHABET[triple & 63] ?? '';
  }
  return out;
}

/** The WebSocket URL of the inbox stream for a Relay base URL. */
export function websocketUrl(baseUrl: string, deviceId: string | null): string {
  const base = baseUrl.replace(/\/+$/, '').replace(/^http/, 'ws');
  const device = deviceId === null ? '' : `&device_id=${encodeURIComponent(deviceId)}`;
  return `${base}${REALTIME_WEBSOCKET_PATH}?vsn=2.0.0${device}`;
}

type PhoenixMessage = [string | null, string | null, string, string, unknown];

const JOIN_REF = '1';

// IN-23
// IN-31
// IN-32
// IN-58
/** The Phoenix Channels (protocol 2.0.0) WebSocket transport: joins the `inbox` topic, pushes nothing but `auth.refresh`, and heartbeats every 15 seconds. */
export class WebSocketTransport implements RealtimeTransport {
  readonly name = 'websocket' as const;
  private socket: WebSocketLike | null = null;
  private handlers: TransportHandlers | null = null;
  private ref = 1;
  private heartbeat: TimerHandle | null = null;
  private pendingHeartbeat: string | null = null;
  private joined = false;

  constructor(
    private readonly baseUrl: string,
    private readonly factory: WebSocketFactory,
    private readonly clock: Clock,
  ) {}

  connect(options: ConnectOptions, handlers: TransportHandlers): void {
    this.handlers = handlers;
    this.joined = false;
    const protocols = ['phoenix', `base64url.bearer.phx.${base64NoPadding(options.token)}`];
    const socket = this.factory(websocketUrl(this.baseUrl, options.deviceId), protocols);
    this.socket = socket;
    socket.onopen = () => {
      this.send([
        JOIN_REF,
        JOIN_REF,
        'inbox',
        'phx_join',
        options.cursor ? { cursor: options.cursor } : {},
      ]);
      this.scheduleHeartbeat();
    };
    socket.onmessage = (event) => {
      this.message(event.data);
    };
    socket.onclose = (event) => {
      this.finish(classifyClose(event.code, event.reason === '' ? null : event.reason));
    };
    socket.onerror = () => undefined;
  }

  refreshToken(token: string): void {
    if (this.joined) this.send([JOIN_REF, this.nextRef(), 'inbox', 'auth.refresh', { token }]);
  }

  close(): void {
    const socket = this.socket;
    this.teardown();
    socket?.close(1000, 'client');
  }

  private message(data: unknown): void {
    if (typeof data !== 'string') return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return;
    }
    if (!Array.isArray(parsed) || parsed.length !== 5) return;
    const [, ref, topic, event, payload] = parsed as PhoenixMessage;
    if (topic === 'phoenix' && event === 'phx_reply') {
      if (ref === this.pendingHeartbeat) this.pendingHeartbeat = null;
      return;
    }
    if (topic !== 'inbox') return;
    if (event === 'phx_reply' && ref === JOIN_REF) {
      const status = (payload as { status?: unknown } | null)?.status;
      if (status === 'ok') {
        this.joined = true;
        this.handlers?.onOpen();
      } else {
        const reason = (payload as { response?: { reason?: unknown } } | null)?.response?.reason;
        this.fail(classifyClose(null, typeof reason === 'string' ? reason : 'join_refused'));
      }
      return;
    }
    if (event === 'phx_error' || event === 'phx_close') {
      this.fail(classifyClose(null, event));
      return;
    }
    const envelope = asEnvelope(payload);
    if (envelope && envelope.t === event) this.handlers?.onEnvelope(envelope);
  }

  private scheduleHeartbeat(): void {
    this.heartbeat = this.clock.setTimeout(() => {
      if (this.pendingHeartbeat !== null) {
        this.fail(classifyClose(null, 'heartbeat_timeout'));
        return;
      }
      this.pendingHeartbeat = this.nextRef();
      this.send([null, this.pendingHeartbeat, 'phoenix', 'heartbeat', {}]);
      this.scheduleHeartbeat();
    }, HEARTBEAT_MS);
  }

  private fail(info: ReturnType<typeof classifyClose>): void {
    const socket = this.socket;
    this.finish(info);
    socket?.close(1000, 'client');
  }

  private finish(info: ReturnType<typeof classifyClose>): void {
    const handlers = this.handlers;
    this.teardown();
    handlers?.onClose(info);
  }

  private teardown(): void {
    if (this.heartbeat !== null) this.clock.clearTimeout(this.heartbeat);
    this.heartbeat = null;
    this.pendingHeartbeat = null;
    this.joined = false;
    this.handlers = null;
    if (this.socket) {
      this.socket.onopen = null;
      this.socket.onmessage = null;
      this.socket.onclose = null;
      this.socket.onerror = null;
    }
    this.socket = null;
  }

  private nextRef(): string {
    this.ref += 1;
    return String(this.ref);
  }

  private send(message: PhoenixMessage): void {
    this.socket?.send(JSON.stringify(message));
  }
}
