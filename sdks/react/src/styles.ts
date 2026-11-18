const rawStyles = `
.relay-root {
  color: var(--relay-color-text);
  background: var(--relay-color-background);
  font-family: var(--relay-font-family);
  font-size: var(--relay-font-size);
  line-height: 1.5;
  box-sizing: border-box;
}
.relay-root *, .relay-root *::before, .relay-root *::after { box-sizing: inherit; }
.relay-root :focus-visible {
  outline: 3px solid var(--relay-color-focus);
  outline-offset: 2px;
}
.relay-sr-only {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
}
.relay-heading { font-size: 1.25em; font-weight: 600; margin: 0 0 0.75em; }
.relay-subheading { font-size: 1.05em; font-weight: 600; margin: 1.25em 0 0.5em; }
.relay-muted { color: var(--relay-color-muted); }
.relay-row { display: flex; flex-wrap: wrap; gap: 0.5em; align-items: center; }
.relay-stack > * + * { margin-top: 0.5em; }
.relay-button {
  min-height: 44px; min-width: 44px; padding: 0.5em 1em;
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  background: var(--relay-color-surface); color: var(--relay-color-text);
  font: inherit; font-weight: 500; cursor: pointer;
  display: inline-flex; align-items: center; justify-content: center; gap: 0.4em;
}
.relay-button:hover { border-color: var(--relay-color-text); }
.relay-button[aria-disabled="true"], .relay-button:disabled { cursor: not-allowed; opacity: 0.7; }
.relay-button-primary {
  background: var(--relay-color-accent); color: var(--relay-color-accent-text);
  border-color: var(--relay-color-accent);
}
.relay-button-small { min-height: 32px; min-width: 32px; padding: 0.25em 0.6em; font-size: 0.9em; }
.relay-link { color: var(--relay-color-accent); text-decoration: underline; font-weight: 500; }
.relay-choice-group { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.5em; }
.relay-choice {
  min-height: 44px; padding: 0.5em; border: 1px solid var(--relay-color-border);
  border-radius: var(--relay-radius); background: var(--relay-color-surface);
  color: var(--relay-color-text); font: inherit; font-weight: 500; cursor: pointer;
}
.relay-input, .relay-select {
  min-height: 44px; padding: 0.4em 0.6em; font: inherit;
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  background: var(--relay-color-background); color: var(--relay-color-text);
}
.relay-field { display: flex; flex-direction: column; gap: 0.25em; margin-bottom: 0.75em; }
.relay-field label, .relay-label { font-weight: 500; }
.relay-error { color: var(--relay-color-danger); font-weight: 500; }
.relay-error::before { content: "\\26A0\\FE0E  "; }
.relay-success { color: var(--relay-color-success); font-weight: 500; }
.relay-success::before { content: "\\2713  "; }
.relay-status { display: inline-flex; align-items: center; gap: 0.3em; font-size: 0.9em; font-weight: 500; }
.relay-status-icon { font-style: normal; }
.relay-tag {
  display: inline-flex; align-items: center; gap: 0.3em; padding: 0.05em 0.5em;
  border: 1px solid var(--relay-color-border); border-radius: 999px; font-size: 0.85em;
}
.relay-bell {
  position: relative; min-height: 44px; min-width: 44px; padding: 0.5em;
  border: 1px solid var(--relay-color-border); border-radius: 999px;
  background: var(--relay-color-surface); color: var(--relay-color-text); cursor: pointer;
}
.relay-badge {
  position: absolute; top: -4px; right: -4px; min-width: 1.5em; padding: 0 0.35em;
  border-radius: 999px; background: var(--relay-color-danger); color: var(--relay-color-background);
  font-size: 0.75em; font-weight: 700; line-height: 1.5em; text-align: center;
}
.relay-inbox { max-width: 40em; }
.relay-root.relay-inline { display: inline-block; background: transparent; }
.relay-tabs { display: flex; flex-wrap: wrap; gap: 0.25em; margin: 0 0 0.5em; padding: 0; }
.relay-tab {
  min-height: 44px; padding: 0.4em 0.9em; border: 1px solid var(--relay-color-border);
  border-radius: var(--relay-radius); background: var(--relay-color-background);
  color: var(--relay-color-text); font: inherit; cursor: pointer;
}
.relay-tab[aria-pressed="true"] {
  background: var(--relay-color-accent); color: var(--relay-color-accent-text);
  border-color: var(--relay-color-accent); font-weight: 600; text-decoration: underline;
}
.relay-list { list-style: none; margin: 0; padding: 0; }
.relay-item {
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  padding: 0.75em; margin-bottom: 0.5em; background: var(--relay-color-background);
}
.relay-item-unread { border-left: 6px solid var(--relay-color-accent); }
.relay-item-title { font-weight: 600; margin: 0; }
.relay-item-unread .relay-item-title { font-weight: 700; }
.relay-item-body { margin: 0.25em 0; }
.relay-item-meta { display: flex; flex-wrap: wrap; gap: 0.5em; align-items: center; font-size: 0.9em; }
.relay-item-actions { display: flex; flex-wrap: wrap; gap: 0.4em; margin-top: 0.5em; }
.relay-menu { position: relative; display: inline-block; }
.relay-menu-list {
  position: absolute; z-index: 10; margin: 0.25em 0 0; padding: 0.25em; list-style: none;
  background: var(--relay-color-background); border: 1px solid var(--relay-color-border);
  border-radius: var(--relay-radius); min-width: 14em;
}
.relay-menu-list button { width: 100%; justify-content: flex-start; border: 0; }
.relay-notice {
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  padding: 0.5em 0.75em; margin: 0.5em 0; background: var(--relay-color-surface);
  display: flex; flex-wrap: wrap; gap: 0.5em; align-items: center;
}
.relay-toaster {
  position: fixed; z-index: 1000; right: 1em; bottom: 1em; display: flex;
  flex-direction: column; gap: 0.5em; max-width: min(24em, calc(100vw - 2em));
}
.relay-toast {
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  background: var(--relay-color-background); color: var(--relay-color-text);
  padding: 0.75em; box-shadow: 0 4px 16px rgba(0, 0, 0, 0.2);
}
.relay-matrix { border-collapse: collapse; width: 100%; }
.relay-matrix th, .relay-matrix td {
  border: 1px solid var(--relay-color-border); padding: 0.4em; text-align: left; vertical-align: top;
}
.relay-matrix thead th { background: var(--relay-color-surface); }
.relay-matrix-scroll { overflow-x: auto; }
.relay-switch {
  display: inline-flex; align-items: center; gap: 0.4em; min-height: 44px; padding: 0.25em 0.5em;
  border: 1px solid var(--relay-color-border); border-radius: 999px; font: inherit; font-weight: 500;
  background: var(--relay-color-background); color: var(--relay-color-text); cursor: pointer;
}
.relay-switch-track {
  position: relative; width: 2.25em; height: 1.25em; border-radius: 999px;
  border: 2px solid var(--relay-color-border); background: var(--relay-color-surface);
}
.relay-switch-track::after {
  content: ""; position: absolute; top: 1px; left: 1px; width: calc(1.25em - 6px); height: calc(1.25em - 6px);
  border-radius: 999px; background: var(--relay-color-muted);
}
.relay-switch[aria-checked="true"] .relay-switch-track {
  background: var(--relay-color-accent); border-color: var(--relay-color-accent);
}
.relay-switch[aria-checked="true"] .relay-switch-track::after {
  left: auto; right: 1px; background: var(--relay-color-accent-text);
}
.relay-dialog {
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  padding: 0.75em; margin: 0.5em 0; background: var(--relay-color-surface);
}
.relay-brand { display: flex; align-items: center; gap: 0.5em; margin-bottom: 0.75em; }
.relay-brand img { max-height: 32px; width: auto; }
.relay-card {
  border: 1px solid var(--relay-color-border); border-radius: var(--relay-radius);
  padding: 0.75em; margin-bottom: 0.75em;
}
.relay-checklist { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.25em; }
.relay-checklist label { display: flex; gap: 0.5em; align-items: center; min-height: 32px; }
.relay-checklist input, .relay-check input { width: 24px; height: 24px; margin: 0; }
.relay-check { display: flex; gap: 0.5em; align-items: center; min-height: 44px; }
.relay-code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all;
  background: var(--relay-color-surface); padding: 0.25em 0.4em; border-radius: 4px;
}
@media (prefers-reduced-motion: no-preference) {
  .relay-switch-track::after { transition: left 120ms ease, right 120ms ease; }
}
`;

/**
 * The stylesheet of the components. Every colour and shape comes from a `--relay-*` custom property; one set on the page or on a host element wins, and the theme of the provider is the fallback.
 */
export const relayStyles = rawStyles.replace(
  /var\(--relay-([a-z-]+)\)/g,
  (_match, name: string) => `var(--relay-${name}, var(--relay-default-${name}))`,
);
