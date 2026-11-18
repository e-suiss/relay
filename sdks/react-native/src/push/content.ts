import type { RelayHttp } from '../http';
import type { PushContentResponse } from '../types';
import type { PushContent, PushContentSource } from './adapter';

const text = (value: unknown): string | null =>
  typeof value === 'string' && value !== '' ? value : null;

/** The content fields of a `PushContent` answer, or `null` when it carries neither a title nor a body. */
export function pushContentOf(response: PushContentResponse): PushContent | null {
  const content = (response.content ?? {}) as Readonly<Record<string, unknown>>;
  const title = text(content.title);
  const body = text(content.body);
  if (title === null && body === null) return null;
  return {
    title,
    body,
    url: text(content.url),
    notificationId: text(response.notification_id),
  };
}

// CH-33
/** Fetches the content of a content-free push from Relay by its delivery id (`relay_id`) with the subscriber's own token and `inbox:read`. Any failure gives `null`, and the device shows its neutral text. */
export class RelayPushContentSource implements PushContentSource {
  constructor(private readonly http: RelayHttp) {}

  async fetch(deliveryId: string): Promise<PushContent | null> {
    try {
      const { body } = await this.http.request<PushContentResponse>({
        method: 'GET',
        path: '/v1/subscriber/push_content/{delivery_id}',
        params: { delivery_id: deliveryId },
        retry: false,
      });
      return pushContentOf(body);
    } catch {
      return null;
    }
  }
}
