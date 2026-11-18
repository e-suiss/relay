import type { ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { RelayProvider, type RelayLinks } from "./context.js";
import type { Messages } from "./i18n/index.js";
import { Bell, type BellProps } from "./inbox/Bell.js";
import { Inbox, InboxPopover, type InboxPopoverProps, type InboxProps } from "./inbox/Inbox.js";
import { PreferenceCenter, type PreferenceCenterProps } from "./preferences/PreferenceCenter.js";
import { RelayRuntime, type RelayRuntimeOptions } from "./runtime.js";
import type { ColorScheme, RelayBrand, RelayTheme } from "./theme.js";
import { Toaster, type ToasterProps } from "./toast/Toaster.js";
import { WebhookPortal, type WebhookPortalProps } from "./portal/WebhookPortal.js";

/** The props of each component that can be mounted. */
export interface RelayComponentProps {
  readonly bell: BellProps;
  readonly inbox: InboxProps;
  readonly "inbox-popover": InboxPopoverProps;
  readonly toaster: ToasterProps;
  readonly "preference-center": PreferenceCenterProps;
  readonly "webhook-portal": WebhookPortalProps;
}

/** The name of a component that can be mounted. */
export type RelayComponentName = keyof RelayComponentProps;

/** Everything a mounted component renders with. */
export interface MountOptions<N extends RelayComponentName> {
  readonly runtime: RelayRuntime;
  readonly props: RelayComponentProps[N];
  readonly locale?: string;
  readonly messages?: Partial<Messages>;
  readonly theme?: RelayTheme;
  readonly brand?: RelayBrand;
  readonly subtenantBrand?: RelayBrand;
  readonly colorScheme?: ColorScheme;
  readonly links?: RelayLinks;
}

/** A mounted component. */
export interface MountedComponent<N extends RelayComponentName> {
  update(options: MountOptions<N>): void;
  unmount(): void;
}

/** Creates a runtime to share between mounted components, so they use one inbox and one connection. */
export function createRelayRuntime(options: RelayRuntimeOptions): RelayRuntime {
  return new RelayRuntime(options);
}

function element<N extends RelayComponentName>(name: N, props: RelayComponentProps[N]): ReactNode {
  switch (name) {
    case "bell":
      return <Bell {...(props as BellProps)} />;
    case "inbox":
      return <Inbox {...(props as InboxProps)} />;
    case "inbox-popover":
      return <InboxPopover {...(props as InboxPopoverProps)} />;
    case "toaster":
      return <Toaster {...(props as ToasterProps)} />;
    case "preference-center":
      return <PreferenceCenter {...(props as PreferenceCenterProps)} />;
    default:
      return <WebhookPortal {...(props as WebhookPortalProps)} />;
  }
}

function render<N extends RelayComponentName>(root: Root, name: N, options: MountOptions<N>): void {
  const { runtime, props, ...provider } = options;
  root.render(
    <RelayProvider runtime={runtime} {...provider}>
      {element(name, props)}
    </RelayProvider>,
  );
}

/**
 * Mounts a component into an element or a shadow root, for hosts that are not React apps, such as the web components of `@esuiss/relay-elements`.
 */
export function mountRelayComponent<N extends RelayComponentName>(
  target: Element | DocumentFragment,
  name: N,
  options: MountOptions<N>,
): MountedComponent<N> {
  const root = createRoot(target);
  render(root, name, options);
  return {
    update: (next) => render(root, name, next),
    unmount: () => root.unmount(),
  };
}
