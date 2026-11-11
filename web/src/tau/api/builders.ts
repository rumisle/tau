// tau's Dialogs and entries as Web A's Api* objects (docs/web.md "Structure inside"): a Dialog is a private chat with a
// user of its own; an entry is a message with its entry ID, `tau` content for tau's row, and a rich message for the rest
import type { Dialog, Entry } from 'tau-client/protocol';

import type {
  ApiChat, ApiMessage, ApiPageBlock, ApiRichMessage, ApiThreadInfo, ApiUser,
} from '../../api/types';
import type { ThreadReadState } from '../../types';
import type { ApiTauPart } from './types';
import { MAIN_THREAD_ID } from '../../api/types';

import { ARCHIVED_FOLDER_ID } from '../../config';
import { STRINGS } from '../strings';
import { buildMarkdownBlocks, buildParagraph } from './markdown';

// The user's own account. Conversation IDs are entry IDs, far below it.
export const ME_ID = '9000000000';
// New Chat's draft, a chat until its conversation exists (session.ts)
export const DRAFT_CHAT_ID = '8999999999';
const MAX_TOOL_OUTPUT = 2000;
// Rows per entry: an entry is one message or several (a user's photos, an album of messages as Telegram sends one), so
// a message's ID is its entry's ID times this, plus its row. Entry IDs stay far below 2^53 / ROWS.
export const ROWS = 32;

export function messageIdOf(entryId: number, row = 0) {
  return entryId * ROWS + row;
}

/** The last ID an entry's rows may take: what is read or sent up to an entry covers all its rows */
export function lastRowIdOf(entryId: number) {
  return entryId * ROWS + ROWS - 1;
}

export function entryIdOf(messageId: number) {
  return Math.floor(messageId / ROWS);
}

export function buildChatId(conversationId: number) {
  return String(conversationId);
}

export function buildTitle(dialog: Dialog) {
  return dialog.title || `Chat ${dialog.conversation.id}`;
}

export function buildUser(dialog: Dialog): ApiUser {
  return {
    id: buildChatId(dialog.conversation.id),
    isMin: false,
    type: 'userTypeRegular',
    firstName: buildTitle(dialog),
    phoneNumber: '',
    noStatus: true,
  };
}

export function buildMe(): ApiUser {
  return {
    id: ME_ID,
    isMin: false,
    isSelf: true,
    type: 'userTypeRegular',
    firstName: 'You',
    phoneNumber: '',
  };
}

export function buildDraftUser(): ApiUser {
  return {
    id: DRAFT_CHAT_ID,
    isMin: false,
    type: 'userTypeRegular',
    firstName: STRINGS.NewChat,
    phoneNumber: '',
    noStatus: true,
  };
}

export function buildDraftChat(): ApiChat {
  return {
    id: DRAFT_CHAT_ID,
    type: 'chatTypePrivate',
    title: STRINGS.NewChat,
  };
}

export function buildChat(dialog: Dialog): ApiChat {
  return {
    id: buildChatId(dialog.conversation.id),
    type: 'chatTypePrivate',
    title: buildTitle(dialog),
    folderId: dialog.archived ? ARCHIVED_FOLDER_ID : undefined,
    isListed: true,
    creationDate: dialog.createdAt ? Math.floor(dialog.createdAt / 1000) : undefined,
  };
}

export function buildReadState(dialog: Dialog): ThreadReadState {
  return {
    unreadCount: dialog.unreadCount,
    hasUnreadMark: dialog.markedUnread,
    lastReadInboxMessageId: dialog.read === undefined ? undefined : lastRowIdOf(dialog.read),
    lastReadOutboxMessageId: dialog.last === undefined ? undefined : lastRowIdOf(dialog.last.id),
  };
}

export function buildThreadInfo(dialog: Dialog): ApiThreadInfo {
  return {
    isCommentsInfo: false,
    chatId: buildChatId(dialog.conversation.id),
    threadId: MAIN_THREAD_ID,
    lastMessageId: dialog.last === undefined ? undefined : messageIdOf(dialog.last.id),
  };
}

/** The chat list's last message, from the Dialog's summary of its newest entry */
export function buildSummaryMessage(dialog: Dialog): ApiMessage | undefined {
  const { last } = dialog;
  if (!last) return undefined;
  return {
    id: messageIdOf(last.id),
    chatId: buildChatId(dialog.conversation.id),
    date: Math.floor((last.timestamp ?? dialog.createdAt ?? Date.now()) / 1000),
    isOutgoing: last.role === 'user',
    senderId: last.role === 'user' ? ME_ID : buildChatId(dialog.conversation.id),
    content: { text: { text: last.text } },
  };
}

/** What building a message needs beyond its entry: from the replica it is in, and the chat list */
export type MessageContext = {
  // Tool results by call ID: a call's result is a later entry, shown in the call's message
  results: Map<string, any>;
  // When the run an assistant entry ends began: its user message's time
  runStartAt: (entryId: number) => number | undefined;
  // A subagent's task, by its conversation, from the call that started it
  subagentTask: (conversationId: number) => string | undefined;
  isBusy: (conversationId: number) => boolean;
};

const SUBAGENT_REPORT = /^<subagent name="([^"]*)" conversation="(\d+)" status="(\w+)">([\s\S]*)<\/subagent>$/;

/** An entry's messages, in order: none for those the chat does not show, several for an album */
export function buildRows(entry: Entry, context: MessageContext): ApiMessage[] {
  const message = buildMessage(entry, context);
  return message ? [message] : [];
}

/** An entry's first message, or undefined for those the chat does not show */
export function buildMessage(entry: Entry, context: MessageContext): ApiMessage | undefined {
  const message = (entry.model as any[] | undefined)?.[0];
  const chatId = buildChatId(entry.conversationId);
  const base = {
    id: messageIdOf(entry.id),
    chatId,
    date: Math.floor((message?.timestamp ?? Date.now()) / 1000),
  };

  switch (entry.kind) {
    case 'pi.user': {
      const text = userText(message.content);
      const report = SUBAGENT_REPORT.exec(text);
      if (report) {
        // A subagent's report, which the server submits as a user message: the subagent's card, on the answer's side
        const [, name, conversation, status, answer] = report;
        const answerBlocks = buildMarkdownBlocks(answer.trim());
        return {
          ...base,
          isOutgoing: false,
          senderId: chatId,
          content: {
            richMessage: {
              blocks: [
                buildParagraph(`${name} ${status}`),
                { type: 'blockquoteBlocks', blocks: answerBlocks, caption: { type: 'empty' } },
              ],
            },
          },
          tau: {
            role: 'assistant',
            parts: [{
              type: 'subagent',
              name,
              state: status,
              isFailed: status === 'failed',
              task: context.subagentTask(Number(conversation)) ?? 'Subagent',
              answer: answerBlocks,
            }],
          },
        };
      }
      return {
        ...base, isOutgoing: true, senderId: ME_ID, content: { text: { text } },
      };
    }
    case 'pi.assistant': {
      const isRunEnd = message.stopReason !== 'toolUse';
      const startAt = isRunEnd ? context.runStartAt(entry.id) : undefined;
      return {
        ...base,
        isOutgoing: false,
        senderId: chatId,
        content: { richMessage: buildAssistantRichMessage(message, context.results) },
        tau: {
          role: 'assistant',
          parts: buildAssistantParts(message, context),
          runEnd: isRunEnd
            ? { workedForMs: startAt !== undefined ? message.timestamp - startAt : undefined }
            : undefined,
        },
      };
    }
    case 'pi.tool-result':
    case 'pi.system':
      return undefined;
    default:
      // Compactions, resets, files and subagents a script started: a placeholder per kind
      return {
        ...base,
        isOutgoing: false,
        senderId: chatId,
        content: { text: { text: `[${entry.kind}]` } },
        tau: { role: 'notice', parts: [{ type: 'text', blocks: [buildParagraph(`[${entry.kind}]`)] }] },
      };
  }
}

/** An assistant message as tau's row draws it: thinking, Markdown, and a card per tool call */
export function buildAssistantParts(message: any, context?: MessageContext): ApiTauPart[] {
  const parts: ApiTauPart[] = [];
  for (const part of message.content as any[]) {
    if (part.type === 'thinking' && part.thinking) {
      parts.push({ type: 'thinking', text: part.thinking.trim() });
    } else if (part.type === 'text' && part.text) {
      parts.push({ type: 'text', blocks: buildMarkdownBlocks(part.text) });
    } else if (part.type === 'toolCall') {
      parts.push(buildToolPart(part, message.timestamp, context?.results.get(part.id), context));
    }
  }
  if (message.errorMessage) parts.push({ type: 'text', blocks: [buildParagraph(`⚠ ${message.errorMessage}`)] });
  return parts;
}

function buildToolPart(call: any, startedAt: number, result: any, context?: MessageContext): ApiTauPart {
  const args = call.arguments ?? {};
  const output = result ? userText(result.content).replace(/<\/?harness>/g, '').trim() : undefined;
  const status = !result ? 'running' : result.isError ? 'failed' : 'done';
  const base = {
    type: 'tool' as const, id: call.id, status, output, durationMs: result?.durationMs, startedAt,
  } as const;
  switch (call.name) {
    case 'bash':
      return {
        ...base, title: 'Bash', command: `$ ${String(args.command ?? '').trim()}`, language: 'bash',
      };
    case 'read':
      return { ...base, title: 'Read', summary: shortPath(args.path) };
    case 'write': {
      const content = String(args.content ?? '');
      const lines = content ? content.split('\n').length : 0;
      const summary = `${shortPath(args.path)}  ${lines} lines`;
      return {
        ...base, title: 'Write', summary, command: content, output: undefined,
      };
    }
    case 'edit':
      return { ...base, title: 'Edit', summary: shortPath(args.path) };
    case 'subagent': {
      const childId = result?.details?.conversationId;
      const isWorking = !result || (childId !== undefined && context?.isBusy(childId));
      return {
        type: 'subagent',
        name: String(args.name ?? 'subagent'),
        state: args.action === 'spawn' || !args.action ? (isWorking ? 'working' : '') : String(args.action),
        isWorking,
        isFailed: result?.isError,
        task: String(args.message ?? args.task ?? ''),
      };
    }
    default: {
      const summary = Object.values(args).find((value): value is string => typeof value === 'string');
      return {
        ...base, title: call.name === 'code' ? 'Code' : call.name, summary: summary?.split('\n')[0],
      };
    }
  }
}

function shortPath(path: unknown) {
  return (typeof path === 'string' ? path : '').replace(/^\/home\/[^/]+/, '~');
}

export function buildAssistantRichMessage(message: any, results?: Map<string, any>): ApiRichMessage {
  const blocks: ApiPageBlock[] = [];
  // Thinking only when there is nothing else: the chat list's preview is the answer, as the Dialog's summary is
  const hasMore = (message.content as any[]).some((part) => (part.type === 'text' && part.text)
    || part.type === 'toolCall');
  for (const part of message.content as any[]) {
    if (part.type === 'thinking' && part.thinking) {
      if (!hasMore) blocks.push({ type: 'thinking', text: { type: 'plain', text: part.thinking } });
    } else if (part.type === 'text' && part.text) {
      blocks.push(...buildMarkdownBlocks(part.text));
    } else if (part.type === 'toolCall') {
      blocks.push(buildToolBlock(part, results?.get(part.id)));
    }
  }
  if (message.errorMessage) blocks.push(buildParagraph(`⚠ ${message.errorMessage}`));
  if (!blocks.length) blocks.push(buildParagraph('…'));
  return { blocks };
}

function buildToolBlock(call: any, result: any) {
  const args = call.name === 'bash' && typeof call.arguments?.command === 'string'
    ? call.arguments.command
    : JSON.stringify(call.arguments ?? {}, undefined, 2);
  const firstString = Object.values(call.arguments ?? {}).find((value) => typeof value === 'string') as string;
  const output = result ? userText(result.content) : undefined;
  const blocks: ApiPageBlock[] = [
    { type: 'preformatted', text: { type: 'plain', text: args }, language: '' },
  ];
  if (output) {
    const clipped = output.length > MAX_TOOL_OUTPUT ? `${output.slice(0, MAX_TOOL_OUTPUT)}\n…` : output;
    blocks.push({ type: 'preformatted', text: { type: 'plain', text: clipped }, language: '' });
  }
  const status = !result ? ' …' : result.isError ? ' ✗' : '';
  const summary = (call.name === 'bash' ? args : firstString ?? '').split('\n')[0].slice(0, 60);
  return {
    type: 'details' as const,
    title: { type: 'plain' as const, text: `🔧 ${call.name} · ${summary}${status}` },
    blocks,
  };
}

export function userText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map((part) => (part.type === 'text' ? part.text : part.type === 'image' ? '[image]' : ''))
    .join('');
}
