import { readFileSync } from "node:fs";

const repository = new URL("../../../", import.meta.url);

export function readRepositoryJson<T>(path: string): T {
  return JSON.parse(readFileSync(new URL(path, repository), "utf8")) as T;
}

export function readVector<T>(name: string): T {
  return readRepositoryJson<T>(`conformance/sdk/vectors/1/${name}.json`);
}

export interface VectorResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: unknown;
}

export interface NetworkError {
  readonly network_error: true;
}

export function toResponse(response: VectorResponse): Response {
  const headers = new Headers(response.headers);
  let body: string | null = null;
  if (response.body !== null && response.body !== undefined) {
    if (typeof response.body === "string") {
      body = response.body;
    } else {
      body = JSON.stringify(response.body);
      if (!headers.has("content-type")) headers.set("content-type", "application/json");
    }
  }
  return new Response(response.status === 204 ? null : body, { status: response.status, headers });
}

export function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

export const noSleep = async (): Promise<void> => undefined;
