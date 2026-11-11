// tau's items in Web A's chat list menu (hooks/useChatContextActions.ts)
import type { MenuItemContextAction } from '../components/ui/ListItem';

import { hide } from './api/session';
import { STRINGS } from './strings';

/** Hide: out of every list and search, on every device; kept, as durable deletes no conversation */
export function buildTauHideAction(chatId: string): MenuItemContextAction {
  return {
    title: STRINGS.MenuHide, icon: 'eye-crossed', destructive: true, handler: () => hide(chatId),
  };
}
