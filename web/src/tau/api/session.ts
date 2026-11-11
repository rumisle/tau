// The connection to this origin's tau server and what Web A's state is built from: the chat list by version and a
// replica per opened chat (tau-client), turned into `apiUpdate`s as GramJS's update handler sends them.
import { TauClient } from 'tau-client/connection';
import { DialogList } from 'tau-client/dialogs';
import type { Dialog, Entry } from 'tau-client/protocol';
import { ConversationReplica } from 'tau-client/replica';

import type { ApiMessage, ApiUpdate } from '../../api/types';
import type { MessageContext } from './builders';
import { MAIN_THREAD_ID } from '../../api/types';

import {
  probe, readToken, saveToken, serverOrigin, socketProtocols, socketUrl,
} from '../auth';
import { whenLinkTokenStored } from '../boot';
import {
  buildAssistantParts, buildAssistantRichMessage, buildChat, buildChatId, buildMe, buildMessage, buildReadState,
  buildSummaryMessage, buildThreadInfo, buildUser,
} from './builders';

// The PoC reads a transcript whole, in pages of the server's largest
const PAGE = 500;
// Web A drops a typing status a few seconds after it came, as Telegram's clients send theirs again every few seconds
const TYPING_REFRESH_MS = 4000;
const RECONNECT_MS = [500, 1000, 2000, 5000];

export type AuthStatus = 'connecting' | 'needsToken' | 'wrongToken' | 'unreachable' | 'ready';

type Opened = {
  replica: ConversationReplica;
  ready: Promise<void>;
  isLoaded: boolean;
  // Entries already turned into messages or folded into one (a tool result into its call)
  seen: Set<number>;
  // Tool results by call ID, and the entry each call is in
  results: Map<string, any>;
  callEntries: Map<string, number>;
  draftId?: string;
};

let onUpdate: (update: ApiUpdate) => void = () => undefined;
let client: TauClient | undefined;
let token: string | undefined;
let wasConnected = false;
let attempt = 0;
let typingTimer: number | undefined;
let authStatus: AuthStatus = 'connecting';
const authListeners = new Set<(status: AuthStatus) => void>();

export const dialogs = new DialogList();
const opened = new Map<number, Opened>();
// Entries a chat not open has shown as its Dialog's summary, by conversation: replaced or removed once it opens
const summarized = new Map<number, Set<number>>();
// The call that started each subagent, by the subagent's conversation
const subagentCalls = new Map<number, { parentId: number; callId: string }>();

dialogs.onChange((changed) => {
  for (const dialog of changed) applyDialog(dialog);
});

export async function start(callback: (update: ApiUpdate) => void) {
  onUpdate = callback;
  await whenLinkTokenStored();
  token = await readToken(serverOrigin());
  await connect();
}

/** The connect screen's token: kept when the server takes it */
export async function submitToken(given: string) {
  const result = await probe(serverOrigin(), given);
  if (result !== 'ok') {
    setAuthStatus(result === 'token' ? 'wrongToken' : 'unreachable');
    return false;
  }
  token = given;
  await saveToken(serverOrigin(), given);
  await connect();
  return true;
}

export function getAuthStatus() {
  return authStatus;
}

export function onAuthStatus(listener: (status: AuthStatus) => void) {
  authListeners.add(listener);
  return () => authListeners.delete(listener);
}

function setAuthStatus(status: AuthStatus) {
  authStatus = status;
  for (const listener of authListeners) listener(status);
  if (status === 'needsToken' || status === 'wrongToken') {
    // Web A's auth screen, where tau's connect screen is (src/tau/components/Connect.tsx)
    send({ '@type': 'updateAuthorizationState', authorizationState: 'authorizationStateWaitPhoneNumber' });
  }
}

async function connect() {
  const result = await probe(serverOrigin(), token);
  if (result !== 'ok') {
    if (result === 'token') setAuthStatus(token ? 'wrongToken' : 'needsToken');
    else scheduleReconnect('unreachable');
    return;
  }
  try {
    client = await TauClient.open(new WebSocket(socketUrl(), socketProtocols(token)));
  } catch {
    scheduleReconnect('unreachable');
    return;
  }
  attempt = 0;
  void client.closed.then(() => {
    client = undefined;
    send({ '@type': 'updateConnectionState', connectionState: 'connectionStateConnecting' });
    scheduleReconnect('connecting');
  });
  await dialogs.sync(client);
  if (!wasConnected) {
    wasConnected = true;
    send({ '@type': 'updateApiReady' });
    send({ '@type': 'updateAuthorizationState', authorizationState: 'authorizationStateReady' });
    send({ '@type': 'updateCurrentUser', currentUser: buildMe(), currentUserFullInfo: {} });
  } else {
    // Back after a dropped socket: open chats subscribe again from their newest entry
    for (const each of opened.values()) void each.replica.sync(client, { limit: PAGE });
  }
  setAuthStatus('ready');
  // Web A syncs (`loadAllChats`, then `fetchChats`) once connected and authorized
  send({ '@type': 'updateConnectionState', connectionState: 'connectionStateReady' });
  refreshTyping();
}

function scheduleReconnect(status: AuthStatus) {
  if (!wasConnected) setAuthStatus(status);
  const delay = RECONNECT_MS[Math.min(attempt++, RECONNECT_MS.length - 1)];
  window.setTimeout(() => void connect(), delay);
}

function applyDialog(dialog: Dialog) {
  const id = dialog.conversation.id;
  refreshTyping();
  if (dialog.conversation.owner) refreshSubagentCard(id);
  if (!isListed(dialog) || !wasConnected) return;
  sendDialog(dialog);
}

/**
 * A Dialog as Telegram's server sends a dialog (GramJS's `requestChatUpdate`): its peer, the chat, its thread's info and
 * read state, and its last message. A chat not open learns of new entries this way only, which skips some: the summary
 * is the chat's last message until it opens, not a message in its history (`newMessage` would make the history Web A
 * has of it look whole, with the entries between missing).
 */
function sendDialog(dialog: Dialog) {
  const id = dialog.conversation.id;
  const chatId = buildChatId(id);
  send({ '@type': 'updateUser', id: chatId, user: buildUser(dialog) });
  send({ '@type': 'updateThreadInfo', threadInfo: buildThreadInfo(dialog) });
  send({
    '@type': 'updateChat', id: chatId, chat: buildChat(dialog), readState: buildReadState(dialog),
  });
  if (!opened.has(id) && dialog.last) {
    const message = buildSummaryMessage(dialog)!;
    if (!summarized.has(id)) summarized.set(id, new Set());
    summarized.get(id)!.add(message.id);
    send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage: message });
  }
}

/** Web A asks for a chat it knows only from an update: what the server has of it now */
export function requestDialog(chatId: string) {
  const dialog = dialogs.dialogs.get(Number(chatId));
  if (dialog && isListed(dialog)) sendDialog(dialog);
}

export function isListed(dialog: Dialog) {
  return !dialog.hidden && !dialog.conversation.owner;
}

/** A conversation's replica, subscribed and loaded whole on first use */
function open(conversationId: number) {
  let each = opened.get(conversationId);
  if (each) return each;
  const replica = new ConversationReplica(conversationId);
  each = {
    replica, ready: Promise.resolve(), isLoaded: false, seen: new Set(), results: new Map(), callEntries: new Map(),
  };
  const current = each;
  opened.set(conversationId, each);
  replica.onChange(() => applyReplica(current));
  each.ready = load(current);
  return each;
}

async function load(each: Opened) {
  const { replica } = each;
  await replica.sync(client!, { limit: PAGE });
  while (replica.hasOlder) await replica.loadOlder(client!, PAGE);
  while (replica.holes.length > 0) await replica.fillHole(client!, PAGE);
  each.isLoaded = true;
  // Web A keeps a message it has: what stood for entries as the Dialog's summary is replaced by the entry's message,
  // or removed when the entry has none (a tool's result, which shows in its call's card)
  const chatId = buildChatId(replica.id);
  const stale = new Set(summarized.get(replica.id));
  const lastId = dialogs.dialogs.get(replica.id)?.last?.id;
  if (lastId !== undefined) stale.add(lastId);
  summarized.delete(replica.id);
  const removed: number[] = [];
  for (const id of stale) {
    const entry = replica.entries.get(id);
    const message = entry && buildMessage(entry, contextOf(each));
    if (message) {
      send({
        '@type': 'updateMessage', chatId, id, message, isFull: true,
      });
    } else {
      removed.push(id);
    }
  }
  if (removed.length > 0) send({ '@type': 'deleteMessages', ids: removed, chatId });
}

function applyReplica(each: Opened) {
  const fresh = each.replica.ordered().filter((entry) => !each.seen.has(entry.id));
  for (const entry of fresh) index(each, entry);
  if (each.isLoaded) {
    for (const entry of fresh) emitEntry(each, entry);
  }
  updateDraft(each);
}

function index(each: Opened, entry: Entry) {
  each.seen.add(entry.id);
  const message = (entry.model as any[] | undefined)?.[0];
  if (entry.kind === 'pi.assistant') {
    for (const part of message.content) {
      if (part.type === 'toolCall') each.callEntries.set(part.id, entry.id);
    }
  } else if (entry.kind === 'pi.tool-result') {
    each.results.set(message.toolCallId, message);
    const childId = message.details?.conversationId;
    if (message.toolName === 'subagent' && childId !== undefined) {
      subagentCalls.set(childId, { parentId: each.replica.id, callId: message.toolCallId });
    }
  }
}

function emitEntry(each: Opened, entry: Entry) {
  const chatId = buildChatId(entry.conversationId);
  if (entry.kind === 'pi.tool-result') {
    // The result shows in its call's message, which changes
    const call = each.replica.entries.get(each.callEntries.get((entry.model as any[])[0].toolCallId)!);
    const message = call && buildMessage(call, contextOf(each));
    if (message) {
      send({
        '@type': 'updateMessage', chatId, id: message.id, message, isFull: true,
      });
    }
    return;
  }
  const message = buildMessage(entry, contextOf(each));
  if (!message) return;
  send({
    '@type': 'newMessage', chatId, id: message.id, message,
  });
  // At once, not after Web A's 350 ms for an open chat: a typing draft is numbered after the chat's last message
  send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage: message });
}

/**
 * The answer streaming in `pi.live.generation` as Telegram's typing draft (a bot's streamed message), in tau's row:
 * the final entry's `newMessage` takes its place
 */
function updateDraft(each: Opened) {
  const chatId = buildChatId(each.replica.id);
  const live = each.replica.docs['pi.live'] as Record<string, any> | undefined;
  const generation = live?.generation;
  const message = generation?.message;
  const hasContent = message?.content?.some((part: any) => (part.type === 'text' && part.text)
    || (part.type === 'thinking' && part.thinking));
  if (!hasContent) {
    if (each.draftId && !generation) {
      send({ '@type': 'updateChatTypingDraftStopped', chatId, id: each.draftId });
      each.draftId = undefined;
    }
    return;
  }
  each.draftId = `${live?.run?.taskId ?? 0}-${generation.attempt ?? 0}`;
  send({
    '@type': 'updateChatTypingDraft',
    chatId,
    id: each.draftId,
    threadId: MAIN_THREAD_ID,
    richMessage: buildAssistantRichMessage(message),
    tau: { role: 'assistant', parts: buildAssistantParts(message, contextOf(each)) },
  });
}

function contextOf(each: Opened): MessageContext {
  return {
    results: each.results,
    runStartAt: (entryId) => {
      let startAt: number | undefined;
      for (const entry of each.replica.ordered()) {
        if (entry.id >= entryId) break;
        if (entry.kind === 'pi.user') startAt = (entry.model as any[])[0]?.timestamp;
      }
      return startAt;
    },
    subagentTask: (conversationId) => {
      const call = subagentCalls.get(conversationId);
      const parent = call && opened.get(call.parentId);
      const entry = call && parent?.replica.entries.get(parent.callEntries.get(call.callId)!);
      const toolCall = (entry?.model as any[] | undefined)?.[0]?.content.find((part: any) => part.id === call!.callId);
      return toolCall?.arguments?.message ?? toolCall?.arguments?.task ?? dialogs.dialogs.get(conversationId)?.title;
    },
    isBusy: (conversationId) => Boolean(dialogs.dialogs.get(conversationId)?.busy),
  };
}

/** A subagent started or stopped working: the card of the call that started it says so */
function refreshSubagentCard(conversationId: number) {
  const call = subagentCalls.get(conversationId);
  const parent = call && opened.get(call.parentId);
  if (!call || !parent?.isLoaded) return;
  const entry = parent.replica.entries.get(parent.callEntries.get(call.callId)!);
  const message = entry && buildMessage(entry, contextOf(parent));
  if (!message) return;
  send({
    '@type': 'updateMessage', chatId: message.chatId, id: message.id, message, isFull: true,
  });
}

/** Messages of an opened chat, newest first, as `messages.getHistory` pages them */
export async function fetchHistory(
  conversationId: number, offsetId: number | undefined, addOffset: number, limit: number,
) {
  const each = open(conversationId);
  await each.ready;
  const messages = each.replica.ordered()
    .reverse()
    .map((entry) => buildMessage(entry, contextOf(each)))
    .filter((message): message is ApiMessage => Boolean(message));
  let first = offsetId ? messages.findIndex((message) => message.id < offsetId) : 0;
  if (first < 0) first = messages.length;
  first = Math.max(0, first + addOffset);
  return { messages: messages.slice(first, first + limit), count: messages.length };
}

/** Telegram's typing dots for chats with a run going, their own or a subagent's at any depth */
function refreshTyping() {
  if (!wasConnected) return;
  window.clearTimeout(typingTimer);
  let isAnyBusy = false;
  for (const dialog of dialogs.dialogs.values()) {
    if (!isListed(dialog)) continue;
    const chatId = buildChatId(dialog.conversation.id);
    const isBusy = dialog.busy || hasBusySubagent(dialog.conversation.id);
    isAnyBusy ||= isBusy;
    send({
      '@type': 'updateChatTypingStatus',
      id: chatId,
      peerId: chatId,
      typingStatus: isBusy ? { type: 'typing', timestamp: Date.now() } : undefined,
    });
  }
  if (isAnyBusy) typingTimer = window.setTimeout(refreshTyping, TYPING_REFRESH_MS);
}

function hasBusySubagent(conversationId: number, depth = 0): boolean {
  if (depth > 8) return false;
  for (const dialog of dialogs.dialogs.values()) {
    if (dialog.conversation.owner?.conversationId !== conversationId) continue;
    if (dialog.busy || hasBusySubagent(dialog.conversation.id, depth + 1)) return true;
  }
  return false;
}

function send(update: object) {
  onUpdate(update as ApiUpdate);
}
