# Relay console

The tenant and operator console of Relay: a React application that Relay
builds into its image and serves at `/console` from the same origin as the
API. It signs in through Access, keeps one tenant, environment and subtenant
context visible on every page, and calls the server API with the operator
session (cookie, `Relay-Csrf-Token`, `Relay-Tenant`, `Relay-Environment`).

## Layout

- `src/api` — fetch client and types generated from `contracts/openapi`
  (`npm run generate`; CI fails when the committed types differ).
- `src/app` — shell, router, route table and working context bar.
- `src/components` — shared components: status badges, masked personal data
  with an audited reveal, engagement notices.
- `src/i18n` — Turkish and English texts; both catalogs carry the same keys
  and placeholders.
- `src/pages` — one folder or file per console area.
- `e2e` — Playwright tests against a mocked API, with an axe WCAG 2.2 AA
  check.

## Adding a page

Add the page component under `src/pages` and point its route in
`src/app/routes.tsx` at it. Routes are plain patterns such as
`/workflows/:key`; a trailing `/*` matches any rest of the path.

## Scripts

| Script                 | What it does                            |
| ---------------------- | --------------------------------------- |
| `npm run typecheck`    | Strict TypeScript check                 |
| `npm run lint`         | ESLint with type-aware rules            |
| `npm run format:check` | Prettier check                          |
| `npm test`             | Vitest unit tests                       |
| `npm run build`        | Production build into `dist/`           |
| `npm run e2e`          | Playwright and accessibility tests      |
| `npm run generate`     | Regenerate API types from the contracts |
