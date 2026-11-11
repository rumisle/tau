// The connection to this origin's tau server and what Web A's state is built from: the chat list by version and a
// replica per opened chat (tau-client), turned into `apiUpdate`s as GramJS's update handler sends them.
import { TauClient } from 'tau-client/connection';
import { DialogList } from 'tau-client/dialogs';
import type { OutgoingMessage, PendingCreate, SendMode, Upload } from 'tau-client/outbox';
import { Outbox, UploadError } from 'tau-client/outbox';
import type { Dialog, Entry, JsonObject } from 'tau-client/protocol';
import { ConversationReplica } from 'tau-client/replica';
import { getActions, getGlobal } from '../../global';

import type { ApiAttachment, ApiMessage, ApiUpdate } from '../../api/types';
import type { MessageContext } from './builders';
import type { QueuedMessage } from './queue';
import { MAIN_THREAD_ID } from '../../api/types';

import { ALL_FOLDER_ID, ARCHIVED_FOLDER_ID } from '../../config';
import { selectCurrentMessageList } from '../../global/selectors';
import { isLocalMessageId } from '../../util/keys/messageKey';
import {
  probe, readToken, saveToken, serverOrigin, socketProtocols, socketUrl,
} from '../auth';
import { whenLinkTokenStored } from '../boot';
import { draftsOf } from '../db/drafts';
import { openOutboxState } from '../db/outbox';
import { deleteOutboxFile, readOutboxFile, saveOutboxFile } from '../db/outboxFiles';
import { readUserContent } from './attachments';
import {
  buildAssistantParts, buildAssistantRichMessage, buildChat, buildChatId, buildDraftChat, buildDraftUser, buildMe,
  buildMessage, buildReadState, buildRows, buildSummaryMessage, buildThreadInfo, buildUser, DRAFT_CHAT_ID, lastRowIdOf,
  messageIdOf,
} from './builders';
import { buildOutgoingRows, outgoingRowCount, prepareUploads } from './outgoing';
import { buildQueue, isInQueue } from './queue';

// The PoC reads a transcript whole, in pages of the server's largest
const PAGE = 500;
// Web A drops a typing status a few seconds after it came, as Telegram's clients send theirs again every few seconds
const TYPING_REFRESH_MS = 4000;
const RECONNECT_MS = [500, 1000, 2000, 5000];
// Web A's local message IDs: a fraction above the chat's last message
const LOCAL_ID_STEP = 1e-6;
// Messages an opened chat refreshes in Web A's state, newest first: as many as a chat shows
const REFRESHED_ON_OPEN = 50;
// When drafts an answer replaced are looked for again in Web A's state
const DRAFT_SWEEP_MS = 300;
// A chat on screen tells the server what was read at most this often (docs/protocol.md conversation.read)
const READ_INTERVAL_MS = 2000;

export type AuthStatus = 'connecting' | 'needsToken' | 'wrongToken' | 'unreachable' | 'ready';

type Opened = {
  replica: ConversationReplica;
  ready: Promise<void>;
  isLoaded: boolean;
  // Its docs are current: subscribed on this connection
  isSynced: boolean;
  // Entries already turned into messages or folded into one (a tool result into its call)
  seen: Set<number>;
  // Tool results by call ID, and the entry each call is in
  results: Map<string, any>;
  callEntries: Map<string, number>;
  draftId?: string;
  // Generations answered so far, in the draft's ID: the next generation of a run streams as a draft of its own
  answered: number;
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
// Reads sent for chats on screen in the last two seconds, with the newest entry to read once they pass
const reading = new Map<number, { at: number }>();
// Entries a chat not open has shown as its Dialog's summary, by conversation: replaced or removed once it opens
const summarized = new Map<number, Set<number>>();
// The call that started each subagent, by the subagent's conversation
const subagentCalls = new Map<number, { parentId: number; callId: string }>();
// Messages on their way as Web A has them: their local message and the state it shows, by request ID
const shown = new Map<string, { chatId: string; localIds: number[]; state: string }>();
// Object URLs of the bytes of the outbox's photos and files, by upload key, while a message has them
const blobUrls = new Map<string, string>();
let outbox: Outbox | undefined;
// New Chat's create, until it is sent, and the agent picked in it (an AgentPatch)
let draftRequestId: string | undefined;
let draftAgent: JsonObject | undefined;
const changeListeners = new Set<(conversationId?: number) => void>();

dialogs.onChange((changed) => {
  for (const dialog of changed) applyDialog(dialog);
});

export async function start(callback: (update: ApiUpdate) => void) {
  onUpdate = callback;
  await whenLinkTokenStored();
  token = await readToken(serverOrigin());
  const { state, persist } = await openOutboxState(serverOrigin());
  // The bytes of what a reload left unsent, for its bubbles
  for (const upload of state.items.flatMap((item) => item.uploads ?? [])) {
    const blob = await readOutboxFile(upload.key);
    if (blob) blobUrls.set(upload.key, URL.createObjectURL(blob));
  }
  outbox = new Outbox({
    state,
    persist,
    upload: uploadFile,
    events: {
      removed: (_item, keys) => dropUploads(keys),
      changed: (conversationId) => {
        if (conversationId !== undefined) refreshOutgoing(conversationId);
        else refreshDraft();
        emitChange(conversationId);
      },
      created: onCreated,
      placed: onPlaced,
      restored: restoreToField,
    },
  });
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
  const current = client;
  current.on((push) => {
    if (push.event === 'submission') outbox!.apply(push.record as JsonObject);
  });
  void client.closed.then(() => {
    if (client === current) outbox!.disconnected();
    for (const each of opened.values()) each.isSynced = false;
    client = undefined;
    send({ '@type': 'updateConnectionState', connectionState: 'connectionStateConnecting' });
    scheduleReconnect('connecting');
  });
  await dialogs.sync(client);
  // After the chat list's subscribe, which brings every conversation's submission pushes
  outbox!.connected(client, String(client.hello?.serverId));
  if (!wasConnected) {
    wasConnected = true;
    send({ '@type': 'updateApiReady' });
    send({ '@type': 'updateAuthorizationState', authorizationState: 'authorizationStateReady' });
    send({ '@type': 'updateCurrentUser', currentUser: buildMe(), currentUserFullInfo: {} });
  } else {
    // Back after a dropped socket: open chats subscribe again from their newest entry
    for (const each of opened.values()) void syncReplica(each);
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
  emitChange(id);
  refreshTyping();
  if (dialog.conversation.owner) refreshSubagentCard(id);
  if (!wasConnected) return;
  if (!isListed(dialog)) {
    // Hidden (here or on another device): out of Web A's lists
    if (dialog.hidden && isInWebAList(buildChatId(id))) send({ '@type': 'updateChatLeave', id: buildChatId(id) });
    return;
  }
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
  // Archived or back: Web A moves a chat between its lists on this, not on the chat's folder (read before it changes)
  const known = getGlobal().chats.byId[chatId];
  // Archived or back, or shown again after Hide: into the list it belongs in
  const isMoved = known !== undefined && ((known.folderId === ARCHIVED_FOLDER_ID) !== Boolean(dialog.archived)
    || !isInWebAList(chatId));
  send({ '@type': 'updateUser', id: chatId, user: buildUser(dialog) });
  send({ '@type': 'updateThreadInfo', threadInfo: buildThreadInfo(dialog) });
  send({
    '@type': 'updateChat', id: chatId, chat: buildChat(dialog), readState: readStateOf(dialog),
  });
  // Web A takes a chat's read state from this, not from `updateChat`: unread counts, and the checks of what the
  // agent has read (everything in the transcript)
  send({
    '@type': 'updateThreadReadState', chatId, threadId: MAIN_THREAD_ID, readState: readStateOf(dialog),
  });
  if (isMoved) {
    send({
      '@type': 'updateChatListType', id: chatId, folderId: dialog.archived ? ARCHIVED_FOLDER_ID : ALL_FOLDER_ID,
    });
  }
  if (!opened.has(id) && dialog.last) {
    send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage: summaryOf(dialog)! });
  }
}

/**
 * A chat's last message for the chat list: its entry's message once the chat is open, else the Dialog's summary,
 * which the entry's message replaces when it opens (Web A keeps a message it has over the history's)
 */
export function chatListMessage(dialog: Dialog): ApiMessage | undefined {
  const each = opened.get(dialog.conversation.id);
  if (!each) return summaryOf(dialog);
  // Opening: its last message comes once it is loaded
  if (!each.isLoaded) return undefined;
  for (const entry of each.replica.ordered().reverse()) {
    const message = buildRows(entry, contextOf(each)).at(-1);
    if (message) return message;
  }
  return undefined;
}

/** The chat list's last messages, as updates: Web A stores them under messages it may have already, not over them */
export function sendChatListMessages(messages: ApiMessage[]) {
  for (const message of messages) send({ '@type': 'updateChatLastMessage', id: message.chatId, lastMessage: message });
}

function summaryOf(dialog: Dialog) {
  const message = buildSummaryMessage(dialog);
  if (!message) return undefined;
  const id = dialog.conversation.id;
  if (!summarized.has(id)) summarized.set(id, new Set());
  summarized.get(id)!.add(dialog.last!.id);
  return message;
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
    replica,
    ready: Promise.resolve(),
    isLoaded: false,
    isSynced: false,
    seen: new Set(),
    results: new Map(),
    callEntries: new Map(),
    answered: 0,
  };
  const current = each;
  opened.set(conversationId, each);
  replica.onChange(() => applyReplica(current));
  each.ready = load(current);
  return each;
}

/** Subscribes a replica on the current connection; the outbox learns what became of the messages it has */
async function syncReplica(each: Opened) {
  const { replica } = each;
  await replica.sync(client!, { limit: PAGE });
  each.isSynced = true;
  const unsettled = new Set<number>();
  for (const record of replica.submissions.values()) {
    if (record.status === 'queued' || record.status === 'placed') unsettled.add(record.id as number);
    outbox!.apply(record);
  }
  outbox!.refreshSettled(replica.id, unsettled);
}

async function load(each: Opened) {
  const { replica } = each;
  await syncReplica(each);
  while (replica.hasOlder) await replica.loadOlder(client!, PAGE);
  while (replica.holes.length > 0) await replica.fillHole(client!, PAGE);
  each.isLoaded = true;
  // Web A keeps a message it has over the history's: what stood for entries as the Dialog's summary, and what its own
  // cache kept from an earlier visit (a tool card before its result), is replaced by the entry's message, or removed
  // when the entry has none (a tool's result, which shows in its call's card). The newest page covers what the cache
  // keeps.
  const chatId = buildChatId(replica.id);
  const stale = new Set(summarized.get(replica.id));
  const lastId = dialogs.dialogs.get(replica.id)?.last?.id;
  if (lastId !== undefined) stale.add(lastId);
  for (const entry of replica.ordered().slice(-REFRESHED_ON_OPEN)) stale.add(entry.id);
  summarized.delete(replica.id);
  const removed: number[] = [];
  let last: ApiMessage | undefined;
  for (const id of [...stale].sort((a, b) => a - b)) {
    const entry = replica.entries.get(id);
    const rows = entry ? buildRows(entry, contextOf(each)) : [];
    for (const message of rows) {
      last = message;
      send({
        '@type': 'updateMessage', chatId, id: message.id, message, isFull: true,
      });
    }
    if (rows.length === 0) removed.push(messageIdOf(id));
  }
  if (removed.length > 0) send({ '@type': 'deleteMessages', ids: removed, chatId });
  if (last) send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage: last });
}

function applyReplica(each: Opened) {
  const fresh = each.replica.ordered().filter((entry) => !each.seen.has(entry.id));
  for (const entry of fresh) index(each, entry);
  // Before they show: a message on its way becomes its entry in one step, not a duplicate first
  const users = fresh.filter((entry) => entry.kind === 'pi.user').map((entry) => {
    const content = (entry.model as any[])[0]?.content;
    const { text, photos, documents } = readUserContent(content, entry.conversationId, entry.id, 0);
    return { id: entry.id, text, files: photos.length + documents.length };
  });
  if (users.length > 0) outbox?.matchPlacements(each.replica.id, users);
  if (each.isLoaded) {
    for (const entry of fresh) emitEntry(each, entry);
  }
  if (fresh.some((entry) => entry.kind === 'pi.assistant')) endDraft(each);
  if (fresh.length && each.isLoaded) readOnScreen(each.replica.id, each.replica.maxId);
  updateDraft(each);
  emitChange(each.replica.id);
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
    for (const message of call ? buildRows(call, contextOf(each)) : []) {
      send({
        '@type': 'updateMessage', chatId, id: message.id, message, isFull: true,
      });
    }
    return;
  }
  const rows = buildRows(entry, contextOf(each));
  if (!rows.length) return;
  const sent = entry.kind === 'pi.user' ? outbox?.placedAs(entry.conversationId, entry.id) : undefined;
  const local = sent && shown.get(sent.requestId);
  if (sent) {
    shown.delete(sent.requestId);
    outbox!.settle(sent.requestId);
  }
  const localIds = local?.localIds ?? [];
  rows.forEach((message, row) => {
    if (row < localIds.length) {
      // The bubble that was on its way is the entry now: Telegram's send succeeded (its handler keeps what the local
      // message had, the clock too, unless the entry's message says otherwise)
      send({
        '@type': 'updateMessageSendSucceeded',
        chatId,
        localId: localIds[row],
        message: { ...message, sendingState: undefined },
      });
    } else {
      send({
        '@type': 'newMessage', chatId, id: message.id, message,
      });
    }
  });
  if (localIds.length > rows.length) send({ '@type': 'deleteMessages', ids: localIds.slice(rows.length), chatId });
  const lastRow = rows.at(-1)!;
  // At once, not after Web A's 350 ms for an open chat: a typing draft is numbered after the chat's last message
  send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage: lastRow });
}

/**
 * A generation's entry came: its draft is gone. Web A's `newMessage` for the entry removes the thread's drafts at once
 * (a Stopped after it would delete the draft again, with an animation, a second after the entry is drawn: the answer
 * twice meanwhile). Without the entry's message (a chat still loading), Stopped removes it. Whatever came between,
 * no draft outlives its answer: a moment later any still in Web A's state goes.
 */
function endDraft(each: Opened) {
  each.answered += 1;
  if (!each.draftId) return;
  const chatId = buildChatId(each.replica.id);
  if (!each.isLoaded) send({ '@type': 'updateChatTypingDraftStopped', chatId, id: each.draftId });
  each.draftId = undefined;
  window.setTimeout(() => {
    if (each.draftId) return;
    const byId = getGlobal().messages.byChatId[chatId]?.byId ?? {};
    const stale = Object.values(byId)
      .filter((message) => message.isTypingDraft && isLocalMessageId(message.id))
      .map((message) => message.id);
    if (stale.length) send({ '@type': 'deleteMessages', ids: stale, chatId });
  }, DRAFT_SWEEP_MS);
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
  each.draftId = `${live?.run?.taskId ?? 0}-${generation.attempt ?? 0}-${each.answered}`;
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

/** Messages of an opened chat, newest first, as `messages.getHistory` pages them; then those on their way */
export async function fetchHistory(
  conversationId: number, offsetId: number | undefined, addOffset: number, limit: number,
) {
  const each = open(conversationId);
  await each.ready;
  const messages = each.replica.ordered()
    .flatMap((entry) => buildRows(entry, contextOf(each)))
    .reverse();
  messages.unshift(...outgoingOf(conversationId).reverse());
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
      // `tauRun`: its own run, which Stop ends (src/tau/selectors.ts)
      typingStatus: isBusy ? { type: 'typing', timestamp: Date.now(), tauRun: dialog.busy || undefined } : undefined,
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

// MARK: Sending

/** The composer's Send: a message to the conversation, steering a run that works (docs/sending.md) */
export async function sendText(chatId: string, text: string, attachments: ApiAttachment[] = []) {
  const uploads = attachments.length ? await keepUploads(attachments) : undefined;
  if (isDraftChat(chatId)) {
    sendToDraft(text, uploads);
    return;
  }
  const conversationId = Number(chatId);
  const how = nextSend.get(chatId);
  nextSend.delete(chatId);
  if (how === 'stopAndSend') {
    // After the abort in the conversation's order: the run is over, so it goes to the chat, not the queue
    interrupt(conversationId);
    outbox!.enqueue({
      text, conversationId, mode: 'steer', showsInQueue: false, uploads,
    });
    return;
  }
  outbox!.enqueue({
    text,
    conversationId,
    mode: how ?? 'steer',
    showsInQueue: Boolean(dialogs.dialogs.get(conversationId)?.busy),
    uploads,
  });
}

// How the next Send of a chat goes, from Send's menu: Web A's send takes no mode, so it waits here a moment
const nextSend = new Map<string, SendMode | 'stopAndSend'>();
const NEXT_SEND_MS = 1000;

/** Send's menu while the agent works: the field's message as a follow-up, or after stopping the run */
export function sendNextAs(chatId: string, how: SendMode | 'stopAndSend') {
  nextSend.set(chatId, how);
  window.setTimeout(() => {
    if (nextSend.get(chatId) === how) nextSend.delete(chatId);
  }, NEXT_SEND_MS);
}

/** The composer's files, kept beside the outbox before the message is: a reload or a crash still sends them */
async function keepUploads(attachments: ApiAttachment[]) {
  const prepared = await prepareUploads(attachments, crypto.randomUUID());
  for (const { upload, blob } of prepared) {
    await saveOutboxFile(upload.key, blob);
    blobUrls.set(upload.key, URL.createObjectURL(blob));
  }
  return prepared.map(({ upload }) => upload);
}

/** `POST /files` for the outbox: the file's ID, or an UploadError when the server refuses it */
async function uploadFile(upload: Upload) {
  const blob = await readOutboxFile(upload.key);
  if (!blob) throw new UploadError(400, `${upload.name} is missing`);
  const response = await fetch(`${serverOrigin()}/files?name=${encodeURIComponent(upload.name)}`, {
    method: 'POST', headers: authHeaders(), body: blob,
  });
  if (!response.ok) {
    const error = await response.json().catch(() => undefined);
    throw new UploadError(response.status, error?.error?.message ?? `${upload.name} was refused`);
  }
  return ((await response.json()) as { id: string }).id;
}

/** What a message that left the outbox kept for its files goes */
function dropUploads(keys: string[]) {
  for (const key of keys) {
    void deleteOutboxFile(key);
    const url = blobUrls.get(key);
    if (url) URL.revokeObjectURL(url);
    blobUrls.delete(key);
  }
}

/** The message on its way a local bubble stands for, if any: what its menu offers (Resend, Delete) depends on it */
export function outgoingForMessage(chatId: string, localId: number) {
  for (const [requestId, local] of shown) {
    if (local.chatId === chatId && local.localIds.includes(localId)) return outbox!.item(requestId);
  }
  return undefined;
}

/**
 * Delete in a message's menu: a refused one, or one still on its way, which is withdrawn (it never reaches the model,
 * or the withdraw says it already did)
 */
export function deleteOutgoing(requestId: string) {
  const item = outbox!.item(requestId);
  if (!item) return;
  if (item.state.type === 'failed' || !item.wasSent) outbox!.discard(requestId);
  else outbox!.withdraw(requestId);
}

/** Resend a refused message: a new one with its text and files, in its place */
export function resendOutgoing(requestId: string) {
  const item = outbox!.item(requestId);
  if (item?.state.type !== 'failed') return;
  outbox!.enqueue({
    text: item.text,
    conversationId: item.conversationId,
    createRequestId: item.conversationId === undefined ? item.createRequestId : undefined,
    mode: 'steer',
    showsInQueue: Boolean(item.conversationId !== undefined && dialogs.dialogs.get(item.conversationId)?.busy),
    uploads: item.uploads?.map((upload) => ({ ...upload, serverId: undefined })),
  });
  outbox!.discard(requestId);
}

/** Stop: the run ends, and the messages waiting for it come back to the field (docs/sending.md "Stop") */
export function stop(conversationId: number) {
  interrupt(conversationId);
}

/**
 * Stops the run: this device's queued messages are withdrawn in order and come back to the field; the abort withdraws
 * the other devices' ones, which come back too. `sendNow`: one of this device's goes to the chat instead.
 */
function interrupt(conversationId: number, sendNow?: string) {
  const queue = queueOf(conversationId);
  const own = queue.flatMap((queued) => (queued.outgoingId ? [queued.outgoingId] : []));
  // Pending ones the panel shows, and those it does not yet (a reload before the inbox came)
  for (const item of outbox!.itemsOf(conversationId)) {
    if (isInQueue(item) && !own.includes(item.requestId)) own.push(item.requestId);
  }
  const others = queue.filter((queued) => !queued.outgoingId && queued.text);
  void outbox!.interrupt(conversationId, { restoring: own, sendNow }).then(() => {
    for (const queued of others) restoreToField(conversationId, queued.text);
  }).catch(() => undefined);
}

// MARK: The queue

/** The messages waiting for the agent in a conversation, in the panel's order */
export function queueOf(conversationId: number): QueuedMessage[] {
  if (!outbox) return [];
  const each = opened.get(conversationId);
  const inbox = each?.isSynced ? ((each.replica.docs['pi.inbox'] as JsonObject | undefined)?.items ?? []) : [];
  return buildQueue(inbox as JsonObject[], outbox.itemsOf(conversationId), Boolean(each?.isSynced));
}

/** Another device's queued message, taken back by its submission ID in the conversation's order */
function withdrawOther(conversationId: number, queued: QueuedMessage) {
  if (queued.submissionId === undefined) return Promise.resolve(false);
  const params = { submissionId: queued.submissionId };
  return outbox!.request<{ result: string }>('submission.abort', { conversationId }, params)
    .then(({ result }) => result === 'aborted', () => false);
}

/** Delete, or Edit (`restore`: its text comes back to the field). False when the model has it already. */
export function withdrawQueued(conversationId: number, queued: QueuedMessage, restore: boolean) {
  if (queued.outgoingId) return outbox!.withdraw(queued.outgoingId, { restore });
  void withdrawOther(conversationId, queued).then((withdrawn) => {
    if (withdrawn && restore) restoreToField(conversationId, queued.text);
  });
  return true;
}

/** Send as Follow-up, or as Steer: withdrawn, then queued anew */
export function moveQueued(conversationId: number, queued: QueuedMessage, mode: SendMode) {
  if (queued.outgoingId) {
    outbox!.move(queued.outgoingId, mode);
    return;
  }
  void withdrawOther(conversationId, queued).then((withdrawn) => {
    if (withdrawn) {
      outbox!.enqueue({
        text: queued.text, conversationId, mode, showsInQueue: true,
      });
    }
  });
}

/** Send Now: the run stops and this message goes to the chat; the others come back to the field */
export function sendQueuedNow(conversationId: number, queued: QueuedMessage) {
  if (queued.outgoingId) {
    interrupt(conversationId, queued.outgoingId);
    return;
  }
  void withdrawOther(conversationId, queued).then((withdrawn) => {
    if (!withdrawn) return;
    interrupt(conversationId);
    outbox!.enqueue({
      text: queued.text, conversationId, mode: 'steer', showsInQueue: false,
    });
  });
}

/** Bubbles for the messages of a conversation on their way, oldest first, numbered after its entries */
function outgoingOf(conversationId: number) {
  return bubblesOf(buildChatId(conversationId), outbox!.itemsOf(conversationId));
}

// A message on its way is a bubble unless it is in the transcript, withdrawn, or waiting in the queue's panel
function isBubble(item: OutgoingMessage) {
  return item.state.type !== 'placed' && item.state.type !== 'withdrawing' && !isInQueue(item);
}

function bubblesOf(chatId: string, items: OutgoingMessage[]) {
  return items
    .filter(isBubble)
    .flatMap((item) => {
      const local = shown.get(item.requestId) ?? showAs(item, chatId);
      local.state = stateOf(item);
      return buildOutgoingRows(item, chatId, local.localIds, blobUrls);
    });
}

function showAs(item: OutgoingMessage, chatId: string) {
  const conversationId = Number(chatId);
  const lastEntry = opened.get(conversationId)?.replica.maxId ?? dialogs.dialogs.get(conversationId)?.last?.id;
  let last = lastEntry === undefined ? 0 : lastRowIdOf(lastEntry);
  for (const each of shown.values()) if (each.chatId === chatId) last = Math.max(last, ...each.localIds);
  const localIds = Array.from({ length: outgoingRowCount(item) }, (_, row) => last + (row + 1) * LOCAL_ID_STEP);
  const local = { chatId, localIds, state: '' };
  shown.set(item.requestId, local);
  return local;
}

function stateOf(item: OutgoingMessage) {
  return item.state.type === 'failed' ? 'failed' : item.state.type === 'queued' ? 'queued' : 'pending';
}

/** What Web A shows of a conversation's messages on their way follows the outbox: new ones, states, the withdrawn */
function refreshOutgoing(conversationId: number) {
  if (!opened.get(conversationId)?.isLoaded) return;
  refreshBubbles(buildChatId(conversationId), outbox!.itemsOf(conversationId));
}

function refreshBubbles(chatId: string, list: OutgoingMessage[]) {
  const items = new Map(list.map((item) => [item.requestId, item]));
  const gone: number[] = [];
  for (const [requestId, local] of shown) {
    if (local.chatId !== chatId) continue;
    const item = items.get(requestId);
    if (!item || (item.state.type !== 'placed' && !isBubble(item))) {
      shown.delete(requestId);
      gone.push(...local.localIds);
    }
  }
  if (gone.length > 0) send({ '@type': 'deleteMessages', ids: gone, chatId });
  for (const item of items.values()) {
    if (!isBubble(item)) continue;
    const local = shown.get(item.requestId);
    if (!local) {
      const fresh = showAs(item, chatId);
      fresh.state = stateOf(item);
      for (const message of buildOutgoingRows(item, chatId, fresh.localIds, blobUrls)) {
        send({
          '@type': 'newMessage', chatId, id: message.id, message,
        });
      }
      continue;
    }
    const state = stateOf(item);
    if (state === local.state) continue;
    local.state = state;
    for (const message of buildOutgoingRows(item, chatId, local.localIds, blobUrls)) {
      if (item.state.type === 'failed') {
        send({
          '@type': 'updateMessageSendFailed', chatId, localId: message.id, error: item.state.message,
        });
      } else {
        send({
          '@type': 'updateMessage', chatId, id: message.id, message,
        });
      }
    }
  }
}

// MARK: New Chat

/**
 * New Chat is a draft until its first message (docs/sending.md "Edits and drafts"): a chat of its own, not listed,
 * whose messages wait in the outbox for the conversation's create. One at a time, as iOS keeps one: what a reload left
 * unsent is still in it.
 */
export function openNewChat() {
  draftRequestId ??= outbox!.state.creates.find((create) => create.forkOf === undefined)?.requestId
    ?? crypto.randomUUID();
  send({ '@type': 'updateUser', id: DRAFT_CHAT_ID, user: buildDraftUser() });
  send({ '@type': 'updateChat', id: DRAFT_CHAT_ID, chat: buildDraftChat() });
  // What was written in it before, kept as any chat's draft. In place before the chat opens: the composer takes a draft
  // that comes later for the user's own typing, and keeps the field as it is
  // (Web A keeps a draft in its thread, which the thread's info makes)
  const draft = draftsOf([DRAFT_CHAT_ID])[DRAFT_CHAT_ID];
  if (draft) {
    send({
      '@type': 'updateThreadInfo',
      threadInfo: { isCommentsInfo: false, chatId: DRAFT_CHAT_ID, threadId: MAIN_THREAD_ID },
    });
    send({
      '@type': 'draftMessage', chatId: DRAFT_CHAT_ID, threadId: MAIN_THREAD_ID, draft,
    });
  }
  // After the updates, which Web A takes one per microtask
  window.setTimeout(() => getActions().openChat({ id: DRAFT_CHAT_ID }));
}

export function isDraftChat(chatId: string) {
  return chatId === DRAFT_CHAT_ID;
}

/** The draft's messages, newest first, as a history page */
export function draftHistory() {
  if (!draftRequestId) return [];
  return bubblesOf(DRAFT_CHAT_ID, outbox!.itemsOfCreate(draftRequestId)).reverse();
}

function sendToDraft(text: string, uploads?: Upload[]) {
  draftRequestId ??= crypto.randomUUID();
  // Named after its first answer; the server's default model, as iOS's New Chat without a pick
  outbox!.enqueueCreate({ requestId: draftRequestId, autoTitle: true, agent: draftAgent });
  outbox!.enqueue({
    text, createRequestId: draftRequestId, mode: 'steer', uploads,
  });
}

function refreshDraft() {
  if (draftRequestId) refreshBubbles(DRAFT_CHAT_ID, outbox!.itemsOfCreate(draftRequestId));
}

/** The draft is a conversation now: its messages show there, and the chat opens in the draft's place */
function onCreated(create: PendingCreate, conversationId: number) {
  if (create.requestId !== draftRequestId) return;
  draftRequestId = undefined;
  draftAgent = undefined;
  const wasOpen = Object.values(getGlobal().byTabId)
    .some(({ id: tabId }) => selectCurrentMessageList(getGlobal(), tabId)?.chatId === DRAFT_CHAT_ID);
  const gone = [...shown].filter(([, local]) => local.chatId === DRAFT_CHAT_ID);
  for (const [requestId] of gone) shown.delete(requestId);
  if (gone.length > 0) {
    send({ '@type': 'deleteMessages', ids: gone.flatMap(([, local]) => local.localIds), chatId: DRAFT_CHAT_ID });
  }
  if (wasOpen) getActions().openChat({ id: buildChatId(conversationId) });
}

/** A message reached the model; when its entry already shows on its own, the bubble that stood for it goes */
function onPlaced(item: OutgoingMessage, entryId: number) {
  const each = item.conversationId === undefined ? undefined : opened.get(item.conversationId);
  if (!each?.seen.has(entryId)) return;
  const local = shown.get(item.requestId);
  shown.delete(item.requestId);
  outbox!.settle(item.requestId);
  if (local) send({ '@type': 'deleteMessages', ids: local.localIds, chatId: local.chatId });
}

// Texts withdrawn back to the field, gathered per chat: Stop returns all its queued messages at once
const restoring = new Map<number, string[]>();

function restoreToField(conversationId: number, text: string) {
  if (!restoring.has(conversationId)) {
    restoring.set(conversationId, []);
    window.setTimeout(() => {
      const texts = restoring.get(conversationId)!;
      restoring.delete(conversationId);
      send({
        '@type': 'draftMessage',
        chatId: buildChatId(conversationId),
        threadId: MAIN_THREAD_ID,
        draft: { text: { text: texts.join('\n\n') }, isLocal: true },
      });
    });
  }
  restoring.get(conversationId)!.push(text);
}

// MARK: Read state and the chat list's marks

/** The user has seen the chat up to this entry; the server moves `read` forward only */
export function markRead(chatId: string, entryId: number) {
  if (isDraftChat(chatId) || !client) return;
  void client.request('conversation.read', { conversationId: Number(chatId), at: entryId }).catch(() => undefined);
}

/** Whether the chat is open in a tab the user sees: what arrives in it is read as it comes */
function isOnScreen(conversationId: number) {
  if (document.visibilityState !== 'visible') return false;
  const global = getGlobal();
  const chatId = buildChatId(conversationId);
  return Object.values(global.byTabId)
    .some(({ id: tabId }) => selectCurrentMessageList(global, tabId)?.chatId === chatId);
}

/**
 * A chat on screen reads what arrives, as iOS does (docs/protocol.md conversation.read): the newest entry, at most
 * every two seconds; meanwhile its Dialogs show it read, so its row never shows a badge for what is on screen
 */
function readOnScreen(conversationId: number, newest: number | undefined) {
  if (!newest || !isOnScreen(conversationId)) return;
  if ((dialogs.dialogs.get(conversationId)?.read ?? 0) >= newest) return;
  const pending = reading.get(conversationId);
  if (pending) {
    pending.at = Math.max(pending.at, newest);
    return;
  }
  const state = { at: newest };
  reading.set(conversationId, state);
  markRead(buildChatId(conversationId), newest);
  window.setTimeout(() => {
    reading.delete(conversationId);
    if (state.at > newest) markRead(buildChatId(conversationId), state.at);
  }, READ_INTERVAL_MS);
}

// Back on screen: what came meanwhile is read now
document.addEventListener('visibilitychange', () => {
  for (const each of opened.values()) if (each.isLoaded) readOnScreen(each.replica.id, each.replica.maxId);
});

function readStateOf(dialog: Dialog) {
  const readState = buildReadState(dialog);
  if (!dialog.last || !isOnScreen(dialog.conversation.id)) return readState;
  // Shown read, so it is read: the server hears it too
  readOnScreen(dialog.conversation.id, dialog.last.id);
  return { ...readState, unreadCount: 0, lastReadInboxMessageId: lastRowIdOf(dialog.last.id) };
}

function isInWebAList(chatId: string) {
  const { listIds } = getGlobal().chats;
  return Boolean(listIds.active?.includes(chatId) || listIds.archived?.includes(chatId));
}

/** Hide: the chat leaves every list on every device; kept, as durable deletes no conversation */
export function hide(chatId: string) {
  mark(chatId, { hidden: true });
}

/** Mark as Unread or as Read, Archive: on every device, from the next Dialog on */
export function mark(chatId: string, marks: { unread?: boolean; archived?: boolean; hidden?: boolean }) {
  if (isDraftChat(chatId)) return;
  void outbox!.request('conversation.mark', { conversationId: Number(chatId) }, marks).catch(() => undefined);
}

// MARK: For tau's own UI (agent.ts, the chat menu)

/** A conversation's Dialog or replica changed; undefined for New Chat's draft */
export function onConversationChange(listener: (conversationId?: number) => void) {
  changeListeners.add(listener);
  return () => changeListeners.delete(listener);
}

function emitChange(conversationId?: number) {
  for (const listener of changeListeners) listener(conversationId);
}

export function currentClient() {
  return client;
}

/** The headers a request beside the socket carries (`/files`) */
export function authHeaders(): Record<string, string> {
  return token === undefined ? {} : { authorization: `Bearer ${token}` };
}

export function getOutbox() {
  return outbox!;
}

/** A conversation's entries while it is open, and its context's head */
export function entriesOf(conversationId: number) {
  const replica = opened.get(conversationId)?.replica;
  return { entries: replica?.ordered() ?? [], head: replica?.head };
}

/** A conversation's docs while it is open (`pi.agent`, `pi.usage`, ...) */
export function docsOf(conversationId: number) {
  return opened.get(conversationId)?.replica.docs;
}

export function draftState() {
  return { requestId: draftRequestId, agent: draftAgent };
}

export function setDraftAgent(agent: JsonObject) {
  draftAgent = { ...draftAgent, ...agent };
  emitChange(undefined);
}

function send(update: object) {
  onUpdate(update as ApiUpdate);
}
