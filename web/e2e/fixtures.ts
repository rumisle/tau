// A dev tau server per worker (the dev model, in memory, the built app, a token), as ios/scripts/uitests.py gives each
// simulator one; an API client to set chats up; and a page signed in with a `#token=` link, which fails the test if it
// asks anything of another origin.
import { type ChildProcess, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { expect, type Page, test as base } from '@playwright/test';

import { TauClient } from '../../client/src/connection.ts';
import type { Dialog } from '../../client/src/protocol.ts';
import { ConversationReplica } from '../../client/src/replica.ts';

const ROOT = resolve(import.meta.dirname, '../..');
const PORTS = (process.env.TAU_WEB_PORTS ?? '7960,7961,7962,7963,7964,7965,7966,7967').split(',').map(Number);
export const TOKEN = 'e2e-token-0123456789abcdef';

type Server = { origin: string; port: number };
type Api = {
  client: TauClient;
  /** A new chat with `messages` sent one after another, each answered */
  chat(title: string, messages: string[]): Promise<number>;
  /** Sends a message and waits for its answer */
  send(conversationId: number, content: string, options?: { wait?: boolean; attachments?: Attachment[] }): Promise<void>;
  /** Uploads a file as `POST /files` does for a message: its ID */
  upload(name: string, bytes: Uint8Array): Promise<string>;
};
type Attachment = { id: string; as?: 'image' | 'file' };

export const test = base.extend<{ api: Api; app: Page }, { server: Server }>({
  server: [async ({}, use, workerInfo) => {
    const port = PORTS[workerInfo.parallelIndex % PORTS.length];
    const home = mkdtempSync(join(tmpdir(), 'tau-web-e2e-'));
    const child = spawn(process.execPath, [
      '--no-warnings', join(ROOT, 'server/src/main.ts'), '--memory', '--port', String(port), '--host', '127.0.0.1',
      '--model', 'dev/echo', '--dev-tps', '400', '--web', join(ROOT, 'web/dist'), '--cwd', home,
    ], { env: { ...process.env, TAU_TOKEN: TOKEN, PI_CODING_AGENT_DIR: home }, stdio: ['ignore', 'pipe', 'pipe'] });
    await listening(child);
    await use({ origin: `http://127.0.0.1:${port}`, port });
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
    page.on('request', (request) => {
      const url = new URL(request.url());
      if (!['http:', 'ws:', 'blob:', 'data:'].includes(url.protocol) || url.host !== `127.0.0.1:${server.port}`) {
        if (url.protocol !== 'blob:' && url.protocol !== 'data:') foreign.push(request.url());
      }
    });
    await page.goto(`${server.origin}/#token=${TOKEN}`);
    await use(page);
    expect(foreign, 'requests to other origins').toEqual([]);
  },
});

export { expect };

// The smoke subset (`scripts/web/test.sh smoke`): open, read, send, steer and stop, files, a new chat; kept under 15 s
export const SMOKE = { tag: '@smoke' };

function listening(child: ChildProcess) {
  return new Promise<void>((done, fail) => {
    let output = '';
    const timer = setTimeout(() => fail(new Error(`the server did not start:\n${output}`)), 20_000);
    const read = (chunk: Buffer) => {
      output += chunk;
      if (output.includes('tau listening on')) {
        clearTimeout(timer);
        done();
      }
    };
    child.stdout!.on('data', read);
    child.stderr!.on('data', read);
    child.once('exit', (code) => fail(new Error(`the server exited (${code}):\n${output}`)));
  });
}
