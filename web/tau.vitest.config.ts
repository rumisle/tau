// tau's unit tests in web/ (docs/web.md "Tests, fast"): Vitest with Web A's Vite config, for its transforms and
// aliases, over src/tau only. Web A's own vitest.config.ts names a setup file its repository does not have.
import { defineConfig, mergeConfig } from 'vitest/config';

import viteConfig from './vite.config.ts';

export default defineConfig((configEnv) => mergeConfig(
  viteConfig(configEnv),
  {
    root: import.meta.dirname,
    define: {
      APP_REVISION: JSON.stringify('vitest-test'),
      APP_VERSION: JSON.stringify('0.0.1'),
    },
    test: {
      environment: 'jsdom',
      include: ['src/tau/**/*.test.ts'],
      setupFiles: ['src/tau/test-setup.ts'],
    },
  },
));
