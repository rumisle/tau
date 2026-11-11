// tau's backend in place of GramJS's worker connector: the same exports, which src/api/gramjs/index.ts re-exports, so
// the UI's `callApi` and `apiUpdate` stay as they are
import type { MethodArgs, MethodResponse, Methods } from '../../api/gramjs/methods/types';
import type { ApiInitialArgs, ApiOnProgress, OnApiUpdate } from '../../api/types';

import { DEBUG } from '../../config';
import { methods } from './methods';
import { start } from './session';

type EnsurePromise<T> = Promise<Awaited<T>>;

const unanswered = new Set<string>();
let started: Promise<void> | undefined;

export function initApi(onUpdate: OnApiUpdate, _initialArgs: ApiInitialArgs) {
  started ??= start(onUpdate);
  return started;
}

export function callApi<T extends keyof Methods>(fnName: T, ...args: MethodArgs<T>): EnsurePromise<MethodResponse<T>> {
  const method = methods[fnName];
  if (!method) {
    if (DEBUG && !unanswered.has(fnName)) {
      unanswered.add(fnName);
      // eslint-disable-next-line no-console
      console.debug('[tau] unanswered', fnName);
    }
    return Promise.resolve(undefined) as EnsurePromise<MethodResponse<T>>;
  }
  return Promise.resolve(method(...args)) as EnsurePromise<MethodResponse<T>>;
}

export const callApiLocal = callApi;

export function closeApi(_shouldClearLocalDb: boolean) {
  return Promise.resolve(true);
}

export function reconnectApi() {
  return Promise.resolve();
}

export function cancelApiProgress(_progressCallback: ApiOnProgress) {}

export function cancelApiProgressMaster(_messageId: string) {}

// Multitab: other tabs' calls through the master tab, and GramJS's local database. A tab here has its own socket.
export function handleMethodCallback(_data: unknown) {}

export function handleMethodResponse(_data: unknown) {}

export function updateFullLocalDb(_initial: unknown) {}

export function updateLocalDb(_name: unknown, _prop: string, _value: unknown) {}

export function setShouldEnableDebugLog(_value: boolean) {
  return Promise.resolve();
}
