// The `callApi` methods tau answers. Every other method resolves to `undefined`, as a failed GramJS request does, and
// the UI copes (docs/web.md "What the proof of concept showed").
import type {
  ApiAttachment, ApiChat, ApiDraft, ApiMediaFormat, ApiMessage, ApiMessageEntity, ApiPeer,
} from '../../api/types';

import { ALL_FOLDER_ID, ARCHIVED_FOLDER_ID } from '../../config';
import { draftsOf, writeDraft } from '../db/drafts';
import { agentPatchOf } from './agent';
import {
  buildChat, buildChatId, buildReadState, buildThreadInfo, buildUser, entryIdOf,
} from './builders';
import { downloadMedia } from './media';
import { toMarkdown } from './outgoing';
import {
  chatListMessage, dialogs, draftHistory, editMessage, fetchHistory, isDraftChat, isListed, mark, markRead,
  pin, rename, requestDialog, searchConversation, searchConversations, searchMessage, sendChatListMessages, sendText,
  stop,
} from './session';

// Telegram's seven peer colors, which its server sends with `help.getPeerColors`; without them avatars are black
const PEER_COLORS = ['#CC5049', '#D67722', '#955CDB', '#40A920', '#309EBA', '#368AD1', '#C7508B'];

// A page of the chat list's message search, as Telegram's (docs/search.md "In the app")
const SEARCH_PAGE = 20;

export const methods: Record<string, (...args: any[]) => unknown> = {
  /** No contacts: an empty list, which Web A's search results wait for */
  fetchContactList() {
    return { users: [], userStatusesById: {} };
  },

  /** The chat list's search, its chats: those whose title has the query, at once, before the servers' messages */
  searchChats({ query }: { query: string }) {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const found = dialogs.ordered().filter((dialog) => {
      const title = (dialog.title ?? '').toLowerCase();
      return isListed(dialog) && words.every((word) => title.includes(word));
    });
    return { accountResultIds: found.map((dialog) => buildChatId(dialog.conversation.id)), globalResultIds: [] };
  },

  /**
   * The chat list's search, its messages: the servers' conversations best first, each by its best part, a page at a
   * time (the page's offset in `offsetRate`, as Telegram's pages by rate)
   */
  async searchMessagesGlobal({ query, offsetRate = 0, type }: { query: string; offsetRate?: number; type?: string }) {
    if (!query.trim() || (type && type !== 'text')) return { messages: [], topics: [], totalCount: 0 };
    const { results, total, hasMore } = await searchConversations(query, offsetRate, SEARCH_PAGE);
    const messages = results.flatMap(({ conversationId, hits }) => {
      const hit = hits.find((each) => each.entryId !== undefined);
      return hit ? [searchMessage(conversationId, hit)] : [];
    });
    return {
      messages,
      topics: [],
      totalCount: total,
      nextOffsetRate: hasMore ? offsetRate + SEARCH_PAGE : undefined,
    };
  },

  /** A chat's own search: its matching messages, newest first, which Up and Down step through */
  async searchMessagesInChat({ peer, query }: { peer: ApiPeer; query?: string }) {
    if (!query?.trim() || isDraftChat(peer.id)) return { messages: [], topics: [], totalCount: 0 };
    const conversationId = Number(peer.id);
    // One per entry: an answer's text and its reasoning are parts of one message
    const hits = (await searchConversation(conversationId, query))
      .filter((hit, index, all) => all.findIndex((each) => each.entryId === hit.entryId) === index);
    const messages = hits.map((hit) => searchMessage(conversationId, hit));
    return { messages, topics: [], totalCount: messages.length };
  },

  fetchChats({ archived }: { archived?: boolean }) {
    const listed = dialogs.ordered()
      .filter((dialog) => isListed(dialog) && Boolean(dialog.archived) === Boolean(archived));
    // The Dialogs' summaries, but for chats open already, which may have opened first (Web A opens the chat it showed
    // last at once)
    const messages = listed.map(chatListMessage).filter((message) => message !== undefined);
    // Not in the result: Web A's `loadAllChats` puts a result's messages over those it has, a while later, which would
    // undo what an opened chat put in their place
    sendChatListMessages(messages);
    const pinned = listed.filter((dialog) => dialog.pinned).sort((a, b) => b.pinned! - a.pinned!);
    const chatIds = listed.map((dialog) => buildChatId(dialog.conversation.id));
    return {
      chatIds,
      chats: listed.map(buildChat),
      users: listed.map(buildUser),
      userStatusesById: {},
      draftsById: draftsOf(chatIds),
      orderedPinnedIds: pinned.map((dialog) => buildChatId(dialog.conversation.id)),
      totalChatCount: listed.length,
      messages: [],
      notifyExceptionById: {},
      lastMessageByChatId: Object.fromEntries(messages.map((message) => [message.chatId, message.id])),
      isFullyLoaded: true,
      threadReadStatesById: Object.fromEntries(listed.map((dialog) => [
        buildChatId(dialog.conversation.id), buildReadState(dialog),
      ])),
      threadInfos: listed.map(buildThreadInfo),
    };
  },

  async fetchMessages({
    chat, offsetId, addOffset, limit,
  }: { chat: ApiChat; offsetId?: number; addOffset?: number; limit: number }) {
    if (isDraftChat(chat.id)) {
      const { messages, count } = draftHistory(chat.id, offsetId, addOffset ?? 0, limit);
      return {
        messages, users: [], chats: [], count, topics: [],
      };
    }
    const { messages, count } = await fetchHistory(Number(chat.id), offsetId, addOffset ?? 0, limit);
    return {
      messages, users: [], chats: [], count, topics: [],
    };
  },

  sendMessage({
    chat, text, entities, attachments, attachment,
  }: {
    chat?: ApiChat;
    text?: string;
    entities?: ApiMessageEntity[];
    attachments?: ApiAttachment[];
    attachment?: ApiAttachment;
  }) {
    // One request with all the message's files (Web A's action sends them so for tau)
    const files = attachments ?? (attachment ? [attachment] : []);
    if (!chat || (!text && !files.length)) return undefined;
    // Web A clears the draft on its own side only, as Telegram's server clears it on a send
    writeDraft(chat.id, undefined);
    return sendText(chat.id, text ? toMarkdown(text, entities) : '', files);
  },

  // An edit of the user's message: a fork before it (docs/sending.md "Edits and drafts")
  editMessage({
    chat, message, text, entities,
  }: { chat: ApiChat; message: ApiMessage; text?: string; entities?: ApiMessageEntity[] }) {
    if (!text) return;
    editMessage(chat.id, message.id, toMarkdown(text, entities), agentPatchOf(chat.id));
  },

  // Rename, through Web A's `updateChat` action (src/tau/components/RenameModal.tsx)
  updateChatTitle(chat: ApiChat, title: string) {
    rename(chat.id, title);
  },

  saveDraft({ chat, draft }: { chat: ApiChat; draft?: ApiDraft }) {
    writeDraft(chat.id, draft);
    return true;
  },

  sendMessageAction({ peer, action }: { peer: ApiPeer; action: { type: string } }) {
    // The composer's Stop, which Web A has for a bot's streamed answer and tau for the whole run (src/tau/selectors.ts)
    if (action.type === 'stopDraft') stop(Number(peer.id));
  },

  // The chat list's and the chat's read state (docs/protocol.md conversation.read, conversation.mark); Web A shows each
  // change at once and the Dialog that comes back confirms it
  markMessageListRead({ chat, maxId }: { chat: ApiChat; maxId?: number }) {
    if (maxId) markRead(chat.id, entryIdOf(maxId));
  },

  toggleDialogUnread({ chat, hasUnreadMark }: { chat: ApiChat; hasUnreadMark?: boolean }) {
    mark(chat.id, { unread: Boolean(hasUnreadMark) });
  },

  toggleChatPinned({ chat, shouldBePinned }: { chat: ApiChat; shouldBePinned: boolean }) {
    pin(chat.id, shouldBePinned);
  },

  toggleChatArchived({ chat, folderId }: { chat: ApiChat; folderId: number }) {
    mark(chat.id, { archived: folderId === ARCHIVED_FOLDER_ID });
  },

  requestChatUpdate({ chat }: { chat: ApiChat }) {
    requestDialog(chat.id);
  },

  downloadMedia({ url, mediaFormat }: { url: string; mediaFormat: ApiMediaFormat }) {
    return downloadMedia(url, mediaFormat);
  },

  fetchChatFolders() {
    // No folders: the list without tabs
    return { byId: {}, orderedIds: [ALL_FOLDER_ID], areTagsEnabled: false };
  },

  fetchPeerColors() {
    return {
      colors: Object.fromEntries(PEER_COLORS.map((color, i) => [i, { colors: [color], darkColors: [color] }])),
    };
  },
};
