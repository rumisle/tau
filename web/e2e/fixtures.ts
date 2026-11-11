// A dev tau server per worker (the dev model, in memory, the built app, a token), as ios/scripts/uitests.py gives each
// simulator one; an API client to set chats up; and a page signed in with a `#token=` link, which fails the test if it
// asks anything of another origin.
import { type ChildProcess, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { expect, type Page, test as base } from '@playwright/test';

import { TauClient } from '../../client/src/connection.ts';
import type { Dialog } from '../../client/src/protocol.ts';
import { ConversationReplica } from '../../client/src/replica.ts';

const ROOT = resolve(import.meta.dirname, '../..');
// A port per worker: 7960 to 7975, apart from iOS's 7979 and 7991 to 7995, the dev servers' 7990 and the live 7878
const PORTS = (process.env.TAU_WEB_PORTS ?? Array.from({ length: 16 }, (_, i) => 7960 + i).join(','))
  .split(',').map(Number);
// The app from Vite's dev server (scripts/web/test.sh e2e --dev), else the build in web/dist
const WEB = process.env.TAU_E2E_WEB_DEV
  ? ['--web-dev', process.env.TAU_E2E_WEB_DEV] : ['--web', join(ROOT, 'web/dist')];
export const TOKEN = 'e2e-token-0123456789abcdef';

type Server = { origin: string; port: number; home: string };
type Api = {
  client: TauClient;
  /** A new chat with `messages` sent one after another, each answered */
  chat(title: string, messages: string[]): Promise<number>;
  /** Sends a message and waits for its answer */
  send(conversationId: number, content: string, options?: { wait?: boolean; attachments?: Attachment[] }): Promise<void>;
  /** Uploads a file as `POST /files` does for a message: its ID */
  upload(name: string, bytes: Uint8Array): Promise<string>;
  /**
   * A command that keeps a run working until `open()`, for a test to act while it works whatever the page's speed
   * (a fixed `sleep` ends early under a slow load, as Vite's dev server's first one)
   */
  gate(): { command: string; open(): void };
};
type Attachment = { id: string; as?: 'image' | 'file' };

export const test = base.extend<{ api: Api; app: Page }, { server: Server }>({
  server: [async ({}, use, workerInfo) => {
    const port = PORTS[workerInfo.parallelIndex % PORTS.length];
    const home = mkdtempSync(join(tmpdir(), 'tau-web-e2e-'));
    const child = spawn(process.execPath, [
      '--no-warnings', join(ROOT, 'server/src/main.ts'), '--memory', '--port', String(port), '--host', '127.0.0.1',
      '--model', 'dev/echo', '--dev-tps', '400', ...WEB, '--cwd', home,
    ], { env: { ...process.env, TAU_TOKEN: TOKEN, PI_CODING_AGENT_DIR: home }, stdio: ['ignore', 'pipe', 'pipe'] });
    await listening(child);
    await use({ origin: `http://127.0.0.1:${port}`, port, home });
    const exited = new Promise((done) => child.once('exit', done));
    child.kill();
    await exited;
    rmSync(home, { recursive: true, force: true });
  }, { scope: 'worker' }],

  api: async ({ server }, use) => {
    const protocols = ['tau.v1', `tau.token.${Buffer.from(TOKEN).toString('base64url')}`];
    const client = await TauClient.open(new WebSocket(`ws://127.0.0.1:${server.port}/socket`, protocols));
    const send = async (
      conversationId: number, content: string, { wait = true, attachments }: { wait?: boolean; attachments?: Attachment[] } = {},
    ) => {
      const replica = new ConversationReplica(conversationId);
      await replica.sync(client);
      const { submission } = await client.request('conversation.submit', {
        conversationId, requestId: crypto.randomUUID(), content, ...(attachments && { attachments }),
      });
      if (!wait) return;
      await new Promise<void>((done) => {
        const check = () => {
          const live = replica.docs['pi.live'] as { run?: unknown } | undefined;
          if (replica.submissions.get(submission.id)?.status === 'done' && live?.run === undefined) done();
        };
        replica.onChange(check);
        check();
      });
      replica.detach();
    };
    await use({
      client,
      send,
      async upload(name, bytes) {
        const response = await fetch(`${server.origin}/files?name=${encodeURIComponent(name)}`, {
          method: 'POST', headers: { authorization: `Bearer ${TOKEN}` }, body: new Blob([bytes as Uint8Array<ArrayBuffer>]),
        });
        return ((await response.json()) as { id: string }).id;
      },
      gate() {
        const name = `gate-${crypto.randomUUID().slice(0, 8)}`;
        return {
          command: `$ until [ -e ${name} ]; do sleep 0.05; done`,
          open: () => writeFileSync(join(server.home, name), ''),
        };
      },
      async chat(title, messages) {
        const { dialog } = await client.request<{ dialog: Dialog }>('conversation.create', {
          title, requestId: crypto.randomUUID(),
        });
        for (const message of messages) await send(dialog.conversation.id, message);
        return dialog.conversation.id;
      },
    });
    await client.close();
  },

  app: async ({ page, server }, use) => {
    const foreign: string[] = [];
    secondHosts.clear();
    page.on('request', (request) => {
      const url = new URL(request.url());
      const isOurs = url.host === `127.0.0.1:${server.port}` || secondHosts.has(url.host);
      if (!['http:', 'ws:', 'blob:', 'data:'].includes(url.protocol) || !isOurs) {
        if (url.protocol !== 'blob:' && url.protocol !== 'data:') foreign.push(request.url());
      }
    });
    await page.goto(`${server.origin}/#token=${TOKEN}`);
    await use(page);
    expect(foreign, 'requests to other origins').toEqual([]);
  },
});

export { expect };

export const SECOND_TOKEN = 'second-token-0123456789abcdef';
// Servers a test started beside its worker's, which the page may reach
const secondHosts = new Set<string>();

/**
 * Another tau server, as a second one the app adds (docs/web.md "Several servers"): its own token, the dev/parrot model,
 * no web app, on a port of the system's choosing; stopped by the returned function
 */
export async function startSecondServer() {
  const home = mkdtempSync(join(tmpdir(), 'tau-web-e2e-second-'));
  const child = spawn(process.execPath, [
    '--no-warnings', join(ROOT, 'server/src/main.ts'), '--memory', '--port', '0', '--host', '127.0.0.1',
    '--model', 'dev/parrot', '--dev-tps', '400', '--no-web', '--cwd', home,
  ], { env: { ...process.env, TAU_TOKEN: SECOND_TOKEN, PI_CODING_AGENT_DIR: home }, stdio: ['ignore', 'pipe', 'pipe'] });
  const url = new URL(await listening(child));
  secondHosts.add(url.host);
  const client = await TauClient.open(new WebSocket(`ws://${url.host}/socket`, [
    'tau.v1', `tau.token.${Buffer.from(SECOND_TOKEN).toString('base64url')}`,
  ]));
  return {
    origin: `http://${url.host}`,
    host: url.host,
    client,
    async stop() {
      await client.close();
      const exited = new Promise((done) => child.once('exit', done));
      child.kill();
      await exited;
      rmSync(home, { recursive: true, force: true });
    },
  };
}

// The smoke subset (`scripts/web/test.sh smoke`): open, read, send, steer and stop, files, a new chat; kept under 15 s
export const SMOKE = { tag: '@smoke' };

function listening(child: ChildProcess) {
  return new Promise<string>((done, fail) => {
    let output = '';
    const timer = setTimeout(() => fail(new Error(`the server did not start:\n${output}`)), 20_000);
    const read = (chunk: Buffer) => {
      output += chunk;
      const url = /tau listening on (\S+)/.exec(output)?.[1];
      if (url) {
        clearTimeout(timer);
        done(url);
      }
    };
    child.stdout!.on('data', read);
    child.stderr!.on('data', read);
    child.once('exit', (code) => fail(new Error(`the server exited (${code}):\n${output}`)));
  });
}
