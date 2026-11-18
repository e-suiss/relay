import {
  invoke,
  paginate,
  type CallArgs,
  type CallArgsTuple,
  type ItemOf,
  type LooseArgs,
  type ResponseOf,
} from "./core/operations.js";
import type { Paginator } from "./core/pagination.js";
import { Transport, type RelayResponse, type TransportOptions } from "./core/transport.js";
import { serverOperations } from "./generated/operations.js";
import type { operations } from "./generated/server.js";

/** Operation identifiers of the server API. */
export type ServerOperationId = keyof typeof serverOperations & keyof operations;

/** Server API operations that return a cursor list. */
export type ServerListOperationId = {
  [K in ServerOperationId]: (typeof serverOperations)[K]["paginated"] extends true ? K : never;
}[ServerOperationId];

/** The argument of a server API call. */
export type ServerCallArgs<K extends ServerOperationId> = CallArgs<operations[K]>;

/** The success body of a server API call. */
export type ServerResult<K extends ServerOperationId> = ResponseOf<operations[K]>;

/** The item of a server API list. */
export type ServerListItem<K extends ServerListOperationId> = ItemOf<operations[K]>;

/** Options of the server client. */
export interface RelayServerClientOptions extends TransportOptions {
  /** Builds the DPoP authorization headers of every attempt (see `dpopAuthenticator`). */
  readonly authenticate: NonNullable<TransportOptions["authenticate"]>;
}

/**
 * The server API client (X-29): every operation of the contract, an Idempotency-Key generated per call and kept across retries, retries only on `retryable: true` with exponential backoff, full jitter and Retry-After, typed errors, and lazy pagination. The SDK always sends the API version it was generated from.
 */
export class RelayServerClient {
  readonly transport: Transport;

  constructor(options: RelayServerClientOptions) {
    this.transport = new Transport(options);
  }

  /** Calls an operation and returns its body. */
  async call<K extends ServerOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Promise<ServerResult<K>> {
    const response = await this.callRaw(operation, ...args);
    return response.data;
  }

  /** Calls an operation and returns the body with status, headers, request id and replay flag. */
  callRaw<K extends ServerOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Promise<RelayResponse<ServerResult<K>>> {
    return invoke<ServerResult<K>>(
      this.transport,
      serverOperations[operation],
      ((args[0] as unknown) ?? {}) as LooseArgs,
    );
  }

  /** Iterates lazily over every item of a list operation. */
  paginate<K extends ServerListOperationId>(
    operation: K,
    ...args: CallArgsTuple<operations[K]>
  ): Paginator<ServerListItem<K>> {
    return paginate<ServerListItem<K>>(
      this.transport,
      serverOperations[operation],
      ((args[0] as unknown) ?? {}) as LooseArgs,
    );
  }
}
