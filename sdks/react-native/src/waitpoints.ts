import type { RelayHttp } from './http';
import type { WaitpointResponseReceipt } from './types';

// AG-35
// AG-26
/** Sends the subscriber's response to a waitpoint it is asked by, with `inbox:write`. A response is never an approval: approval items are answered on the Access approval surface. */
export class WaitpointsClient {
  constructor(private readonly http: RelayHttp) {}

  /** Responds with one option value and the subject digest the item showed; sending the same response again is answered as the first was. */
  async respond(
    waitpointId: string,
    response: string,
    subjectDigest: string,
  ): Promise<WaitpointResponseReceipt> {
    const { body } = await this.http.request<WaitpointResponseReceipt>({
      method: 'POST',
      path: '/v1/subscriber/waitpoints/{waitpoint_id}/response',
      params: { waitpoint_id: waitpointId },
      body: { response, subject_digest: subjectDigest },
    });
    return body;
  }
}
