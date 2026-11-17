/** A window client as the service worker sees it. */
export interface WindowClientLike {
  readonly url: string;
  focus(): Promise<unknown>;
  navigate?(url: string): Promise<unknown>;
}

/** The parts of the service worker global scope the helpers use. */
export interface ServiceWorkerScopeLike {
  readonly location: { readonly origin: string };
  readonly registration: {
    showNotification(title: string, options?: Record<string, unknown>): Promise<void>;
  };
  readonly clients: {
    matchAll(options: {
      type: "window";
      includeUncontrolled: boolean;
    }): Promise<readonly WindowClientLike[]>;
    openWindow(url: string): Promise<unknown>;
  };
  readonly navigator?: {
    setAppBadge?(count?: number): Promise<void>;
    clearAppBadge?(): Promise<void>;
  };
  addEventListener(type: string, listener: (event: never) => void): void;
}

/** A notification as the click handler sees it. */
export interface NotificationLike {
  readonly data?: unknown;
  close(): void;
}

interface DeclarativeNotification {
  readonly title?: string;
  readonly navigate?: string;
  readonly body?: string;
  readonly tag?: string;
  readonly lang?: string;
  readonly dir?: string;
  readonly silent?: boolean;
  readonly app_badge?: string | number;
  readonly data?: unknown;
  readonly actions?: readonly {
    readonly action: string;
    readonly title: string;
    readonly navigate?: string;
  }[];
}

interface PushPayload {
  readonly notification?: DeclarativeNotification;
  readonly app_badge?: string | number;
  readonly counters?: { readonly unseen?: number };
}

/** The badge count a push carries, or null when it carries none. */
export function badgeFromPayload(payload: unknown): number | null {
  if (typeof payload !== "object" || payload === null) return null;
  const push = payload as PushPayload;
  const raw = push.notification?.app_badge ?? push.app_badge ?? push.counters?.unseen;
  if (raw === undefined) return null;
  const count = typeof raw === "number" ? raw : Number(raw);
  return Number.isInteger(count) && count >= 0 ? count : null;
}

/** The in-app badge text: the count, capped at "99+" (IN-20). */
export function formatBadge(count: number): string {
  return count > 99 ? "99+" : String(Math.max(0, Math.floor(count)));
}

/**
 * Handles a push in the service worker (IN-36): updates the app badge from the absolute count the push carries and shows the notification of a declarative or classic payload that names a title. Returns once both are done; pass it to `event.waitUntil`.
 */
export async function handlePush(scope: ServiceWorkerScopeLike, payload: unknown): Promise<void> {
  const badge = badgeFromPayload(payload);
  if (badge !== null) {
    if (badge === 0 && scope.navigator?.clearAppBadge) await scope.navigator.clearAppBadge();
    else if (scope.navigator?.setAppBadge) await scope.navigator.setAppBadge(badge);
  }
  const notification = (payload as PushPayload | null)?.notification;
  if (notification?.title === undefined) return;
  await scope.registration.showNotification(notification.title, {
    ...(notification.body === undefined ? {} : { body: notification.body }),
    ...(notification.tag === undefined ? {} : { tag: notification.tag }),
    ...(notification.lang === undefined ? {} : { lang: notification.lang }),
    ...(notification.dir === undefined ? {} : { dir: notification.dir }),
    ...(notification.silent === undefined ? {} : { silent: notification.silent }),
    ...(notification.actions === undefined
      ? {}
      : { actions: notification.actions.map(({ action, title }) => ({ action, title })) }),
    data: {
      navigate: notification.navigate,
      actions: notification.actions ?? [],
      data: notification.data,
    },
  });
}

/**
 * Handles a notification click (IN-36): closes the notification and brings the user to its URL, focusing an open tab of the same origin when there is one instead of opening another.
 */
export async function handleNotificationClick(
  scope: ServiceWorkerScopeLike,
  notification: NotificationLike,
  action = "",
): Promise<void> {
  notification.close();
  const data = (notification.data ?? {}) as {
    navigate?: string;
    url?: string;
    actions?: readonly { action: string; navigate?: string }[];
  };
  const target =
    data.actions?.find((item) => item.action === action)?.navigate ??
    data.navigate ??
    data.url ??
    "/";
  const url = new URL(target, scope.location.origin);
  const windows = await scope.clients.matchAll({ type: "window", includeUncontrolled: true });
  const sameOrigin = windows.find((client) => new URL(client.url).origin === url.origin);
  if (sameOrigin !== undefined) {
    if (sameOrigin.navigate && sameOrigin.url !== url.href) await sameOrigin.navigate(url.href);
    await sameOrigin.focus();
    return;
  }
  await scope.clients.openWindow(url.href);
}

interface PushEventLike {
  readonly data?: { json(): unknown } | null;
  waitUntil(promise: Promise<unknown>): void;
}

interface NotificationEventLike {
  readonly notification: NotificationLike;
  readonly action?: string;
  waitUntil(promise: Promise<unknown>): void;
}

/** Installs the push and notification click handlers on the service worker scope. */
export function installServiceWorkerHandlers(scope: ServiceWorkerScopeLike): void {
  scope.addEventListener("push", (event: PushEventLike) => {
    let payload: unknown;
    try {
      payload = event.data?.json() ?? null;
    } catch {
      payload = null;
    }
    event.waitUntil(handlePush(scope, payload));
  });
  scope.addEventListener("notificationclick", (event: NotificationEventLike) => {
    event.waitUntil(handleNotificationClick(scope, event.notification, event.action ?? ""));
  });
}
