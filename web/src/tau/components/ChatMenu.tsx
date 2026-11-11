// The chat's ⋯ menu, in place of Web A's header menu (ios/Tau/Chat/ChatController.swift openChatMenu): Search, the
// model and thinking level with their submenus, Compact Context, in Web A's Menu with its nested submenus.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { Agent } from '../api/agent';

import {
  agentOf, compact, configureAgent, describeContext, formatCost, formatTokens, loadModels, modelName, onAgentChange,
  summarizeUsage, thinkingLevels, thinkingTitle,
  usageOf,
} from '../api/agent';
import { STRINGS } from '../strings';

import Menu from '../../components/ui/Menu';
import MenuItem, { MenuItemSubtitle, MenuItemTitle } from '../../components/ui/MenuItem';
import MenuSeparator from '../../components/ui/MenuSeparator';
import NestedMenuItem from '../../components/ui/NestedMenuItem';
import { openModelPicker } from './ModelPicker';

type OwnProps = {
  chatId: string;
  isOpen: boolean;
  x: number;
  y: number;
  shouldCloseFast?: boolean;
  canSearch?: boolean;
  onSearch: () => void;
  onClose: () => void;
};

function UsageRow({ title, value }: { title: string; value: string }) {
  return (
    <MenuItem disabled className="tau-usage-row">
      <MenuItemTitle>{title}</MenuItemTitle>
      <MenuItemSubtitle>{value}</MenuItemSubtitle>
    </MenuItem>
  );
}

const ChatMenu = ({
  chatId, isOpen, x, y, shouldCloseFast, canSearch, onSearch, onClose,
}: OwnProps) => {
  const [agent, setAgent] = useState<Agent>(() => agentOf(chatId));
  useEffect(() => onAgentChange(() => setAgent(agentOf(chatId))), [chatId]);
  const usage = usageOf(chatId);

  // Names and thinking levels come with the models; their load is an agent change
  useEffect(() => {
    void loadModels();
  }, []);

  const pick = (change: Parameters<typeof configureAgent>[1], toast: string) => {
    configureAgent(chatId, change);
    getActions().showNotification({ message: toast });
    onClose();
  };

  return (
    <Menu
      isOpen={isOpen}
      positionX="right"
      style={`left: ${x}px;top: ${y}px;`}
      onClose={onClose}
      shouldCloseFast={shouldCloseFast}
    >
      {canSearch && <MenuItem icon="search" onClick={onSearch}>{STRINGS.MenuSearch}</MenuItem>}
      <MenuItem
        icon="settings"
        onClick={() => {
          onClose();
          openModelPicker(chatId);
        }}
      >
        <MenuItemTitle>{STRINGS.MenuModel}</MenuItemTitle>
        <MenuItemSubtitle>{modelName(agent.model)}</MenuItemSubtitle>
      </MenuItem>
      <NestedMenuItem
        icon="timer"
        submenu={thinkingLevels(agent).map((level) => (
          <MenuItem
            key={level}
            icon={level === agent.thinkingLevel ? 'check' : 'placeholder'}
            onClick={() => pick(
              { thinkingLevel: level },
              level === 'off' ? STRINGS.ThinkingOff : `Thinking set to ${thinkingTitle(level)}`,
            )}
          >
            {thinkingTitle(level)}
          </MenuItem>
        ))}
      >
        <MenuItemTitle>{STRINGS.MenuThinking}</MenuItemTitle>
        <MenuItemSubtitle>{thinkingTitle(agent.thinkingLevel)}</MenuItemSubtitle>
      </NestedMenuItem>
      <MenuSeparator />
      <NestedMenuItem
        icon="info"
        submenu={(
          <>
            <UsageRow title={STRINGS.UsageContext} value={describeContext(usage)} />
            <UsageRow title={STRINGS.UsageCost} value={formatCost(usage.cost)} />
            <MenuSeparator />
            <UsageRow
              title={STRINGS.UsageTokens}
              value={`${formatTokens(usage.total.input)} in, ${formatTokens(usage.total.output)} out`}
            />
            <UsageRow
              title={STRINGS.UsageCached}
              value={`${formatTokens(usage.total.cacheRead)} read, ${formatTokens(usage.total.cacheWrite)} written`}
            />
            {usage.models.length > 1 && <MenuSeparator />}
            {usage.models.length > 1 && usage.models.map(({ model, usage: each }) => (
              <UsageRow key={model} title={model.split('/').at(-1)!} value={formatCost(each.cost)} />
            ))}
          </>
        )}
      >
        <MenuItemTitle>{STRINGS.MenuUsage}</MenuItemTitle>
        <MenuItemSubtitle>{summarizeUsage(usage)}</MenuItemSubtitle>
      </NestedMenuItem>
      <MenuItem
        icon="replace"
        onClick={() => {
          void compact(chatId).catch(() => undefined);
          onClose();
        }}
      >
        {STRINGS.MenuCompact}
      </MenuItem>
    </Menu>
  );
};

export default memo(ChatMenu);
