// The `callApi` methods tau answers. Every other method resolves to `undefined`, as a failed GramJS request does, and
// the UI copes (docs/web.md "What the proof of concept showed").
import type { ApiChat } from '../../api/types';

import { ALL_FOLDER_ID } from '../../config';
import {
  buildChat, buildChatId, buildReadState, buildSummaryMessage, buildThreadInfo, buildUser,
} from './builders';
import {
  dialogs, fetchHistory, isListed, requestDialog,
} from './session';

// Telegram's seven peer colors, which its server sends with `help.getPeerColors`; without them avatars are black
const PEER_COLORS = ['#CC5049', '#D67722', '#955CDB', '#40A920', '#309EBA', '#368AD1', '#C7508B'];

export const methods: Record<string, (...args: any[]) => unknown> = {
  fetchChats({ archived }: { archived?: boolean }) {
    const listed = dialogs.ordered()
      .filter((dialog) => isListed(dialog) && Boolean(dialog.archived) === Boolean(archived));
    // Nothing is cached yet, so the chat list's last messages are the Dialogs' summaries; an opened chat replaces its
    // with the entry (session.ts)
    const messages = listed.map(buildSummaryMessage).filter((message) => message !== undefined);
    const pinned = listed.filter((dialog) => dialog.pinned).sort((a, b) => b.pinned! - a.pinned!);
    return {
      chatIds: listed.map((dialog) => buildChatId(dialog.conversation.id)),
      chats: listed.map(buildChat),
      users: listed.map(buildUser),
      userStatusesById: {},
      draftsById: {},
      orderedPinnedIds: pinned.map((dialog) => buildChatId(dialog.conversation.id)),
      totalChatCount: listed.length,
      messages,
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
    const { messages, count } = await fetchHistory(Number(chat.id), offsetId, addOffset ?? 0, limit);
    return {
      messages, users: [], chats: [], count, topics: [],
    };
  },

  requestChatUpdate({ chat }: { chat: ApiChat }) {
    requestDialog(chat.id);
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
