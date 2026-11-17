import { describe, expect, it } from 'vitest';
import { TokenManager } from '../src/http';
import { RealtimeConnection } from '../src/realtime/connection';
import { SseParser, SseTransport, type StreamingHandlers } from '../src/realtime/sse';
import {
  classifyClose,
  type ConnectOptions,
  type RealtimeTransport,
  type TransportHandlers,
  type TransportName,
} from '../src/realtime/transport';
import {
  base64NoPadding,
  HEARTBEAT_MS,
  WebSocketTransport,
  websocketUrl,
  type WebSocketLike,
} from '../src/realtime/websocket';
import { fakeClock, fakeRandom, flushPromises, recordingLogger } from './helpers';

const ENVELOPE = {
  t: 'inbox.counters_changed',
  v: 1,
  ts: '2026-11-18T09:00:00Z',
  id: 'c5',
  d: { unseen: 1, unread: 1, total: 1, version: 5 },
  counters: { unseen: 1, unread: 1, total: 1, version: 5 },
};

class FakeSocket implements WebSocketLike {
  onopen: ((event: unknown) => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: ((event: { code: number; reason: string }) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;
  sent: unknown[] = [];
  closed = false;

  constructor(
    readonly url: string,
    readonly protocols: string[],
  ) {}

  send(data: string) {
    this.sent.push(JSON.parse(data));
  }

  close() {
    this.closed = true;
  }

  receive(message: unknown) {
    this.onmessage?.({ data: JSON.stringify(message) });
  }
}

function recorder() {
  const events: string[] = [];
  const envelopes: unknown[] = [];
  const closes: unknown[] = [];
  const handlers: TransportHandlers = {
    onOpen: () => events.push('open'),
    onEnvelope: (envelope) => envelopes.push(envelope),
    onClose: (info) => closes.push(info),
  };
  return { events, envelopes, closes, handlers };
}

function socketHarness() {
  const sockets: FakeSocket[] = [];
  const clock = fakeClock();
  const transport = new WebSocketTransport(
    'https://relay.example.com/',
    (url, protocols) => {
      const socket = new FakeSocket(url, protocols);
      sockets.push(socket);
      return socket;
    },
    clock,
  );
  return { sockets, clock, transport };
}

const options: ConnectOptions = { token: 'tok.en-1', cursor: 'c4', deviceId: 'dev_01j9zq3k4m5n6p7q8r9s0t1v2w' };

describe('IN-23 IN-58 WebSocket transport', () => {
  it('IN-23 connects with the token in the Phoenix subprotocol and joins inbox with the cursor', () => {
    const { sockets, transport } = socketHarness();
    const { handlers, events } = recorder();
    transport.connect(options, handlers);
    const socket = sockets[0];
    expect(socket?.url).toBe(
      'wss://relay.example.com/v1/realtime/websocket?vsn=2.0.0&device_id=dev_01j9zq3k4m5n6p7q8r9s0t1v2w',
    );
    expect(socket?.protocols).toEqual(['phoenix', `base64url.bearer.phx.${base64NoPadding('tok.en-1')}`]);
    socket?.onopen?.({});
    expect(socket?.sent[0]).toEqual(['1', '1', 'inbox', 'phx_join', { cursor: 'c4' }]);
    socket?.receive(['1', '1', 'inbox', 'phx_reply', { status: 'ok', response: {} }]);
    expect(events).toEqual(['open']);
  });

  it('IN-26 delivers envelopes pushed under their type', () => {
    const { sockets, transport } = socketHarness();
    const { handlers, envelopes } = recorder();
    transport.connect(options, handlers);
    sockets[0]?.onopen?.({});
    sockets[0]?.receive(['1', null, 'inbox', 'inbox.counters_changed', ENVELOPE]);
    sockets[0]?.receive(['1', null, 'inbox', 'inbox.item_created', ENVELOPE]);
    expect(envelopes).toEqual([ENVELOPE]);
  });

  it('IN-31 sends nothing but the join, heartbeats and auth.refresh', async () => {
    const { sockets, transport, clock } = socketHarness();
    const { handlers } = recorder();
    transport.connect(options, handlers);
    const socket = sockets[0];
    socket?.onopen?.({});
    socket?.receive(['1', '1', 'inbox', 'phx_reply', { status: 'ok', response: {} }]);
    transport.refreshToken('fresh');
    await clock.advance(HEARTBEAT_MS);
    const events = (socket?.sent ?? []).map((message) => (message as unknown[])[3]);
    expect(events).toEqual(['phx_join', 'auth.refresh', 'heartbeat']);
    expect((socket?.sent[1] as unknown[])[4]).toEqual({ token: 'fresh' });
  });

  it('IN-58 an unanswered heartbeat closes the connection as an error', async () => {
    const { sockets, transport, clock } = socketHarness();
    const { handlers, closes } = recorder();
    transport.connect(options, handlers);
    sockets[0]?.onopen?.({});
    await clock.advance(HEARTBEAT_MS * 2);
    expect(closes).toEqual([{ reason: 'error', detail: 'heartbeat_timeout', retryAfterMs: null }]);
    expect(sockets[0]?.closed).toBe(true);
  });

  it('IN-33 IN-52 maps the server close codes', () => {
    expect(classifyClose(1008, 'auth_expired_token').reason).toBe('auth_expired');
    expect(classifyClose(1008, 'auth_subscriber_suspended').reason).toBe('fatal');
    expect(classifyClose(1008, 'connection_limit').reason).toBe('fatal');
    expect(classifyClose(1013, 'retry-after=4')).toEqual({ reason: 'overloaded', detail: 'retry-after=4', retryAfterMs: 4000 });
    expect(classifyClose(503, null, 2000)).toEqual({ reason: 'overloaded', detail: null, retryAfterMs: 2000 });
    expect(classifyClose(1006, null).reason).toBe('error');
  });

  it('IN-23 builds ws URLs from http base addresses', () => {
    expect(websocketUrl('http://localhost:4000', null)).toBe('ws://localhost:4000/v1/realtime/websocket?vsn=2.0.0');
  });
});

describe('IN-23 SSE transport', () => {
  it('IN-23 parses events split across chunks', () => {
    const parser = new SseParser();
    expect(parser.push(': keep-alive\n\nid: c1\nevent: inbox.counters')).toEqual([]);
    expect(parser.push('_changed\ndata: {"a":\ndata: 1}\n\n')).toEqual([
      { id: 'c1', event: 'inbox.counters_changed', data: '{"a":\n1}' },
    ]);
  });

  it('IN-23 resumes with Last-Event-ID and hands envelopes over', () => {
    let captured: { url: string; headers: Readonly<Record<string, string>>; handlers: StreamingHandlers } | undefined;
    const transport = new SseTransport(
      (deviceId) => `https://relay.example.com/v1/realtime/events?device_id=${deviceId ?? ''}`,
      (url, headers, handlers) => {
        captured = { url, headers, handlers };
        return { abort: () => undefined };
      },
    );
    const { handlers, events, envelopes } = recorder();
    transport.connect(options, handlers);
    expect(captured?.headers['Last-Event-ID']).toBe('c4');
    expect(captured?.headers.Authorization).toBe('Bearer tok.en-1');
    captured?.handlers.onResponse(200, () => null);
    captured?.handlers.onChunk(`id: c5\nevent: inbox.counters_changed\ndata: ${JSON.stringify(ENVELOPE)}\n\n`);
    expect(events).toEqual(['open']);
    expect(envelopes).toEqual([ENVELOPE]);
  });

  it('IN-52 an overloaded node answers 503 with Retry-After', () => {
    let handlersOf: StreamingHandlers | undefined;
    const transport = new SseTransport(
      () => 'https://relay.example.com/v1/realtime/events',
      (_url, _headers, handlers) => {
        handlersOf = handlers;
        return { abort: () => undefined };
      },
    );
    const { handlers, closes } = recorder();
    transport.connect(options, handlers);
    handlersOf?.onResponse(503, (name) => (name === 'Retry-After' ? '3' : null));
    expect(closes).toEqual([{ reason: 'overloaded', detail: null, retryAfterMs: 3000 }]);
  });
});

class ScriptedTransport implements RealtimeTransport {
  connects = 0;
  closes = 0;
  tokens: string[] = [];
  handlers: TransportHandlers | null = null;

  constructor(
    readonly name: TransportName,
    private readonly script: (attempt: number, handlers: TransportHandlers) => void,
  ) {}

  connect(connectOptions: ConnectOptions, handlers: TransportHandlers) {
    this.connects += 1;
    this.tokens.push(connectOptions.token);
    this.handlers = handlers;
    this.script(this.connects, handlers);
  }

  close() {
    this.closes += 1;
  }
}

function connectionHarness(transports: RealtimeTransport[]) {
  const clock = fakeClock();
  let issued = 0;
  const forced: boolean[] = [];
  const tokens = new TokenManager(({ forceRefresh }) => {
    forced.push(forceRefresh);
    issued += 1;
    return Promise.resolve({ token: `t${String(issued)}` });
  }, clock);
  const opened: string[] = [];
  const fatal: (string | null)[] = [];
  const connection = new RealtimeConnection(
    {
      transports,
      tokens,
      clock,
      random: fakeRandom(1),
      logger: recordingLogger(),
      cursor: () => null,
      deviceId: () => Promise.resolve(null),
    },
    {
      onOpen: (name) => opened.push(name),
      onEnvelope: () => undefined,
      onFatal: (detail) => fatal.push(detail),
    },
  );
  return { clock, connection, opened, fatal, forced };
}

const fail = (_attempt: number, handlers: TransportHandlers) => {
  handlers.onClose({ reason: 'error', detail: null, retryAfterMs: null });
};
const succeed = (_attempt: number, handlers: TransportHandlers) => {
  handlers.onOpen();
};

describe('IN-23 IN-34 connection fallback and reconnect', () => {
  it('IN-23 falls back from WebSocket to SSE to long-poll after two failures each', async () => {
    const ws = new ScriptedTransport('websocket', fail);
    const sse = new ScriptedTransport('sse', fail);
    const poll = new ScriptedTransport('poll', succeed);
    const { clock, connection, opened } = connectionHarness([ws, sse, poll]);
    connection.start();
    await clock.advance(10 * 60_000 - 1);
    expect([ws.connects, sse.connects, poll.connects]).toEqual([2, 2, 1]);
    expect(opened).toEqual(['poll']);
  });

  it('IN-34 IN-52 reconnects with full-jitter backoff from 1 s capped at 60 s', async () => {
    const ws = new ScriptedTransport('websocket', fail);
    const { clock, connection } = connectionHarness([ws]);
    connection.start();
    await clock.advance(400_000);
    expect(clock.delays.slice(0, 8)).toEqual([1000, 2000, 4000, 8000, 16_000, 32_000, 60_000, 60_000]);
  });

  it('IN-33 a fatal close stops reconnecting', async () => {
    const ws = new ScriptedTransport('websocket', (_attempt, handlers) => {
      handlers.onClose({ reason: 'fatal', detail: 'auth_subscriber_suspended', retryAfterMs: null });
    });
    const { clock, connection, fatal } = connectionHarness([ws]);
    connection.start();
    await clock.advance(120_000);
    expect(ws.connects).toBe(1);
    expect(fatal).toEqual(['auth_subscriber_suspended']);
    expect(connection.current).toBe('stopped');
  });

  it('IN-33 an expired token is renewed once before reconnecting', async () => {
    const ws = new ScriptedTransport('websocket', (attempt, handlers) => {
      if (attempt === 1) handlers.onClose({ reason: 'auth_expired', detail: 'auth_expired_token', retryAfterMs: null });
      else handlers.onOpen();
    });
    const { clock, connection, forced, opened } = connectionHarness([ws]);
    connection.start();
    await flushPromises();
    await clock.advance(0);
    expect(forced).toEqual([false, true]);
    expect(ws.tokens).toEqual(['t1', 't2']);
    expect(opened).toEqual(['websocket']);
  });

  it('IN-52 waits at least the Retry-After of an overloaded node', async () => {
    const ws = new ScriptedTransport('websocket', (attempt, handlers) => {
      if (attempt === 1) handlers.onClose({ reason: 'overloaded', detail: 'retry-after=5', retryAfterMs: 5000 });
      else handlers.onOpen();
    });
    const { clock, connection } = connectionHarness([ws]);
    connection.start();
    await flushPromises();
    expect(clock.delays[0]).toBe(5000);
    await clock.advance(5000);
    expect(ws.connects).toBe(2);
  });

  it('IN-35 stop closes the transport and nothing reconnects', async () => {
    const ws = new ScriptedTransport('websocket', succeed);
    const { clock, connection } = connectionHarness([ws]);
    connection.start();
    await flushPromises();
    connection.stop();
    await clock.advance(600_000);
    expect(ws.closes).toBe(1);
    expect(ws.connects).toBe(1);
  });
});
