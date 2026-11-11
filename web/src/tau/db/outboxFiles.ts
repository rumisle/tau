// The bytes of the outbox's photos and files (docs/files.md "In the app"), beside the outbox in IndexedDB, by key, until
// the messages that carry them are done with them
import { createStore, del, get, set } from 'idb-keyval';

const STORE = createStore('tau-outbox-files', 'files');

export function saveOutboxFile(key: string, blob: Blob) {
  return set(key, blob, STORE);
}

export function readOutboxFile(key: string) {
  return get<Blob>(key, STORE);
}

export function deleteOutboxFile(key: string) {
  return del(key, STORE);
}
