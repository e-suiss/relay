import { API_VERSION } from '../ports';
import {
  asEnvelope,
  classifyClose,
  type ConnectOptions,
  type RealtimeTransport,
  type TransportHandlers,
} from './transport';

export interface SseEvent {
  readonly id: string | null;
  readonly event: string;
  readonly data: string;
}

/** Incremental `text/event-stream` parser. */
export class SseParser {
  private buffer = '';
  private data: string[] = [];
  private event = '';
  private id: string | null = null;

  push(chunk: string): SseEvent[] {
    this.buffer += chunk;
    const events: SseEvent[] = [];
    let newline = this.nextLineEnd();
    while (newline !== null) {
      const line = this.buffer.slice(0, newline.index);
      this.buffer = this.buffer.slice(newline.index + newline.length);
      const event = this.line(line);
      if (event) events.push(event);
      newline = this.nextLineEnd();
    }
    return events;
  }

  private nextLineEnd(): { index: number; length: number } | null {
    const match = /\r\n|\r|\n/.exec(this.buffer);
    if (!match) return null;
    if (match[0] === '\r' && match.index === this.buffer.length - 1) return null;
    return { index: match.index, length: match[0].length };
  }

  private line(line: string): SseEvent | null {
    if (line === '') {
      if (this.data.length === 0) {
        this.event = '';
        return null;
      }
      const event = { id: this.id, event: this.event || 'message', data: this.data.join('\n') };
      this.data = [];
      this.event = '';
      return event;
    }
    if (line.startsWith(':')) return null;
    const colon = line.indexOf(':');
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? '' : line.slice(colon + 1);
    if (value.startsWith(' ')) value = value.slice(1);
    if (field === 'data') this.data.push(value);
    else if (field === 'event') this.event = value;
    else if (field === 'id' && !value.includes('\0')) this.id = value;
    return null;
  }
}

/** A streaming HTTP GET; React Native's XMLHttpRequest with progress events fits. */
export interface StreamingRequest {
  abort(): void;
}

export interface StreamingHandlers {
  onResponse(status: number, headers: (name: string) => string | null): void;
  onChunk(text: string): void;
  onEnd(error: boolean): void;
}

export type StreamingConnector = (
  url: string,
  headers: Readonly<Record<string, string>>,
  handlers: StreamingHandlers,
) => StreamingRequest;

interface XhrLike {
  readyState: number;
  status: number;
  responseText: string;
  onreadystatechange: (() => void) | null;
  onprogress: (() => void) | null;
  onerror: (() => void) | null;
  onload: (() => void) | null;
  open(method: string, url: string): void;
  setRequestHeader(name: string, value: string): void;
  getResponseHeader(name: string): string | null;
  send(): void;
  abort(): void;
}

/** A streaming connector over the global XMLHttpRequest. */
export function xhrConnector(): StreamingConnector {
  return (url, headers, handlers) => {
    const Xhr = (globalThis as { XMLHttpRequest?: new () => XhrLike }).XMLHttpRequest;
    if (!Xhr) throw new Error('XMLHttpRequest is not available');
    const xhr = new Xhr();
    let seen = 0;
    let responded = false;
    const drain = () => {
      const text = xhr.responseText;
      if (text.length > seen) {
        handlers.onChunk(text.slice(seen));
        seen = text.length;
      }
    };
    xhr.open('GET', url);
    for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, value);
    xhr.onreadystatechange = () => {
      if (xhr.readyState >= 2 && !responded) {
        responded = true;
        handlers.onResponse(xhr.status, (name) => xhr.getResponseHeader(name));
      }
    };
    xhr.onprogress = drain;
    xhr.onload = () => {
      drain();
      handlers.onEnd(false);
    };
    xhr.onerror = () => {
      handlers.onEnd(true);
    };
    xhr.send();
    return { abort: () => xhr.abort() };
  };
}

// IN-23
// IN-58
/** The SSE transport of the inbox stream with `Last-Event-ID` resumption. */
export class SseTransport implements RealtimeTransport {
  readonly name = 'sse' as const;
  private request: StreamingRequest | null = null;
  private handlers: TransportHandlers | null = null;

  constructor(
    private readonly url: (deviceId: string | null) => string,
    private readonly connector: StreamingConnector,
  ) {}

  connect(options: ConnectOptions, handlers: TransportHandlers): void {
    this.handlers = handlers;
    const parser = new SseParser();
    const headers: Record<string, string> = {
      Accept: 'text/event-stream',
      Authorization: `Bearer ${options.token}`,
      'Relay-Version': API_VERSION,
    };
    if (options.cursor) headers['Last-Event-ID'] = options.cursor;
    let failed = false;
    this.request = this.connector(this.url(options.deviceId), headers, {
      onResponse: (status, header) => {
        if (status === 200) {
          this.handlers?.onOpen();
          return;
        }
        failed = true;
        const retryAfter = header('Retry-After');
        const seconds = retryAfter !== null && /^\d+$/.test(retryAfter) ? Number(retryAfter) : null;
        this.finish(classifyClose(status, null, seconds === null ? null : seconds * 1000));
      },
      onChunk: (text) => {
        if (failed) return;
        for (const event of parser.push(text)) {
          let parsed: unknown;
          try {
            parsed = JSON.parse(event.data);
          } catch {
            continue;
          }
          const envelope = asEnvelope(parsed);
          if (envelope) {
            this.handlers?.onEnvelope(event.id ? { ...envelope, id: envelope.id ?? event.id } : envelope);
          }
        }
      },
      onEnd: () => {
        if (!failed) this.finish(classifyClose(null, 'stream_ended'));
      },
    });
  }

  close(): void {
    const request = this.request;
    this.handlers = null;
    this.request = null;
    request?.abort();
  }

  private finish(info: ReturnType<typeof classifyClose>): void {
    const handlers = this.handlers;
    const request = this.request;
    this.handlers = null;
    this.request = null;
    request?.abort();
    handlers?.onClose(info);
  }
}
