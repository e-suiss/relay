import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const root = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      'react-native': join(root, 'test', 'shims', 'react-native.tsx'),
    },
  },
  oxc: { jsx: { runtime: 'automatic' } },
  test: {
    include: ['test/**/*.test.{ts,tsx}'],
    environment: 'node',
    restoreMocks: true,
  },
});
