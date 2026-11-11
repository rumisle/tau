// The connections to tau's servers (this origin's first, and those added: docs/web.md "Several servers") and what
// Web A's state is built from: their chat lists by version and a replica per opened chat (tau-client), turned into
// `apiUpdate`s as GramJS's update handler sends them.
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
import type { ServerConfig } from './servers';
import { MAIN_THREAD_ID } from '../../api/types';

import { ALL_FOLDER_ID, ARCHIVED_FOLDER_ID } from '../../config';
import { selectCurrentMessageList } from '../../global/selectors';
import { isLocalMessageId } from '../../util/keys/messageKey';
import {
  probe, readToken, saveToken, serverOrigin, socketProtocols, socketUrlOf,
} from '../auth';
import { whenLinkTokenStored } from '../boot';
import { draftsOf } from '../db/drafts';
import { openOutboxState } from '../db/outbox';
import { deleteOutboxFile, readOutboxFile, saveOutboxFile } from '../db/outboxFiles';
import { isLooking, notifyAnswer } from '../notifications';
import { STRINGS } from '../strings';
import { AnswerWatch } from './answers';
import { keptUploadsOf, readUserContent } from './attachments';
import {
  buildAssistantParts, buildAssistantRichMessage, buildChat, buildChatId, buildDraftChat, buildDraftUser, buildMe,
  buildMessage, buildReadState, buildRows, buildSummaryMessage, buildThreadInfo, buildTitle, buildUser, DRAFT_CHAT_ID,
  entryIdOf,
  lastRowIdOf, messageIdOf,
} from './builders';
import { buildParagraph } from './markdown';
import { buildOutgoingRows, outgoingRowCount, prepareUploads } from './outgoing';
import { buildQueue, isInQueue } from './queue';
import { mappedSocket, readServers, slotOf, writeServers } from './servers';
import { countSocket } from './usage';

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
const WAIT_REFRESH_MS = 5000;
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
  // While the τ waits: its draft, and the timer that sends it again before Web A's draft expiry. The answer then
  // streams in the same draft: `streamsIn` maps its generation's draft ID to the τ's
  waitingDraftId?: string;
  streamsIn?: { id: string; draftId: string };
  waitTimer?: number;
  // When its run began (its first input's time) and the compaction now running, for the title's time
  runSince?: number;
  compactingSince?: number;
  // Generations answered so far, in the draft's ID: the next generation of a run streams as a draft of its own
  answered: number;
};

export type ServerStatus = 'connecting' | 'ready' | 'refused' | 'unreachable';

/** A server and what this app keeps of it: its connection, its chat list, its outbox */
type ServerLink = {
  slot: number;
  origin: string;
  token?: string;
  client?: TauClient;
  dialogs: DialogList;
  outbox: Outbox;
  status: ServerStatus;
  attempt: number;
  isRemoved?: boolean;
  // Its chat list's first sync after a connect: the baseline of answers (api/answers.ts)
  isSyncing?: boolean;
};

let onUpdate: (update: ApiUpdate) => void = () => undefined;
const links = new Map<number, ServerLink>();
const answers = new AnswerWatch();
// The first server, this origin's, was ready once: Web A has its state, and takes changes as updates
let wasConnected = false;
let typingTimer: number | undefined;
let authStatus: AuthStatus = 'connecting';
const authListeners = new Set<(status: AuthStatus) => void>();
const serverListeners = new Set<() => void>();

/** Every server's chat list as one, by global conversation IDs (src/tau/api/servers.ts) */
export const dialogs = {
  dialogs: {
    get: (id: number) => links.get(slotOf(id))?.dialogs.dialogs.get(id),
    values: () => [...links.values()].flatMap((link) => [...link.dialogs.dialogs.values()]),
  },
  /** Newest first: by the last entry's time, as entry IDs are each server's own */
  ordered: () => dialogs.dialogs.values()
    .sort((a, b) => (b.last?.timestamp ?? 0) - (a.last?.timestamp ?? 0) || (b.last?.id ?? 0) - (a.last?.id ?? 0)),
};
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
const changeListeners = new Set<(conversationId?: number) => void>();

export async function start(callback: (update: ApiUpdate) => void) {
  onUpdate = callback;
  await whenLinkTokenStored();
  const others = await readServers();
  await addLink({ slot: 0, origin: serverOrigin() });
  for (const config of others) await addLink(config);
  for (const config of others) void connect(links.get(config.slot)!);
  await connect(links.get(0)!);
}

/** A server's link: its token, its outbox as the last page left it, its chat list */
async function addLink(config: ServerConfig) {
  const { state, persist } = await openOutboxState(config.origin);
  // The bytes of what a reload left unsent, for its bubbles
  for (const upload of state.items.flatMap((item) => item.uploads ?? [])) {
    const blob = await readOutboxFile(upload.key);
    if (blob) blobUrls.set(upload.key, URL.createObjectURL(blob));
  }
  const link: ServerLink = {
    slot: config.slot,
    origin: config.origin,
    token: await readToken(config.origin),
    dialogs: new DialogList(),
    status: 'connecting',
    attempt: 0,
    outbox: undefined as unknown as Outbox,
  };
  link.outbox = new Outbox({
    state,
    persist,
    upload: (upload) => uploadFile(link, upload),
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
  link.dialogs.onChange((changed) => {
    for (const dialog of changed) applyDialog(dialog);
    for (const answer of answers.changed(changed, Boolean(link.isSyncing))) {
      notifyAnswer(answer, buildChatId(answer.conversationId));
    }
  });
  links.set(config.slot, link);
  return link;
}

function linkOf(conversationId: number) {
  return links.get(slotOf(conversationId));
}

/** The outbox of a conversation's server */
function outboxOf(conversationId: number) {
  return linkOf(conversationId)!.outbox;
}

/** A message on its way, on whichever server's outbox has it */
function findOutgoing(requestId: string) {
  for (const link of links.values()) {
    const item = link.outbox.item(requestId);
    if (item) return { outbox: link.outbox, item };
  }
  return undefined;
}

/** The connect screen's token: kept when the server takes it */
export async function submitToken(given: string) {
  const result = await probe(serverOrigin(), given);
  if (result !== 'ok') {
    setAuthStatus(result === 'token' ? 'wrongToken' : 'unreachable');
    return false;
  }
  const link = links.get(0)!;
  link.token = given;
  await saveToken(serverOrigin(), given);
  await connect(link);
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

async function connect(link: ServerLink) {
  if (link.isRemoved) return;
  const isFirst = link.slot === 0;
  const result = await probe(link.origin, link.token);
  if (result !== 'ok') {
    if (result === 'token') {
      setStatus(link, 'refused');
      if (isFirst) setAuthStatus(link.token ? 'wrongToken' : 'needsToken');
    } else {
      scheduleReconnect(link, 'unreachable');
    }
    return;
  }
  let client: TauClient;
  try {
    const socket = new WebSocket(socketUrlOf(link.origin), socketProtocols(link.token));
    countSocket(socket, link.origin);
    client = await TauClient.open(mappedSocket(socket, link.slot));
  } catch {
    scheduleReconnect(link, 'unreachable');
    return;
  }
  if (link.isRemoved) {
    void client.close();
    return;
  }
  link.client = client;
  link.attempt = 0;
  client.on((push) => {
    if (push.event === 'submission') link.outbox.apply(push.record as JsonObject);
  });
  void client.closed.then(() => {
    if (link.client === client) link.outbox.disconnected();
    for (const each of opened.values()) {
      if (slotOf(each.replica.id) === link.slot) each.isSynced = false;
    }
    link.client = undefined;
    if (link.isRemoved) return;
    if (isFirst) send({ '@type': 'updateConnectionState', connectionState: 'connectionStateConnecting' });
    scheduleReconnect(link, 'connecting');
  });
  link.isSyncing = true;
  try {
    await link.dialogs.sync(client);
  } finally {
    link.isSyncing = false;
  }
  reportPresence(link);
  // After the chat list's subscribe, which brings every conversation's submission pushes
  link.outbox.connected(client, String(client.hello?.serverId));
  // Back after a dropped socket: its open chats subscribe again from their newest entry
  for (const each of opened.values()) {
    if (slotOf(each.replica.id) === link.slot && each.isLoaded) void syncReplica(each);
  }
  setStatus(link, 'ready');
  if (isFirst) {
    if (!wasConnected) {
      wasConnected = true;
      send({ '@type': 'updateApiReady' });
      send({ '@type': 'updateAuthorizationState', authorizationState: 'authorizationStateReady' });
      send({ '@type': 'updateCurrentUser', currentUser: buildMe(), currentUserFullInfo: {} });
    }
    setAuthStatus('ready');
    // Web A syncs (`loadAllChats`, then `fetchChats`) once connected and authorized
    send({ '@type': 'updateConnectionState', connectionState: 'connectionStateReady' });
  } else if (wasConnected) {
    // Another server's chats, into the list Web A has already
    for (const dialog of link.dialogs.dialogs.values()) applyDialog(dialog);
  }
  refreshTyping();
}

/**
 * Whether the user looks at this page, to each server (`client.presence`, docs/notifications.md "Pushes"): it pushes
 * an answer to the phone only while no client is in the foreground
 */
function reportPresence(link: ServerLink) {
  link.client?.request('client.presence', { active: isLooking() }).catch(() => undefined);
}

let wasLooking: boolean | undefined;
function onLookChange() {
  const looking = isLooking();
  if (looking === wasLooking) return;
  wasLooking = looking;
  for (const link of links.values()) reportPresence(link);
}
for (const event of ['focus', 'blur']) window.addEventListener(event, onLookChange);
document.addEventListener('visibilitychange', onLookChange);

function scheduleReconnect(link: ServerLink, status: AuthStatus & ServerStatus) {
  setStatus(link, status);
  if (link.slot === 0 && !wasConnected) setAuthStatus(status);
  const delay = RECONNECT_MS[Math.min(link.attempt++, RECONNECT_MS.length - 1)];
  window.setTimeout(() => void connect(link), delay);
}

function setStatus(link: ServerLink, status: ServerStatus) {
  link.status = status;
  for (const listener of serverListeners) listener();
}

function applyDialog(dialog: Dialog) {
  const id = dialog.conversation.id;
  emitChange(id);
  refreshTyping();
  refreshPins();
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
function sendDialog(given: Dialog) {
  const id = given.conversation.id;
  // A rename shows at once and stands until the server's Dialog has it
  const renamed = titleOverrides.get(id);
  if (renamed !== undefined && given.title === renamed) titleOverrides.delete(id);
  const dialog = renamed !== undefined && given.title !== renamed ? { ...given, title: renamed } : given;
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
  const link = linkOf(replica.id)!;
  const { client, outbox } = link;
  if (!client) return;
  await replica.sync(client, { limit: PAGE });
  each.isSynced = true;
  const unsettled = new Set<number>();
  for (const record of replica.submissions.values()) {
    if (record.status === 'queued' || record.status === 'placed') unsettled.add(record.id as number);
    outbox.apply(record);
  }
  outbox.refreshSettled(replica.id, unsettled);
}

async function load(each: Opened) {
  const { replica } = each;
  const link = linkOf(replica.id)!;
  // A server not connected yet: its chats load once it is
  while (!link.client) await new Promise((resolve) => window.setTimeout(resolve, RECONNECT_MS[0]));
  await syncReplica(each);
  while (replica.hasOlder) await replica.loadOlder(link.client, PAGE);
  while (replica.holes.length > 0) await replica.fillHole(link.client, PAGE);
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
  if (users.length > 0) linkOf(each.replica.id)?.outbox.matchPlacements(each.replica.id, users);
  if (each.isLoaded) {
    for (const entry of fresh) emitEntry(each, entry);
  }
  if (fresh.some((entry) => entry.kind === 'pi.assistant')) endDraft(each);
  if (fresh.length && each.isLoaded) readOnScreen(each.replica.id, each.replica.maxId);
  updateDraft(each);
  updateTimes(each);
  emitChange(each.replica.id);
}

/** When its run and its compaction began, as the title counts them: told to the title when either changes */
function updateTimes(each: Opened) {
  const live = each.replica.docs['pi.live'] as Record<string, any> | undefined;
  const first = live?.run ? each.replica.entries.get(live.run.first) : undefined;
  const runSince = live?.run
    ? (first?.model as any[] | undefined)?.[0]?.timestamp ?? each.runSince ?? Date.now() : undefined;
  const compactingSince = compactionOf(each)?.since;
  if (runSince === each.runSince && compactingSince === each.compactingSince) return;
  each.runSince = runSince;
  each.compactingSince = compactingSince;
  refreshTyping();
}

const firstSeen = new Map<number, number>();

/**
 * The compaction running in a chat, from the server's records (`tau.compactions`, docs/compaction.md) or, without
 * them, from durable's live status, timed from when this page first saw it
 */
export function compactionOf(each: Opened): { taskId: number; since: number } | undefined {
  const records = (each.replica.docs['tau.compactions'] as { items?: any[] } | undefined)?.items;
  const running = records?.find((record) => record.state === 'running');
  if (running) return { taskId: running.taskId, since: running.startedAt };
  const live = each.replica.docs['pi.live'] as Record<string, any> | undefined;
  const status = live?.compactions?.[0];
  if (!status || records?.some((record) => record.taskId === status.taskId)) return undefined;
  if (!firstSeen.has(status.taskId)) firstSeen.set(status.taskId, Date.now());
  return { taskId: status.taskId, since: firstSeen.get(status.taskId)! };
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
  const outbox = linkOf(entry.conversationId)?.outbox;
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
  each.waitingDraftId = undefined;
  each.streamsIn = undefined;
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
  if (!hasContent && isAgentWaiting(live, each.replica)) {
    // The τ where the answer will be, in the draft the answer then streams in (iOS's ChatWaitingNode)
    each.waitingDraftId ??= `${live?.run?.taskId ?? 0}-waiting-${each.answered}`;
    each.draftId = each.waitingDraftId;
    send({
      '@type': 'updateChatTypingDraft',
      chatId,
      id: each.draftId,
      threadId: MAIN_THREAD_ID,
      richMessage: { blocks: [buildParagraph('…')] },
      tau: { role: 'assistant', parts: [{ type: 'waiting' }] },
    });
    keepWaiting(each);
    return;
  }
  if (!hasContent) {
    if (each.draftId && !generation) {
      send({ '@type': 'updateChatTypingDraftStopped', chatId, id: each.draftId });
      each.draftId = undefined;
      each.waitingDraftId = undefined;
    }
    return;
  }
  const id = `${live?.run?.taskId ?? 0}-${generation.attempt ?? 0}-${each.answered}`;
  if (each.waitingDraftId) {
    each.streamsIn = { id, draftId: each.waitingDraftId };
    each.waitingDraftId = undefined;
  }
  each.draftId = each.streamsIn?.id === id ? each.streamsIn.draftId : id;
  send({
    '@type': 'updateChatTypingDraft',
    chatId,
    id: each.draftId,
    threadId: MAIN_THREAD_ID,
    richMessage: buildAssistantRichMessage(message),
    tau: { role: 'assistant', parts: buildAssistantParts(message, contextOf(each)) },
  });
}

/**
 * The agent works and nothing shows it: no answer streams, no call runs (its card has a spinner), and the run's answer
 * is not in yet. The run is the server's, so the τ shows only once the server has the message.
 */
function isAgentWaiting(live: Record<string, any> | undefined, replica: ConversationReplica) {
  // A compaction says it works itself
  if (!live?.run || live.compactions?.length) return false;
  // The answer is in: what the run still does after it (a title, a report) is not an answer to wait for
  const last = replica.entries.get(replica.maxId);
  if (last?.kind === 'pi.assistant' && (last.model as any[])?.[0]?.stopReason !== 'toolUse') return false;
  const tools: { status?: string }[] = live.tools ?? [];
  return !tools.some((tool) => tool.status !== 'done');
}

/** Web A drops a typing draft nothing updated for ten seconds: a long wait sends the τ again */
function keepWaiting(each: Opened) {
  window.clearTimeout(each.waitTimer);
  each.waitTimer = window.setTimeout(() => {
    each.waitTimer = undefined;
    if (each.draftId && opened.get(each.replica.id) === each) updateDraft(each);
  }, WAIT_REFRESH_MS);
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
    const working = workingSubagents(dialog.conversation.id);
    const each = opened.get(dialog.conversation.id);
    const compactingSince = dialog.busy ? undefined : each?.compactingSince;
    const isBusy = dialog.busy || working.length > 0 || compactingSince !== undefined;
    isAnyBusy ||= isBusy;
    send({
      '@type': 'updateChatTypingStatus',
      id: chatId,
      peerId: chatId,
      // `tauRun`: its own run, which Stop ends (src/tau/selectors.ts); `tauText` what the title and the list say,
      // `tauSince` since when, which the title counts
      typingStatus: isBusy ? {
        type: 'typing',
        timestamp: Date.now(),
        tauRun: dialog.busy || undefined,
        tauText: compactingSince !== undefined && !working.length
          ? STRINGS.CompactingStatus : activityOf(dialog, working),
        tauSince: dialog.busy ? each?.runSince : compactingSince,
      } : undefined,
    });
  }
  if (isAnyBusy) typingTimer = window.setTimeout(refreshTyping, TYPING_REFRESH_MS);
}

/** The names of a conversation's subagents that work, at any depth (a background subagent is titled "name: task") */
function workingSubagents(conversationId: number, depth = 0): string[] {
  if (depth > 8) return [];
  return dialogs.dialogs.values()
    .filter((dialog) => dialog.conversation.owner?.conversationId === conversationId)
    .flatMap((dialog) => [
      ...(dialog.busy ? [(dialog.title ?? '').split(':')[0] || STRINGS.Subagent] : []),
      ...workingSubagents(dialog.conversation.id, depth + 1),
    ]);
}

/** What a chat's agent does, as iOS's title says it: working; reader working; 2 subagents working */
export function activityOf(dialog: Dialog, working: string[]) {
  if (dialog.busy) return STRINGS.Working;
  if (working.length === 1) return `${working[0]} ${STRINGS.Working}`;
  return working.length ? `${working.length} ${STRINGS.SubagentsWorking}` : undefined;
}

// MARK: Sending

/** The composer's Send: a message to the conversation, steering a run that works (docs/sending.md) */
export async function sendText(chatId: string, text: string, attachments: ApiAttachment[] = []) {
  const uploads = attachments.length ? await keepUploads(attachments) : undefined;
  if (isDraftChat(chatId)) {
    sendToDraft(chatId, text, uploads);
    return;
  }
  const conversationId = Number(chatId);
  const how = nextSend.get(chatId);
  nextSend.delete(chatId);
  if (how === 'stopAndSend') {
    // After the abort in the conversation's order: the run is over, so it goes to the chat, not the queue
    interrupt(conversationId);
    outboxOf(conversationId).enqueue({
      text, conversationId, mode: 'steer', showsInQueue: false, uploads,
    });
    return;
  }
  outboxOf(conversationId).enqueue({
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
async function uploadFile(link: ServerLink, upload: Upload) {
  const blob = await readOutboxFile(upload.key);
  if (!blob) throw new UploadError(400, `${upload.name} is missing`);
  const response = await fetch(`${link.origin}/files?name=${encodeURIComponent(upload.name)}`, {
    method: 'POST', headers: authHeaders(link.slot), body: blob,
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
    if (local.chatId === chatId && local.localIds.includes(localId)) return findOutgoing(requestId)?.item;
  }
  return undefined;
}

/**
 * Delete in a message's menu: a refused one, or one still on its way, which is withdrawn (it never reaches the model,
 * or the withdraw says it already did)
 */
export function deleteOutgoing(requestId: string) {
  const found = findOutgoing(requestId);
  if (!found) return;
  const { outbox, item } = found;
  if (item.state.type === 'failed' || !item.wasSent) outbox.discard(requestId);
  else outbox.withdraw(requestId);
}

/** Resend a refused message: a new one with its text and files, in its place */
export function resendOutgoing(requestId: string) {
  const found = findOutgoing(requestId);
  if (found?.item.state.type !== 'failed') return;
  const { outbox, item } = found;
  outbox.enqueue({
    text: item.text,
    conversationId: item.conversationId,
    createRequestId: item.conversationId === undefined ? item.createRequestId : undefined,
    mode: 'steer',
    showsInQueue: Boolean(item.conversationId !== undefined && dialogs.dialogs.get(item.conversationId)?.busy),
    uploads: item.uploads?.map((upload) => ({ ...upload, serverId: undefined })),
  });
  outbox.discard(requestId);
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
  const outbox = outboxOf(conversationId);
  for (const item of outbox.itemsOf(conversationId)) {
    if (isInQueue(item) && !own.includes(item.requestId)) own.push(item.requestId);
  }
  const others = queue.filter((queued) => !queued.outgoingId && queued.text);
  void outbox.interrupt(conversationId, { restoring: own, sendNow }).then(() => {
    for (const queued of others) restoreToField(conversationId, queued.text);
  }).catch(() => undefined);
}

// MARK: The queue

/** The messages waiting for the agent in a conversation, in the panel's order */
export function queueOf(conversationId: number): QueuedMessage[] {
  const outbox = linkOf(conversationId)?.outbox;
  if (!outbox) return [];
  const each = opened.get(conversationId);
  const inbox = each?.isSynced ? ((each.replica.docs['pi.inbox'] as JsonObject | undefined)?.items ?? []) : [];
  return buildQueue(inbox as JsonObject[], outbox.itemsOf(conversationId), Boolean(each?.isSynced));
}

/** Another device's queued message, taken back by its submission ID in the conversation's order */
function withdrawOther(conversationId: number, queued: QueuedMessage) {
  if (queued.submissionId === undefined) return Promise.resolve(false);
  const params = { submissionId: queued.submissionId };
  return outboxOf(conversationId).request<{ result: string }>('submission.abort', { conversationId }, params)
    .then(({ result }) => result === 'aborted', () => false);
}

/** Delete, or Edit (`restore`: its text comes back to the field). False when the model has it already. */
export function withdrawQueued(conversationId: number, queued: QueuedMessage, restore: boolean) {
  if (queued.outgoingId) return outboxOf(conversationId).withdraw(queued.outgoingId, { restore });
  void withdrawOther(conversationId, queued).then((withdrawn) => {
    if (withdrawn && restore) restoreToField(conversationId, queued.text);
  });
  return true;
}

/** Send as Follow-up, or as Steer: withdrawn, then queued anew */
export function moveQueued(conversationId: number, queued: QueuedMessage, mode: SendMode) {
  if (queued.outgoingId) {
    outboxOf(conversationId).move(queued.outgoingId, mode);
    return;
  }
  void withdrawOther(conversationId, queued).then((withdrawn) => {
    if (withdrawn) {
      outboxOf(conversationId).enqueue({
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
    outboxOf(conversationId).enqueue({
      text: queued.text, conversationId, mode: 'steer', showsInQueue: false,
    });
  });
}

/** Bubbles for the messages of a conversation on their way, oldest first, numbered after its entries */
function outgoingOf(conversationId: number) {
  return bubblesOf(buildChatId(conversationId), outboxOf(conversationId).itemsOf(conversationId));
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
  // An edit's fork shows the original up to the fork: its bubbles come after that
  const lastEntry = draftChats.get(chatId)?.forkAt
    ?? opened.get(conversationId)?.replica.maxId ?? dialogs.dialogs.get(conversationId)?.last?.id;
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
  refreshBubbles(buildChatId(conversationId), outboxOf(conversationId).itemsOf(conversationId));
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

// MARK: Draft chats

/**
 * A chat not created yet (docs/sending.md "Edits and drafts"): a chat of its own, not listed, whose messages wait in
 * the outbox for the conversation's create. New Chat is one, one at a time as iOS keeps one: what a reload left unsent
 * is still in it. An edit is another: a fork before the edited message, showing the original up to there.
 */
type DraftChat = {
  chatId: string;
  title: string;
  // The server it is created on
  slot: number;
  requestId?: string;
  // The agent it shows (an AgentPatch), which its create asks for
  agent?: JsonObject;
  forkOf?: number;
  forkAt?: number;
  // Named by the user, not after its first answer
  isTitleManual?: boolean;
  // Its history was asked for: until then its bubbles wait for it, since Web A asks for no history once it has a message
  isLoaded?: boolean;
};

const draftChats = new Map<string, DraftChat>();
let lastForkChat = 0;

function newChatDraft() {
  let draft = draftChats.get(DRAFT_CHAT_ID);
  if (!draft) {
    // What a reload left unsent, on whichever server
    const [link, left] = [...links.values()]
      .map((each) => [each, each.outbox.state.creates.find((create) => create.forkOf === undefined)] as const)
      .find(([, create]) => create) ?? [undefined, undefined];
    draft = {
      chatId: DRAFT_CHAT_ID,
      title: STRINGS.NewChat,
      slot: link?.slot ?? 0,
      requestId: left?.requestId,
      agent: left?.agent,
    };
    draftChats.set(DRAFT_CHAT_ID, draft);
  }
  return draft;
}

function outboxOfDraft(draft: DraftChat) {
  return links.get(draft.slot)!.outbox;
}

/** Web A's chat for a draft, with what was written in it, then opened */
function showDraftChat(draft: DraftChat, isEdit = false) {
  send({ '@type': 'updateUser', id: draft.chatId, user: buildDraftUser(draft.chatId, draft.title) });
  send({ '@type': 'updateChat', id: draft.chatId, chat: buildDraftChat(draft.chatId, draft.title) });
  // Its thread, where Web A keeps the history it loaded (an empty one too: without it the chat shows its spinner)
  // and a draft written in it
  send({
    '@type': 'updateThreadInfo',
    threadInfo: { isCommentsInfo: false, chatId: draft.chatId, threadId: MAIN_THREAD_ID },
  });
  // A fork starts read up to the fork, as the server's does: Web A opens a chat at its last read message
  if (draft.forkAt !== undefined) {
    send({
      '@type': 'updateThreadReadState',
      chatId: draft.chatId,
      threadId: MAIN_THREAD_ID,
      readState: {
        unreadCount: 0,
        lastReadInboxMessageId: lastRowIdOf(draft.forkAt),
        lastReadOutboxMessageId: lastRowIdOf(draft.forkAt),
      },
    });
  }
  // What was written in it before, kept as any chat's draft. In place before the chat opens: the composer takes a draft
  // that comes later for the user's own typing, and keeps the field as it is
  const written = draftsOf([draft.chatId])[draft.chatId];
  if (written) {
    send({
      '@type': 'draftMessage', chatId: draft.chatId, threadId: MAIN_THREAD_ID, draft: written,
    });
  }
  // After the updates, which Web A takes one per microtask; an edit's draft in the chat's place, as iOS's (42ea67a)
  window.setTimeout(() => getActions().openChat({ id: draft.chatId, shouldReplaceLast: isEdit }));
}

/** New Chat, on a server (the one used last, or this origin's); a draft that has messages waiting keeps its own */
export function openNewChat(slot = lastSlot) {
  const draft = newChatDraft();
  if (!draft.requestId || !outboxOfDraft(draft).create(draft.requestId)) {
    if (links.has(slot)) draft.slot = slot;
    draft.title = newChatTitle(draft.slot);
  }
  draft.requestId ??= crypto.randomUUID();
  showDraftChat(draft);
}

let lastSlot = 0;

/** New Chat names its server when there are several: New Chat on mac.local */
function newChatTitle(slot: number) {
  return links.size > 1 ? `${STRINGS.NewChat} on ${hostOf(links.get(slot)!.origin)}` : STRINGS.NewChat;
}

export function hostOf(origin: string) {
  return new URL(origin).host;
}

export function isDraftChat(chatId: string) {
  return chatId === DRAFT_CHAT_ID || draftChats.has(chatId);
}

/** A draft's messages, newest first, as a history page: a fork's start with the original's rows up to the fork */
export function draftHistory(chatId: string, offsetId: number | undefined, addOffset: number, limit: number) {
  const draft = chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId);
  if (!draft?.requestId) return { messages: [], count: 0 };
  draft.isLoaded = true;
  const messages = bubblesOf(chatId, outboxOfDraft(draft).itemsOfCreate(draft.requestId)).reverse();
  const parent = draft.forkOf === undefined ? undefined : opened.get(draft.forkOf);
  if (parent && draft.forkAt !== undefined) {
    const inherited = parent.replica.ordered().filter((entry) => entry.id <= draft.forkAt!)
      .flatMap((entry) => buildRows(entry, contextOf(parent)))
      .map((message) => ({ ...message, chatId }));
    messages.push(...inherited.reverse());
  }
  listDraft(draft);
  // As fetchHistory pages
  let first = offsetId ? messages.findIndex((message) => message.id < offsetId) : 0;
  if (first < 0) first = messages.length;
  first = Math.max(0, first + addOffset);
  return { messages: messages.slice(first, first + limit), count: messages.length };
}

function sendToDraft(chatId: string, text: string, uploads?: Upload[]) {
  const draft = chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId)!;
  draft.requestId ??= crypto.randomUUID();
  const outbox = outboxOfDraft(draft);
  if (draft.chatId === DRAFT_CHAT_ID) lastSlot = draft.slot;
  // New Chat: named after its first answer unless renamed; the server's default model, as iOS's New Chat without a pick
  outbox.enqueueCreate({
    requestId: draft.requestId,
    ...(draft.isTitleManual ? { title: draft.title, autoTitle: false } : { autoTitle: true }),
    agent: draft.agent,
  });
  outbox.enqueue({
    text, createRequestId: draft.requestId, mode: 'steer', uploads,
  });
}

/**
 * An edit of the user's message (docs/sending.md "Edits and drafts"): a fork before it, with the new text and the
 * original's files as its first message, through the outbox as a create; with the agent the chat shows, since a fork
 * starts with the one the original had back then. The fork's draft opens in the chat's place until the fork exists.
 * Editing the first message is a new chat with the same agent.
 */
export function editMessage(chatId: string, messageId: number, text: string, agent: JsonObject) {
  const conversationId = Number(chatId);
  const parent = opened.get(conversationId);
  const entryId = entryIdOf(messageId);
  const entry = parent?.replica.entries.get(entryId);
  if (!parent || entry?.kind !== 'pi.user') return;
  const uploads = keptUploadsOf((entry.model as any[] | undefined)?.[0]?.content);
  const at = Math.max(...parent.replica.ordered().map((each) => each.id).filter((id) => id < entryId));
  const dialog = dialogs.dialogs.get(conversationId);
  const title = dialog ? buildTitle(dialog) : STRINGS.NewChat;
  let draft: DraftChat;
  if (!Number.isFinite(at)) {
    draft = newChatDraft();
    // On the chat's server, unless New Chat has messages waiting on another
    if (!draft.requestId || !outboxOfDraft(draft).create(draft.requestId)) draft.slot = slotOf(conversationId);
    draft.requestId ??= crypto.randomUUID();
    draft.agent = { ...draft.agent, ...agent };
  } else {
    draft = {
      chatId: String(Number(DRAFT_CHAT_ID) - ++lastForkChat),
      title,
      slot: slotOf(conversationId),
      requestId: crypto.randomUUID(),
      agent,
      forkOf: conversationId,
      forkAt: at,
    };
    draftChats.set(draft.chatId, draft);
    outboxOfDraft(draft).enqueueCreate({
      requestId: draft.requestId!, title, agent, forkOf: conversationId, forkAt: at,
    });
  }
  // Web A's chat first: the message's bubble is an update for it
  showDraftChat(draft, true);
  sendToDraft(draft.chatId, text, uploads);
}

function refreshDraft() {
  for (const draft of [newChatDraft(), ...draftChats.values()]) {
    if (draft.requestId && (draft.isLoaded || draft.forkOf === undefined)) {
      refreshBubbles(draft.chatId, outboxOfDraft(draft).itemsOfCreate(draft.requestId));
    }
    listDraft(draft);
  }
}

/**
 * A draft with messages waiting for its create is in the chat list, at the top with its newest message and the clock,
 * so the chat open is the one highlighted there, as any; it leaves the list when it becomes its conversation, or when
 * nothing waits in it any more
 */
function listDraft(draft: DraftChat) {
  const { chatId } = draft;
  const [requestId, local] = [...shown.entries()].filter(([, each]) => each.chatId === chatId).at(-1) ?? [];
  const item = requestId ? outboxOfDraft(draft).item(requestId) : undefined;
  const isWaiting = Boolean(item && local && draft.requestId);
  if (isWaiting && !isInWebAList(chatId)) {
    send({ '@type': 'updateChat', id: chatId, chat: { ...buildDraftChat(chatId, draft.title), isListed: true } });
    send({ '@type': 'updateChatListType', id: chatId, folderId: ALL_FOLDER_ID });
  }
  if (isWaiting) {
    const lastMessage = buildOutgoingRows(item!, chatId, local!.localIds, blobUrls).at(-1)!;
    send({ '@type': 'updateChatLastMessage', id: chatId, lastMessage });
  } else if (isInWebAList(chatId)) {
    send({ '@type': 'updateChatLeave', id: chatId });
  }
}

/** The draft is a conversation now: its messages show there, and the chat opens in the draft's place */
function onCreated(create: PendingCreate, conversationId: number) {
  const draft = [...draftChats.values()].find((each) => each.requestId === create.requestId);
  if (!draft) return;
  if (draft.chatId === DRAFT_CHAT_ID) {
    draft.requestId = undefined;
    draft.agent = undefined;
  } else {
    draftChats.delete(draft.chatId);
  }
  const { chatId } = draft;
  if (isInWebAList(chatId)) send({ '@type': 'updateChatLeave', id: chatId });
  const wasOpen = Object.values(getGlobal().byTabId)
    .some(({ id: tabId }) => selectCurrentMessageList(getGlobal(), tabId)?.chatId === chatId);
  const gone = [...shown].filter(([, local]) => local.chatId === chatId);
  for (const [requestId] of gone) shown.delete(requestId);
  if (gone.length > 0) {
    send({ '@type': 'deleteMessages', ids: gone.flatMap(([, local]) => local.localIds), chatId });
  }
  // In the draft's place: Back does not lead to a draft that is gone
  if (wasOpen) getActions().openChat({ id: buildChatId(conversationId), shouldReplaceLast: true });
}

/** A message reached the model; when its entry already shows on its own, the bubble that stood for it goes */
function onPlaced(item: OutgoingMessage, entryId: number) {
  if (item.conversationId !== undefined) sentHere.add(`${buildChatId(item.conversationId)}:${entryId}`);
  const each = item.conversationId === undefined ? undefined : opened.get(item.conversationId);
  if (!each?.seen.has(entryId)) return;
  const local = shown.get(item.requestId);
  shown.delete(item.requestId);
  outboxOf(item.conversationId!).settle(item.requestId);
  if (local) send({ '@type': 'deleteMessages', ids: local.localIds, chatId: local.chatId });
}

// The entries this page sent, by chat: a message sent here goes to the top of the view as it lands (src/tau/liveTail.ts)
const sentHere = new Set<string>();

/** A message the user sent from this page: still on its way, or in the transcript from this page's outbox */
export function isSentHere(chatId: string, messageId: number) {
  return isLocalMessageId(messageId) || sentHere.has(`${chatId}:${entryIdOf(messageId)}`);
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
  const client = isDraftChat(chatId) ? undefined : linkOf(Number(chatId))?.client;
  if (!client) return;
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

// MARK: Pins

// The pinned chats Web A was told of last, by list
const sentPins = { active: '', archived: '' };

/**
 * Pinned chats on top of their list, the latest pin first (docs/protocol.md conversation.mark `pinned`: the time it
 * was pinned, so across servers too); Web A orders a list's pinned chats by these IDs
 */
function refreshPins() {
  if (!wasConnected) return;
  for (const isArchived of [false, true]) {
    const ids = dialogs.dialogs.values()
      .filter((dialog) => dialog.pinned && isListed(dialog) && Boolean(dialog.archived) === isArchived)
      .sort((a, b) => b.pinned! - a.pinned!)
      .map((dialog) => buildChatId(dialog.conversation.id));
    const key = isArchived ? 'archived' : 'active';
    if (ids.join() === sentPins[key]) continue;
    sentPins[key] = ids.join();
    send({ '@type': 'updatePinnedChatIds', ids, folderId: isArchived ? ARCHIVED_FOLDER_ID : ALL_FOLDER_ID });
  }
}

/** Pin or Unpin from the chat list's menu: shown at once, kept on the server */
export function pin(chatId: string, isPinned: boolean) {
  send({ '@type': 'updateChatPinned', id: chatId, isPinned });
  mark(chatId, { pinned: isPinned ? Date.now() : false });
}

// MARK: Rename

const titleOverrides = new Map<number, string>();
const MAX_TITLE = 64;

/** A title as the server keeps it: whitespace collapsed, at most 64 characters; empty for none */
export function normalizeTitle(title: string) {
  return title.replace(/\s+/g, ' ').trim().slice(0, MAX_TITLE);
}

/**
 * Rename (docs/protocol.md conversation.rename): shown at once, sent in the conversation's order through the outbox,
 * and believed until the server's Dialog agrees; a draft's create takes it, or a rename follows the create
 */
export function rename(chatId: string, given: string) {
  const title = normalizeTitle(given);
  if (!title) return;
  const draft = isDraftChat(chatId) ? (chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId)) : undefined;
  if (draft) {
    draft.title = title;
    send({ '@type': 'updateUser', id: chatId, user: buildDraftUser(chatId, title) });
    send({ '@type': 'updateChat', id: chatId, chat: buildDraftChat(chatId, title) });
    draft.isTitleManual = true;
    // Not sent yet: its create takes it, when it goes; on its way: a rename follows it
    const { requestId } = draft;
    const outbox = outboxOfDraft(draft);
    if (!requestId || !outbox.create(requestId)) return;
    if (!outbox.updateCreate(requestId, { title, autoTitle: false })) {
      void outbox.request('conversation.rename', { createRequestId: requestId }, { title }).catch(() => {});
    }
    return;
  }
  const conversationId = Number(chatId);
  const dialog = dialogs.dialogs.get(conversationId);
  if (!dialog) return;
  titleOverrides.set(conversationId, title);
  sendDialog(dialog);
  outboxOf(conversationId).request('conversation.rename', { conversationId }, { title }).catch(() => {
    // Refused: the server's title again
    if (titleOverrides.get(conversationId) !== title) return;
    titleOverrides.delete(conversationId);
    const current = dialogs.dialogs.get(conversationId);
    if (current) sendDialog(current);
  });
}

/** Hide: the chat leaves every list on every device; kept, as durable deletes no conversation */
export function hide(chatId: string) {
  mark(chatId, { hidden: true });
}

/** Mark as Unread or as Read, Archive: on every device, from the next Dialog on */
export function mark(
  chatId: string, marks: { unread?: boolean; archived?: boolean; hidden?: boolean; pinned?: number | false },
) {
  if (isDraftChat(chatId)) return;
  const conversationId = Number(chatId);
  void outboxOf(conversationId).request('conversation.mark', { conversationId }, marks).catch(() => undefined);
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

/** A server's connection, while it has one: a conversation's server is its ID's slot (`slotOf`) */
export function clientOf(slot: number) {
  return links.get(slot)?.client;
}

/** A server's address */
export function originOf(slot: number) {
  return links.get(slot)?.origin ?? serverOrigin();
}

/** The headers a request beside a server's socket carries (`/files`) */
export function authHeaders(slot = 0): Record<string, string> {
  const token = links.get(slot)?.token;
  return token === undefined ? {} : { authorization: `Bearer ${token}` };
}

/** A conversation's server's outbox; a draft chat's server's */
export function getOutbox(chatId: string) {
  if (isDraftChat(chatId)) return outboxOfDraft(chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId)!);
  return outboxOf(Number(chatId));
}

/** The server a chat is on: a draft's, or its conversation's */
export function slotOfChat(chatId: string) {
  if (isDraftChat(chatId)) return (chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId))?.slot ?? 0;
  return slotOf(Number(chatId));
}

// MARK: Servers (src/tau/components/ServersModal.tsx)

export type ServerInfo = { slot: number; origin: string; status: ServerStatus };

export function servers(): ServerInfo[] {
  return [...links.values()].filter((link) => !link.isRemoved).map((link) => ({
    slot: link.slot,
    origin: link.origin,
    status: link.status,
  }));
}

export function onServersChange(listener: () => void) {
  serverListeners.add(listener);
  return () => serverListeners.delete(listener);
}

/** Adds a server by its address and token, once it takes the token: the reason when it does not */
export async function addServer(origin: string, token: string): Promise<'ok' | 'token' | 'unreachable' | 'known'> {
  if ([...links.values()].some((link) => link.origin === origin && !link.isRemoved)) return 'known';
  const result = await probe(origin, token);
  if (result !== 'ok') return result;
  await saveToken(origin, token);
  const slot = Math.max(...links.keys()) + 1;
  const configs = (await readServers()).filter((config) => config.origin !== origin);
  await writeServers([...configs, { slot, origin }]);
  const link = await addLink({ slot, origin });
  for (const listener of serverListeners) listener();
  void connect(link);
  return 'ok';
}

/** Removes a server added: its chats leave the list; its token and what it has on its way stay for if it comes back */
export async function removeServer(slot: number) {
  const link = links.get(slot);
  if (!link || slot === 0) return;
  link.isRemoved = true;
  await writeServers((await readServers()).filter((config) => config.slot !== slot));
  for (const dialog of link.dialogs.dialogs.values()) {
    const chatId = buildChatId(dialog.conversation.id);
    if (isInWebAList(chatId)) send({ '@type': 'updateChatLeave', id: chatId });
  }
  link.dialogs.detach();
  links.delete(slot);
  void link.client?.close();
  if (lastSlot === slot) lastSlot = 0;
  for (const listener of serverListeners) listener();
}

/** How long a server takes to answer, in milliseconds: its `/auth`, as the probe asks it */
export async function pingServer(slot: number) {
  const link = links.get(slot);
  if (!link) return undefined;
  const started = performance.now();
  const result = await probe(link.origin, link.token);
  return result === 'unreachable' ? undefined : Math.round(performance.now() - started);
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

/** A draft chat's create and the agent it shows */
export function draftState(chatId: string) {
  const draft = chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId);
  return { requestId: draft?.requestId, agent: draft?.agent };
}

export function setDraftAgent(chatId: string, agent: JsonObject) {
  const draft = chatId === DRAFT_CHAT_ID ? newChatDraft() : draftChats.get(chatId);
  if (!draft) return;
  draft.agent = { ...draft.agent, ...agent };
  emitChange(undefined);
}

function send(update: object) {
  onUpdate(update as ApiUpdate);
}
