import {
  createRelayRuntime,
  mountRelayComponent,
  type MountedComponent,
  type MountOptions,
  type RelayComponentName,
} from "@esuiss/relay-react/mount";

/** Returns a narrow Relay token: a subscriber token, or a portal token minted by the tenant backend. */
export type RelayTokenProvider = () => Promise<string> | string;

/** Theme tokens; each maps to a `--relay-*` CSS custom property, which a page can also set directly. */
export interface RelayElementsTheme {
  readonly background?: string;
  readonly surface?: string;
  readonly text?: string;
  readonly mutedText?: string;
  readonly border?: string;
  readonly accent?: string;
  readonly accentText?: string;
  readonly danger?: string;
  readonly success?: string;
  readonly warning?: string;
  readonly focus?: string;
  readonly radius?: string;
  readonly fontFamily?: string;
  readonly fontSize?: string;
}

/** A brand: name, logo and theme tokens per colour scheme. */
export interface RelayElementsBrand {
  readonly name?: string;
  readonly logoUrl?: string;
  readonly theme?: RelayElementsTheme;
  readonly darkTheme?: RelayElementsTheme;
}

/** Where the elements link outside Relay. */
export interface RelayElementsLinks {
  readonly accessConsentUrl?: string;
  readonly accessApprovalOrigin?: string;
  readonly preferencesHref?: (category: string | null) => string;
}

/** The configuration the elements share. Only narrow tokens are accepted (X-32). */
export interface RelayElementsConfig {
  readonly baseUrl: string;
  readonly token?: RelayTokenProvider;
  readonly portalToken?: RelayTokenProvider;
  readonly fetch?: (input: string, init?: RequestInit) => Promise<Response>;
  readonly realtime?: boolean;
  readonly undoWindowMs?: number;
  readonly locale?: string;
  readonly colorScheme?: "light" | "dark" | "auto";
  readonly theme?: RelayElementsTheme;
  readonly brand?: RelayElementsBrand;
  readonly subtenantBrand?: RelayElementsBrand;
  readonly messages?: Readonly<Record<string, string>>;
  readonly links?: RelayElementsLinks;
  /** Reports digests of the identifiers of displayed notifications to Relay, which measures duplicate displays with them; off by default. */
  readonly reportDisplayedNotifications?: boolean;
}

type Runtime = ReturnType<typeof createRelayRuntime>;

interface RelayElementLike {
  refresh(): void;
}

const connected = new Set<RelayElementLike>();

const runtimes = new WeakMap<RelayElementsConfig, Runtime>();
let globalConfig: RelayElementsConfig | null = null;

/** Sets the configuration every element uses unless it has its own `config`. */
export function configureRelay(config: RelayElementsConfig): void {
  globalConfig = config;
  for (const element of connected) element.refresh();
}

/** The runtime of a configuration: elements that share a configuration share one inbox and one connection. */
function runtimeOf(config: RelayElementsConfig): Runtime {
  let runtime = runtimes.get(config);
  if (runtime === undefined) {
    runtime = createRelayRuntime({
      baseUrl: config.baseUrl,
      ...(config.token === undefined ? {} : { token: config.token }),
      ...(config.portalToken === undefined ? {} : { portalToken: config.portalToken }),
      ...(config.fetch === undefined ? {} : { fetch: config.fetch }),
      ...(config.realtime === false ? { realtime: false as const } : {}),
      ...(config.undoWindowMs === undefined ? {} : { undoWindowMs: config.undoWindowMs }),
      ...(config.reportDisplayedNotifications === true
        ? { reportDisplayedNotifications: true }
        : {}),
    });
    runtimes.set(config, runtime);
  }
  return runtime;
}

/** Reports that the page displayed a notification itself, by its Relay identifier, with the given configuration or the global one; does nothing while reporting is off. */
export function reportDisplayedNotification(
  id: string,
  config: RelayElementsConfig | null = globalConfig,
): void {
  if (config === null) return;
  runtimeOf(config).reportDisplayed(id);
}

/** Sends the queued displayed notifications of a configuration, or of the global one, now. */
export function flushDisplayedNotifications(
  config: RelayElementsConfig | null = globalConfig,
): Promise<void> {
  if (config === null) return Promise.resolve();
  return runtimeOf(config).displayed?.flush() ?? Promise.resolve();
}

/** Reads a token from an endpoint of the application's own backend: JSON with `token` or `access_token`, or plain text. */
export function tokenFromUrl(url: string, fetcher: typeof fetch = fetch): RelayTokenProvider {
  return async () => {
    const response = await fetcher(url, {
      method: "POST",
      credentials: "include",
      headers: { accept: "application/json" },
    });
    if (!response.ok) throw new Error(`The token endpoint answered ${response.status}.`);
    const text = await response.text();
    try {
      const body = JSON.parse(text) as { token?: unknown; access_token?: unknown };
      const token = body.token ?? body.access_token;
      if (typeof token === "string") return token;
    } catch {
      return text.trim();
    }
    throw new Error("The token endpoint answered without a token.");
  };
}

const hostStyles = `
:host { display: block; }
:host([hidden]) { display: none; }
.relay-host { display: contents; }
`;

const inlineHostStyles = `
:host { display: inline-block; }
:host([hidden]) { display: none; }
.relay-host { display: contents; }
`;

interface ElementSpec {
  readonly tag: string;
  readonly component: RelayComponentName;
  readonly inline: boolean;
  readonly attributes: readonly string[];
  readonly props: (element: HTMLElement) => Record<string, unknown>;
}

function headingLevel(element: HTMLElement): 2 | 3 | undefined {
  const value = element.getAttribute("heading-level");
  return value === "3" ? 3 : value === "2" ? 2 : undefined;
}

function badgeSource(element: HTMLElement): "unseen" | "unread" | undefined {
  const value = element.getAttribute("badge-source");
  return value === "unread" ? "unread" : value === "unseen" ? "unseen" : undefined;
}

function list(element: HTMLElement, name: string): string[] | undefined {
  const value = element.getAttribute(name);
  if (value === null) return undefined;
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function defined<T extends Record<string, unknown>>(record: T): Partial<T> {
  const result: Partial<T> = {};
  for (const key of Object.keys(record) as (keyof T)[]) {
    if (record[key] !== undefined) result[key] = record[key];
  }
  return result;
}

const specs: readonly ElementSpec[] = [
  {
    tag: "relay-bell",
    component: "bell",
    inline: true,
    attributes: ["badge-source"],
    props: (element) => defined({ badgeSource: badgeSource(element) }),
  },
  {
    tag: "relay-inbox",
    component: "inbox",
    inline: false,
    attributes: ["heading-level", "categories", "tags"],
    props: (element) =>
      defined({
        headingLevel: headingLevel(element),
        categories: list(element, "categories"),
        tags: list(element, "tags"),
      }),
  },
  {
    tag: "relay-inbox-popover",
    component: "inbox-popover",
    inline: true,
    attributes: ["badge-source", "heading-level", "categories", "tags"],
    props: (element) =>
      defined({
        badgeSource: badgeSource(element),
        headingLevel: headingLevel(element),
        categories: list(element, "categories"),
        tags: list(element, "tags"),
      }),
  },
  {
    tag: "relay-toaster",
    component: "toaster",
    inline: true,
    attributes: ["duration"],
    props: (element) => {
      const duration = Number(element.getAttribute("duration"));
      return defined({
        durationMs: Number.isFinite(duration) && duration > 0 ? duration : undefined,
      });
    },
  },
  {
    tag: "relay-preference-center",
    component: "preference-center",
    inline: false,
    attributes: ["heading-level", "focus-category", "marketing-categories"],
    props: (element) =>
      defined({
        headingLevel: headingLevel(element),
        focusCategory: element.getAttribute("focus-category") ?? undefined,
        marketingCategories: list(element, "marketing-categories"),
      }),
  },
  {
    tag: "relay-webhook-portal",
    component: "webhook-portal",
    inline: false,
    attributes: ["heading-level"],
    props: (element) => defined({ headingLevel: headingLevel(element) }),
  },
];

const sharedAttributes = ["locale", "color-scheme", "base-url", "token-url", "portal-token-url"];

/** The tag names of the elements. */
export const relayElementTags: readonly string[] = specs.map((spec) => spec.tag);

function createElementClass(spec: ElementSpec): CustomElementConstructor {
  return class RelayElement extends HTMLElement implements RelayElementLike {
    static get observedAttributes(): string[] {
      return [...sharedAttributes, ...spec.attributes];
    }

    #config: RelayElementsConfig | null = null;
    #extraProps: Record<string, unknown> = {};
    #attributeConfig: { key: string; config: RelayElementsConfig } | null = null;
    #mounted: MountedComponent<RelayComponentName> | null = null;
    #container: HTMLDivElement | null = null;

    /** This element's own configuration; the one of {@link configureRelay} otherwise. */
    get config(): RelayElementsConfig | null {
      return this.#config;
    }

    set config(value: RelayElementsConfig | null) {
      this.#config = value;
      this.refresh();
    }

    /** Extra component props that attributes cannot carry, such as `categoryLabel` or `consents`. */
    get props(): Record<string, unknown> {
      return this.#extraProps;
    }

    set props(value: Record<string, unknown>) {
      this.#extraProps = value;
      this.refresh();
    }

    connectedCallback(): void {
      const shadow = this.shadowRoot ?? this.attachShadow({ mode: "open" });
      if (this.#container === null) {
        const style = document.createElement("style");
        style.textContent = spec.inline ? inlineHostStyles : hostStyles;
        const container = document.createElement("div");
        container.className = "relay-host";
        shadow.append(style, container);
        this.#container = container;
      }
      connected.add(this);
      this.refresh();
    }

    disconnectedCallback(): void {
      connected.delete(this);
      this.#mounted?.unmount();
      this.#mounted = null;
    }

    attributeChangedCallback(): void {
      this.refresh();
    }

    #resolvedConfig(): RelayElementsConfig | null {
      if (this.#config !== null) return this.#config;
      const baseUrl = this.getAttribute("base-url");
      const tokenUrl = this.getAttribute("token-url");
      const portalTokenUrl = this.getAttribute("portal-token-url");
      if (baseUrl !== null && (tokenUrl !== null || portalTokenUrl !== null)) {
        const key = `${baseUrl}|${tokenUrl ?? ""}|${portalTokenUrl ?? ""}`;
        if (this.#attributeConfig?.key !== key) {
          this.#attributeConfig = {
            key,
            config: {
              ...(globalConfig ?? {}),
              baseUrl,
              ...(tokenUrl === null ? {} : { token: tokenFromUrl(tokenUrl) }),
              ...(portalTokenUrl === null ? {} : { portalToken: tokenFromUrl(portalTokenUrl) }),
            },
          };
        }
        return this.#attributeConfig.config;
      }
      return globalConfig;
    }

    /** Renders the component again with the current configuration, attributes and props. */
    refresh(): void {
      const container = this.#container;
      if (container === null || !this.isConnected) return;
      const config = this.#resolvedConfig();
      if (config === null) return;
      const links = {
        ...(config.links ?? {}),
        ...(config.links?.preferencesHref === undefined
          ? {
              onOpenPreferences: (category: string | null) =>
                this.dispatchEvent(
                  new CustomEvent("relay-open-preferences", {
                    detail: { category },
                    bubbles: true,
                    composed: true,
                  }),
                ),
            }
          : {}),
      };
      const scheme = this.getAttribute("color-scheme");
      const options = {
        runtime: runtimeOf(config),
        props: {
          ...spec.props(this),
          ...(spec.component === "inbox" || spec.component === "inbox-popover"
            ? {
                onItemOpen: (item: unknown) =>
                  this.dispatchEvent(
                    new CustomEvent("relay-item-open", {
                      detail: { item },
                      bubbles: true,
                      composed: true,
                    }),
                  ),
              }
            : {}),
          ...this.#extraProps,
        },
        locale: this.getAttribute("locale") ?? config.locale ?? document.documentElement.lang,
        colorScheme:
          scheme === "light" || scheme === "dark" || scheme === "auto"
            ? scheme
            : (config.colorScheme ?? "auto"),
        links,
        ...(config.theme === undefined ? {} : { theme: config.theme }),
        ...(config.brand === undefined ? {} : { brand: config.brand }),
        ...(config.subtenantBrand === undefined ? {} : { subtenantBrand: config.subtenantBrand }),
        ...(config.messages === undefined ? {} : { messages: config.messages }),
      } as unknown as MountOptions<RelayComponentName>;
      if (this.#mounted === null)
        this.#mounted = mountRelayComponent(container, spec.component, options);
      else this.#mounted.update(options);
    }
  };
}

/**
 * Defines the custom elements `relay-bell`, `relay-inbox`, `relay-inbox-popover`, `relay-toaster`, `relay-preference-center` and `relay-webhook-portal`. Each renders the React component of `@esuiss/relay-react` into its shadow root, so behaviour, texts and accessibility are the same in every framework. Elements already defined are left alone.
 */
export function defineRelayElements(registry: CustomElementRegistry = customElements): void {
  for (const spec of specs) {
    if (registry.get(spec.tag) === undefined) registry.define(spec.tag, createElementClass(spec));
  }
}
