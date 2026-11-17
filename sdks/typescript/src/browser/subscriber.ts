import { AuthenticationError } from "../core/errors.js";
import {
  invoke,
  paginate,
  type CallArgs,
  type CallArgsTuple,
  type ItemOf,
  type LooseArgs,
  type ResponseOf,
} from "../core/operations.js";
import type { Paginator } from "../core/pagination.js";
import { newIdempotencyKey, Transport, type RelayResponse, type TransportOptions } from "../core/transport.js";
import { subscriberOperations } from "../generated/operations.js";
import type { operations } from "../generated/subscriber.js";
import { SubscriberTokenSource, type SubscriberTokenProvider } from "./token.js";

/** Operation identifiers of the subscriber API. */
export type SubscriberOperationId = keyof typeof subscriberOperations & keyof operations;

/** Subscriber API operations that return a cursor list. */
export type SubscriberListOperationId = {
  [K in SubscriberOperationId]: (typeof subscriberOperations)[K]["paginated"] extends true ? K : never;
}[SubscriberOperationId];

/** The argument of a subscriber API call. */
export type SubscriberCallArgs<K extends SubscriberOperationId> = CallArgs<operations[K]>;

/** The success body of a subscriber API call. */
export type SubscriberResult<K extends SubscriberOperationId> = ResponseOf<operations[K]>;

/** The item of a subscriber API list. */
export type SubscriberListItem<K extends SubscriberListOperationId> = ItemOf<operations[K]>;

/** Options of the subscriber client. */
export interface RelaySubscriberClientOptions extends Omit<TransportOptions, "authenticate"> {
  /** The subscriber token: a provider or a shared token source. */
  readonly token: SubscriberTokenProvider | SubscriberTokenSource;
}

/**
 * The subscriber API client used by browsers and UI components (X-32). It holds only the narrow subscriber token, sent as a Bearer token; it never takes a secret credential. A request refused with `auth_expired_token` is sent once more with a renewed token.
 */
export class RelaySubscriberClient {
  readonly transport: Transport;
  readonly tokens: SubscriberTokenSource;

  constructor(options: RelaySubscriberClientOptions) {
    this.tokens =
      options.token instanceof SubscriberTokenSource ? options.token : new SubscriberTokenSource(options.token);
    const tokens = this.tokens;
    this.transport = new Transport({
      ...options,
      authenticate: async () => ({ authorization: `Bearer ${await tokens.get()}` }),
    });
  }

  /** Calls an operation and returns its body. */
  async call<K extends SubscriberOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Promise<SubscriberResult<K>> {
    const response = await this.callRaw(operation, ...args);
    return response.data;
  }

  /** Calls an operation and returns the body with status, headers, request id and replay flag. */
  async callRaw<K extends SubscriberOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Promise<RelayResponse<SubscriberResult<K>>> {
    const spec = subscriberOperations[operation];
    const given = (args[0] ?? {}) as unknown as LooseArgs;
    const loose: LooseArgs =
      spec.idempotency === "required" && given.idempotencyKey === undefined
        ? { ...given, idempotencyKey: newIdempotencyKey() }
        : given;
    try {
      return await invoke<SubscriberResult<K>>(this.transport, spec, loose);
    } catch (error) {
      if (!(error instanceof AuthenticationError) || error.code !== "auth_expired_token") throw error;
      this.tokens.invalidate();
      return invoke<SubscriberResult<K>>(this.transport, spec, loose);
    }
  }

  /** Iterates lazily over every item of a list operation. */
  paginate<K extends SubscriberListOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Paginator<SubscriberListItem<K>> {
    const given = (args[0] ?? {}) as unknown as LooseArgs;
    return paginate<SubscriberListItem<K>>(this.transport, subscriberOperations[operation], given);
  }
}
