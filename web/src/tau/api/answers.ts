// Which chat list changes are answers to tell the user about (docs/notifications.md "In the app", as iOS's
// ServerStore): a top-level chat whose run ended with a newer assistant entry, unread. The first list after a connect
// only sets the baseline: what came while the page was away is not news.
import type { Dialog } from 'tau-client/protocol';

export type Answer = { conversationId: number; title: string; text: string };

export class AnswerWatch {
  readonly #seen = new Map<number, { last: number; busy: boolean }>();

  /** The answers among a list's changed dialogs; none when `isBaseline` (the first list after a connect) */
  changed(dialogs: Dialog[], isBaseline: boolean): Answer[] {
    const answers: Answer[] = [];
    for (const dialog of dialogs) {
      const id = dialog.conversation.id;
      const previous = this.#seen.get(id);
      const { last } = dialog;
      this.#seen.set(id, { last: last?.id ?? 0, busy: dialog.busy });
      if (isBaseline || !last || last.role !== 'assistant' || dialog.busy || dialog.conversation.owner) continue;
      if (dialog.unreadCount === 0 || last.id <= (previous?.last ?? 0)) continue;
      // Its run ended now: a chat seen working, or one new since the baseline
      if (previous && !previous.busy) continue;
      answers.push({ conversationId: id, title: dialog.title ?? '', text: plainPreview(last.text) });
    }
    return answers;
  }
}

/**
 * The chat list's summary of an answer (its text in one line, server/src/dialogs.ts `preview`) without Markdown's
 * inline marks, as iOS's `plainPreview`: code fences, emphasis, code and links
 */
export function plainPreview(summary: string) {
  return summary
    .replace(/```[\w-]*/g, '')
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|\*|~~|`)(\S(?:.*?\S)?)\1/g, '$2')
    .replace(/(?<!\w)(__|_)(\S(?:.*?\S)?)\1(?!\w)/g, '$2')
    .replace(/\s+/g, ' ')
    .trim();
}
