// The `callApi` methods tau answers. Every other method resolves to `undefined`, as a failed GramJS request does, and
// the UI copes (docs/web.md "What the proof of concept showed").
import type {
  ApiAttachment, ApiChat, ApiMediaFormat, ApiMessageEntity, ApiPeer,
} from '../../api/types';

import { ALL_FOLDER_ID } from '../../config';
import {
  buildChat, buildChatId, buildReadState, buildThreadInfo, buildUser,
} from './builders';
import { downloadMedia } from './media';
import { toMarkdown } from './outgoing';
import {
  chatListMessage, dialogs, draftHistory, fetchHistory, isDraftChat, isListed, requestDialog, sendChatListMessages,
  sendText, stop,
} from './session';

// Telegram's seven peer colors, which its server sends with `help.getPeerColors`; without them avatars are black
const PEER_COLORS = ['#CC5049', '#D67722', '#955CDB', '#40A920', '#309EBA', '#368AD1', '#C7508B'];

export const methods: Record<string, (...args: any[]) => unknown> = {
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
    return {
      chatIds: listed.map((dialog) => buildChatId(dialog.conversation.id)),
      chats: listed.map(buildChat),
      users: listed.map(buildUser),
      userStatusesById: {},
      draftsById: {},
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
      const messages = offsetId ? [] : draftHistory();
      return {
        messages, users: [], chats: [], count: messages.length, topics: [],
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
    return sendText(chat.id, text ? toMarkdown(text, entities) : '', files);
  },

  sendMessageAction({ peer, action }: { peer: ApiPeer; action: { type: string } }) {
    // The composer's Stop, which Web A has for a bot's streamed answer and tau for the whole run (src/tau/selectors.ts)
    if (action.type === 'stopDraft') stop(Number(peer.id));
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
