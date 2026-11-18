import type { RelayHttp } from './http';
import type { Consent, ConsentList } from './types';

const MAX_PAGES = 10;

export interface ConsentPageQuery {
  readonly limit?: number;
  readonly startingAfter?: string;
}

// X-44
// X-31
/** A read-only copy of the subscriber's commercial consents with the `preferences` scope. Consents are changed in Access; this client never writes them. */
export class ConsentsClient {
  constructor(private readonly http: RelayHttp) {}

  /** One page of consents, newest first. */
  async list(query: ConsentPageQuery = {}): Promise<ConsentList> {
    const { body } = await this.http.request<ConsentList>({
      method: 'GET',
      path: '/v1/subscriber/consents',
      query: { limit: query.limit, starting_after: query.startingAfter },
    });
    return body;
  }

  /** Every consent, following the cursor for at most ten pages. */
  async all(): Promise<Consent[]> {
    const consents: Consent[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const list = await this.list({
        limit: 100,
        ...(cursor === undefined ? {} : { startingAfter: cursor }),
      });
      const data = list.data as Consent[] | null | undefined;
      consents.push(...(Array.isArray(data) ? data : []));
      if (!list.has_more || !list.next_cursor) break;
      cursor = list.next_cursor;
    }
    return consents;
  }
}
