import { useCallback, useEffect, useMemo, useState } from "react";
import { useRequestContext } from "../session/session";
import { ApiError, request, type QueryValue } from "./client";
import type { Page } from "./types";

export type Load<T> =
  | { kind: "loading" }
  | { kind: "error"; error: unknown }
  | { kind: "ready"; data: T };

export interface Loaded<T> {
  state: Load<T>;
  reload: () => void;
}

/** Reads one API resource in the current tenant context; a null path reads nothing. */
export function useGet<T>(
  path: string | null,
  query: Record<string, QueryValue> = {},
): Loaded<T> {
  const context = useRequestContext();
  const [state, setState] = useState<{ id: string; load: Load<T> }>({
    id: "",
    load: { kind: "loading" },
  });
  const [attempt, setAttempt] = useState(0);
  const key = JSON.stringify(query);
  const id = `${context.tenant ?? ""}|${context.environment}|${path ?? ""}?${key}`;

  useEffect(() => {
    if (path === null) return;
    const controller = new AbortController();
    const parsed = JSON.parse(key) as Record<string, QueryValue>;
    request<T>("GET", path, {
      query: parsed,
      context,
      signal: controller.signal,
    }).then(
      (data) => {
        setState({ id, load: { kind: "ready", data } });
      },
      (error: unknown) => {
        if (!controller.signal.aborted)
          setState({ id, load: { kind: "error", error } });
      },
    );
    return () => {
      controller.abort();
    };
  }, [id, path, key, context, attempt]);

  const reload = useCallback(() => {
    setAttempt((value) => value + 1);
  }, []);

  const current: Load<T> = state.id === id ? state.load : { kind: "loading" };
  return { state: current, reload };
}

export interface Paged<T> extends Loaded<Page<T>> {
  items: T[];
  hasNext: boolean;
  hasPrevious: boolean;
  next: () => void;
  previous: () => void;
}

/** Pages through a cursor list one page at a time. */
export function usePaged<T>(
  path: string | null,
  query: Record<string, QueryValue> = {},
  limit = 25,
): Paged<T> {
  const [cursors, setCursors] = useState<string[]>([]);
  const filterKey = JSON.stringify(query);
  const [lastFilter, setLastFilter] = useState(filterKey);
  if (lastFilter !== filterKey) {
    setLastFilter(filterKey);
    setCursors([]);
  }
  const starting = cursors.at(-1);
  const merged = useMemo(
    () => ({
      ...(JSON.parse(filterKey) as Record<string, QueryValue>),
      limit,
      starting_after: starting,
    }),
    [filterKey, limit, starting],
  );
  const loaded = useGet<Page<T>>(path, merged);
  const page = loaded.state.kind === "ready" ? loaded.state.data : null;
  const nextCursor = page?.next_cursor ?? null;

  return {
    ...loaded,
    items: page?.data ?? [],
    hasNext: page?.has_more === true && nextCursor !== null,
    hasPrevious: cursors.length > 0,
    next: () => {
      if (nextCursor !== null) setCursors((value) => [...value, nextCursor]);
    },
    previous: () => {
      setCursors((value) => value.slice(0, -1));
    },
  };
}

/** Sends one mutating request in the current tenant context. */
export function useMutation() {
  const context = useRequestContext();
  return useCallback(
    <T>(
      method: "POST" | "PUT" | "PATCH" | "DELETE",
      path: string,
      body: unknown,
      idempotencyKey: string,
      ifMatch?: string,
    ) =>
      request<T>(method, path, {
        body,
        idempotencyKey,
        context,
        ...(ifMatch === undefined ? {} : { ifMatch }),
      }),
    [context],
  );
}

/** Reads one API resource on demand in the current tenant context, outside the render cycle. */
export function useFetch() {
  const context = useRequestContext();
  return useCallback(
    <T>(path: string, accept?: string) =>
      request<T>("GET", path, {
        context,
        ...(accept === undefined ? {} : { accept }),
      }),
    [context],
  );
}

export function errorStatus(error: unknown): number | null {
  return error instanceof ApiError ? error.status : null;
}

export function errorCode(error: unknown): string | null {
  return error instanceof ApiError ? error.code : null;
}
