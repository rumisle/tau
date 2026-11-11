// What is written and not sent, per chat, on this device (docs/sending.md "Edits and drafts"): Web A saves a chat's draft
// through `saveDraft` (when the chat changes, ten seconds after typing stops, before the page unloads), and Telegram's
// server would keep it; here localStorage keeps it, written at once, so a reload or a crash keeps it.
import type { ApiDraft } from '../../api/types';

import { serverOrigin } from '../auth';

type Stored = Record<string, Pick<ApiDraft, 'text' | 'date'>>;

const keyOf = () => `tau-drafts:${serverOrigin()}`;

export function readDrafts(): Stored {
  try {
    return JSON.parse(localStorage.getItem(keyOf()) ?? '{}') as Stored;
  } catch {
    return {};
  }
}

/** A chat's draft, or none: cleared when the field is emptied or its message sent */
export function writeDraft(chatId: string, draft?: ApiDraft) {
  const drafts = readDrafts();
  if (draft?.text?.text) drafts[chatId] = { text: draft.text, date: draft.date };
  else delete drafts[chatId];
  localStorage.setItem(keyOf(), JSON.stringify(drafts));
}

/** The drafts of these chats, as Web A takes them with the chat list */
export function draftsOf(chatIds: string[]): Record<string, ApiDraft> {
  const drafts = readDrafts();
  return Object.fromEntries(chatIds.filter((id) => drafts[id]).map((id) => [id, drafts[id]]));
}

/** What the drafts of every server take in localStorage */
export function draftBytes() {
  let bytes = 0;
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key?.startsWith('tau-drafts:')) bytes += new TextEncoder().encode(localStorage.getItem(key) ?? '').length;
  }
  return bytes;
}
