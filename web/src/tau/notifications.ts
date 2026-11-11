// An agent's answer as a system notification (docs/web.md "Notifications"; iOS shows Telegram's in-app banner): for
// any chat but the one on screen while the window has focus, as Telegram Desktop does. Web A's own notifications,
// one per incoming message, are off for tau (util/notifications.tsx): tau decides on the chat list (api/answers.ts).
import { getActions, getGlobal } from '../global';

import type { Answer } from './api/answers';

import { selectCurrentMessageList, selectSettingsKeys } from '../global/selectors';
import { playNotifySoundDebounced } from '../util/notifications';

/** The user looks at the page: the window has focus and the tab shows */
export function isLooking() {
  return document.visibilityState === 'visible' && document.hasFocus();
}

export function notifyAnswer(answer: Answer, chatId: string) {
  const global = getGlobal();
  if (!selectSettingsKeys(global).hasWebNotifications) return;
  if (!('Notification' in window) || Notification.permission !== 'granted') return;
  if (isLooking() && selectCurrentMessageList(global)?.chatId === chatId) return;
  // One per chat: a newer answer replaces the one before
  const notification = new Notification(answer.title, { body: answer.text, tag: chatId });
  notification.onclick = () => {
    notification.close();
    window.focus();
    getActions().openChat({ id: chatId, shouldReplaceHistory: true });
  };
  notification.onshow = () => playNotifySoundDebounced(chatId);
}
