import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { ApiError, request } from "../api/client";
import type {
  Environment,
  OperatorSession,
  RoleGrant,
  StepUpChallenge,
} from "../api/types";
import { readStored, writeStored } from "../app/storage";

export type SessionState =
  | { kind: "loading" }
  | { kind: "signed_out" }
  | { kind: "unavailable" }
  | { kind: "ready"; session: OperatorSession };

export interface WorkingContext {
  tenant: string | null;
  environment: Environment;
  subtenant: string | null;
}

export interface TenantChoice {
  tenant: string;
  environments: Environment[];
}

interface SessionValue {
  state: SessionState;
  context: WorkingContext;
  tenants: TenantChoice[];
  installationOperator: boolean;
  setContext: (next: Partial<WorkingContext>) => void;
  reload: () => void;
  signOut: () => Promise<void>;
  startStepUp: (returnTo: string) => Promise<void>;
}

const SessionContext = createContext<SessionValue | null>(null);

export const subtenantPattern = /^stn_[0-7][0-9a-hjkmnp-tv-z]{25}$/;

const storageKey = "relay.console.context";

export function tenantChoices(roles: readonly RoleGrant[]): TenantChoice[] {
  const byTenant = new Map<string, Set<Environment>>();
  for (const grant of roles) {
    if (grant.tenant_id === null || grant.environment === null) continue;
    const set = byTenant.get(grant.tenant_id) ?? new Set<Environment>();
    set.add(grant.environment);
    byTenant.set(grant.tenant_id, set);
  }
  return [...byTenant.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([tenant, set]) => ({
      tenant,
      environments: (["live", "test"] as const).filter((env) => set.has(env)),
    }));
}

export function resolveContext(
  wanted: Partial<WorkingContext>,
  tenants: readonly TenantChoice[],
): WorkingContext {
  const choice =
    tenants.find((item) => item.tenant === wanted.tenant) ?? tenants[0];
  if (choice === undefined)
    return { tenant: null, environment: "test", subtenant: null };
  const environment =
    wanted.environment && choice.environments.includes(wanted.environment)
      ? wanted.environment
      : (choice.environments[0] ?? "test");
  const subtenant =
    wanted.subtenant && subtenantPattern.test(wanted.subtenant)
      ? wanted.subtenant
      : null;
  return { tenant: choice.tenant, environment, subtenant };
}

function storedContext(): Partial<WorkingContext> {
  const raw = readStored(storageKey);
  if (raw === null) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed !== null && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<SessionState>({ kind: "loading" });
  const [wanted, setWanted] = useState<Partial<WorkingContext>>(storedContext);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    request<OperatorSession>("GET", "/v1/operator/session", {
      signal: controller.signal,
    }).then(
      (session) => {
        setState({ kind: "ready", session });
      },
      (error: unknown) => {
        if (controller.signal.aborted) return;
        setState(
          error instanceof ApiError && error.status === 401
            ? { kind: "signed_out" }
            : { kind: "unavailable" },
        );
      },
    );
    return () => {
      controller.abort();
    };
  }, [attempt]);

  const session = state.kind === "ready" ? state.session : null;
  const tenants = useMemo(
    () => (session ? tenantChoices(session.roles) : []),
    [session],
  );
  const context = useMemo(
    () => resolveContext(wanted, tenants),
    [wanted, tenants],
  );
  const installationOperator =
    session?.roles.some((grant) => grant.role === "installation_operator") ??
    false;

  const setContext = useCallback((next: Partial<WorkingContext>) => {
    setWanted((previous) => {
      const merged = { ...previous, ...next };
      if (next.tenant !== undefined && next.tenant !== previous.tenant)
        merged.subtenant = null;
      writeStored(storageKey, JSON.stringify(merged));
      return merged;
    });
  }, []);

  const reload = useCallback(() => {
    setState({ kind: "loading" });
    setAttempt((value) => value + 1);
  }, []);

  const csrf = session?.csrf_token ?? null;

  const signOut = useCallback(async () => {
    await request<undefined>("DELETE", "/v1/operator/session", {
      context: { tenant: null, environment: null, csrf },
    });
    setState({ kind: "signed_out" });
  }, [csrf]);

  const startStepUp = useCallback(
    async (returnTo: string) => {
      const challenge = await request<StepUpChallenge>(
        "POST",
        "/v1/operator/session/step_up",
        {
          body: { return_to: returnTo },
          context: { tenant: null, environment: null, csrf },
        },
      );
      window.location.assign(challenge.authorization_url);
    },
    [csrf],
  );

  const value = useMemo<SessionValue>(
    () => ({
      state,
      context,
      tenants,
      installationOperator,
      setContext,
      reload,
      signOut,
      startStepUp,
    }),
    [
      state,
      context,
      tenants,
      installationOperator,
      setContext,
      reload,
      signOut,
      startStepUp,
    ],
  );

  return <SessionContext value={value}>{children}</SessionContext>;
}

export function useSession(): SessionValue {
  const value = useContext(SessionContext);
  if (value === null) throw new Error("useSession outside SessionProvider");
  return value;
}

/** The request context of the current tenant, environment and CSRF token. */
export function useRequestContext() {
  const { state, context } = useSession();
  return useMemo(
    () => ({
      tenant: context.tenant,
      environment: context.environment,
      csrf: state.kind === "ready" ? state.session.csrf_token : null,
    }),
    [state, context],
  );
}
