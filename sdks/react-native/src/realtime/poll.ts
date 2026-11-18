import { RelayError } from '../errors';
import type { RelayHttp } from '../http';
import type { RealtimePoll } from '../types';
import {
  asEnvelope,
  classifyClose,
  type ConnectOptions,
  type RealtimeTransport,
  type TransportHandlers,
} from './transport';

// IN-23
/** The long-poll transport, the last fallback of the inbox stream. */
export class PollTransport implements RealtimeTransport {
  readonly name = 'poll' as const;
  private generation = 0;

  constructor(private readonly http: RelayHttp) {}

  connect(options: ConnectOptions, handlers: TransportHandlers): void {
    this.generation += 1;
    void this.loop(this.generation, options.cursor, handlers);
  }

  close(): void {
    this.generation += 1;
  }

  private async loop(
    generation: number,
    start: string | null,
    handlers: TransportHandlers,
  ): Promise<void> {
    let cursor = start;
    let opened = false;
    while (generation === this.generation) {
      let page: RealtimePoll;
      try {
        const { body } = await this.http.request<RealtimePoll>({
          method: 'GET',
          path: '/v1/realtime/poll',
          query: { cursor: cursor ?? undefined },
          retry: false,
        });
        page = body;
      } catch (error) {
        if (generation !== this.generation) return;
        const info =
          error instanceof RelayError
            ? classifyClose(error.status, error.code, error.retryAfterMs)
            : classifyClose(null, 'poll_failed');
        this.generation += 1;
        handlers.onClose(info);
        return;
      }
      if (generation !== this.generation) return;
      if (!opened) {
        opened = true;
        handlers.onOpen();
      }
      for (const raw of page.events) {
        const envelope = asEnvelope(raw);
        if (envelope && generation === this.generation) handlers.onEnvelope(envelope);
      }
      cursor = page.cursor;
    }
  }
}
