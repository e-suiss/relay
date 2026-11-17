import { Paginator, type Page, type QueryValue } from "./pagination.js";
import type { IdempotencyMode, RelayResponse, Transport } from "./transport.js";

/** One entry of a generated operation table. */
export interface OperationSpec {
  readonly method: string;
  readonly path: string;
  readonly idempotency: IdempotencyMode;
  readonly paginated: boolean;
  readonly contentType: string | null;
}

type SuccessStatus = 200 | 201 | 202 | 203 | 204 | 206;

type PathOf<O> = O extends { parameters: { path: infer P } } ? P : never;

type QueryOf<O> = O extends { parameters: { query?: infer Q } } ? NonNullable<Q> : never;

type BodyOf<O> = O extends { requestBody?: never }
  ? never
  : O extends { requestBody?: { content: infer C } }
    ? C[keyof C]
    : never;

type ContentOf<R> = R extends { content: infer C } ? C[keyof C] : undefined;

/** The JSON body of an operation's success responses. */
export type ResponseOf<O> = O extends { responses: infer R }
  ? { [S in keyof R & SuccessStatus]: ContentOf<R[S]> }[keyof R & SuccessStatus]
  : never;

/** The item type of a list operation. */
export type ItemOf<O> = ResponseOf<O> extends { data: readonly (infer T)[] } ? T : never;

/** Options every call takes besides its parameters. */
export interface CallOptions {
  /** The caller's Idempotency-Key; without it the SDK generates one per call and keeps it across retries. */
  readonly idempotencyKey?: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly signal?: AbortSignal;
  /** Content type of the body when the operation accepts several. */
  readonly contentType?: string;
}

type PathArg<O> = [PathOf<O>] extends [never] ? { readonly path?: undefined } : { readonly path: PathOf<O> };

type QueryArg<O> = [QueryOf<O>] extends [never] ? { readonly query?: undefined } : { readonly query?: QueryOf<O> };

type BodyArg<O> = [BodyOf<O>] extends [never]
  ? { readonly body?: undefined }
  : O extends { requestBody: object }
    ? { readonly body: BodyOf<O> }
    : { readonly body?: BodyOf<O> };

/** The argument of a call to operation `O`. */
export type CallArgs<O> = PathArg<O> & QueryArg<O> & BodyArg<O> & CallOptions;

/** The argument tuple of a call: optional when nothing in it is required. */
export type CallArgsTuple<O> = object extends CallArgs<O> ? [args?: CallArgs<O>] : [args: CallArgs<O>];

/** Untyped call arguments, as the operation tables take them. */
export interface LooseArgs extends CallOptions {
  readonly path?: Readonly<Record<string, string | number>>;
  readonly query?: Readonly<Record<string, unknown>>;
  readonly body?: unknown;
}

function expand(template: string, path: LooseArgs["path"]): string {
  return template.replace(/\{([^}]+)\}/g, (_match, name: string) => {
    const value = path?.[name];
    if (value === undefined) throw new TypeError(`Missing path parameter ${name}.`);
    return encodeURIComponent(String(value));
  });
}

function toQuery(query: LooseArgs["query"]): Record<string, QueryValue> {
  const result: Record<string, QueryValue> = {};
  for (const [name, value] of Object.entries(query ?? {})) {
    if (value === undefined || value === null) continue;
    result[name] = Array.isArray(value) ? (value as (string | number | boolean)[]) : String(value);
  }
  return result;
}

/** Sends one operation of a generated table. */
export function invoke<T>(
  transport: Transport,
  spec: OperationSpec,
  args: LooseArgs = {},
): Promise<RelayResponse<T>> {
  return transport.request<T>({
    method: spec.method,
    path: expand(spec.path, args.path),
    query: toQuery(args.query),
    body: args.body,
    contentType: args.contentType ?? spec.contentType,
    idempotency: spec.idempotency,
    ...(args.idempotencyKey === undefined ? {} : { idempotencyKey: args.idempotencyKey }),
    ...(args.headers === undefined ? {} : { headers: args.headers }),
    ...(args.signal === undefined ? {} : { signal: args.signal }),
  });
}

/** A lazy iterator over a list operation of a generated table. */
export function paginate<T>(transport: Transport, spec: OperationSpec, args: LooseArgs = {}): Paginator<T> {
  return new Paginator<T>(async (query) => {
    const response = await invoke<Page<T>>(transport, spec, { ...args, query });
    return response.data;
  }, args.query ?? {});
}
