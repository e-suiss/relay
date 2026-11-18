import type { RelayHttp } from './http';
import type { MyPreferencesPatch, SubscriberPreferences } from './types';

// X-31
// X-32
/** The subscriber's own preferences with the `preferences` scope. Consents and the subscriber profile are never written here. */
export class PreferencesClient {
  constructor(private readonly http: RelayHttp) {}

  async get(): Promise<SubscriberPreferences> {
    const { body } = await this.http.request<SubscriberPreferences>({
      method: 'GET',
      path: '/v1/subscriber/preferences',
    });
    return body;
  }

  /** Writes preference switches and the delivery profile together or not at all. */
  async update(patch: MyPreferencesPatch): Promise<SubscriberPreferences> {
    const { body } = await this.http.request<SubscriberPreferences>({
      method: 'PATCH',
      path: '/v1/subscriber/preferences',
      body: patch,
    });
    return body;
  }
}
