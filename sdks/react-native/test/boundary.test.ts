import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ALLOWED_OPERATIONS } from '../src/boundary';
import { RelayClient } from '../src/client';
import { memoryStore } from '../src/ports';
import { readYaml } from './helpers';

interface Operation {
  'x-relay-idempotency'?: string;
  security?: Record<string, string[]>[];
}

const contract = readYaml<{ paths: Record<string, Record<string, Operation>> }>(
  'contracts/openapi/subscriber.yaml',
);

const sourceRoot = fileURLToPath(new URL('../src', import.meta.url));

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === 'generated' ? [] : sources(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

describe('X-31 mobile SDK boundary', () => {
  it('X-31 every allowed operation exists in the subscriber contract with a subscriber token', () => {
    for (const operation of ALLOWED_OPERATIONS) {
      const entry = contract.paths[operation.path]?.[operation.method.toLowerCase()];
      expect(entry, `${operation.method} ${operation.path}`).toBeDefined();
      const schemes = (entry?.security ?? []).flatMap((requirement) => Object.keys(requirement));
      expect(schemes).toEqual(schemes.map(() => 'subscriber_bearer'));
      expect(schemes.length).toBeGreaterThan(0);
    }
  });

  it('X-29 sends an Idempotency-Key exactly where the contract requires one', () => {
    for (const operation of ALLOWED_OPERATIONS) {
      const entry = contract.paths[operation.path]?.[operation.method.toLowerCase()];
      expect(operation.idempotencyKey, operation.path).toBe(entry?.['x-relay-idempotency'] === 'required');
    }
  });

  it('X-31 allows no event trigger, no profile or consent write and no token exchange', () => {
    const paths = ALLOWED_OPERATIONS.map((operation) => operation.path);
    for (const path of paths) {
      expect(path.startsWith('/v1/subscriber/') || path.startsWith('/v1/realtime/')).toBe(true);
      expect(path).not.toMatch(
        /consent|^\/v1\/events|notifications|\/token|waitpoints|portal|test_recipients|bulk/,
      );
    }
  });

  it('X-31 the sources name no server-family endpoint and take no secret credential', () => {
    const forbidden = [
      /\/v1\/events/,
      /\/v1\/notifications/,
      /\/v1\/subscribers\//,
      /\/v1\/subscriber\/token/,
      /\/v1\/portal\//,
      /apiKey|api_key|clientSecret|client_secret|privateKey/,
      /Authorization: `DPoP/,
    ];
    for (const file of sources(sourceRoot)) {
      const text = readFileSync(file, 'utf8');
      for (const pattern of forbidden) expect(text, `${file} ${String(pattern)}`).not.toMatch(pattern);
    }
  });

  it('X-31 the client has no method that sends an event or writes a profile', () => {
    const client = new RelayClient({
      baseUrl: 'https://relay.example.com',
      tokenProvider: () => Promise.resolve({ token: 't' }),
      storage: memoryStore(),
      realtime: false,
    });
    const methods = Object.getOwnPropertyNames(Object.getPrototypeOf(client));
    for (const name of methods) expect(name).not.toMatch(/trigger|event|send|profile|consent/i);
    expect(Object.keys(client.preferences)).not.toContain('consents');
  });
});
