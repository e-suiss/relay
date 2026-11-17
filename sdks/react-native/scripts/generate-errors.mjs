import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const source = fileURLToPath(new URL('../../../contracts/errors.yaml', import.meta.url));
const target = fileURLToPath(new URL('../src/generated/errors.ts', import.meta.url));
const catalog = parse(readFileSync(source, 'utf8'));

const defaults = catalog.retryable_defaults.map((entry) => ({
  status: entry.status,
  code: entry.code ?? null,
  retryable: entry.retryable === true,
}));

const codes = Object.fromEntries(
  [...catalog.codes]
    .sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0))
    .map((entry) => [
      entry.code,
      { family: entry.family, status: entry.status, retryable: entry.retryable === true },
    ]),
);

const lines = [
  `export const ERROR_CATALOG_VERSION = ${JSON.stringify(catalog.version)};`,
  '',
  'export const RETRYABLE_DEFAULTS: readonly {',
  '  readonly status: number;',
  '  readonly code: string | null;',
  '  readonly retryable: boolean;',
  `}[] = ${JSON.stringify(defaults, null, 2)};`,
  '',
  'export const ERROR_CODES: Readonly<',
  '  Record<string, { readonly family: string; readonly status: number; readonly retryable: boolean }>',
  `> = ${JSON.stringify(codes, null, 2)};`,
  '',
];

writeFileSync(target, lines.join('\n'));
