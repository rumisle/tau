// tau's items in Web A's chat list menu (hooks/useChatContextActions.ts)
import { getGlobal } from '../global';

import type { MenuItemContextAction } from '../components/ui/ListItem';

import { hide } from './api/session';
import { STRINGS } from './strings';

import { openRename } from './components/RenameModal';

/** Hide: out of every list and search, on every device; kept, as durable deletes no conversation */
export function buildTauHideAction(chatId: string): MenuItemContextAction {
  return {
    title: STRINGS.MenuHide, icon: 'eye-crossed', destructive: true, handler: () => hide(chatId),
  };
}

/** Rename: a small dialog, then a toast with Undo */
export function buildTauRenameAction(chatId: string): MenuItemContextAction {
  return {
    title: STRINGS.MenuRename,
    icon: 'edit',
    handler: () => openRename(chatId, getGlobal().chats.byId[chatId]?.title ?? ''),
  };
}
