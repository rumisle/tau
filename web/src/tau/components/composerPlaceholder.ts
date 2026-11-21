// The composer's placeholder for a tau chat: the verb, the model and its thinking level (composerPlaceholder),
// again when the agent or the server's models change.
import { useEffect } from '../../lib/teact/teact';

import { composerPlaceholder, loadModels, onAgentChange } from '../api/agent';
import { slotOfChat } from '../api/session';

import useForceUpdate from '../../hooks/useForceUpdate';

export function useComposerPlaceholder(chatId: string, isBusy?: boolean) {
  const forceUpdate = useForceUpdate();
  useEffect(() => {
    void loadModels(slotOfChat(chatId));
    return onAgentChange(forceUpdate);
  }, [chatId, forceUpdate]);
  return composerPlaceholder(chatId, isBusy);
}
