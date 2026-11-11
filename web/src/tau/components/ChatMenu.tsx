// The chat's ⋯ menu, in place of Web A's header menu (ios/Tau/Chat/ChatController.swift openChatMenu): Search, the
// model and thinking level with their submenus, Compact Context, in Web A's Menu with its nested submenus.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { Agent, ModelInfo } from '../api/agent';

import {
  agentOf, cachedModels, compact, configureAgent, loadModels, modelName, onAgentChange, thinkingLevels,
  thinkingTitle,
} from '../api/agent';
import { STRINGS } from '../strings';

import Menu from '../../components/ui/Menu';
import MenuItem, { MenuItemSubtitle, MenuItemTitle } from '../../components/ui/MenuItem';
import MenuSeparator from '../../components/ui/MenuSeparator';
import NestedMenuItem from '../../components/ui/NestedMenuItem';

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

const ChatMenu = ({
  chatId, isOpen, x, y, shouldCloseFast, canSearch, onSearch, onClose,
}: OwnProps) => {
  const [agent, setAgent] = useState<Agent>(() => agentOf(chatId));
  const [models, setModels] = useState<ModelInfo[] | undefined>(cachedModels);

  useEffect(() => onAgentChange(() => {
    setAgent(agentOf(chatId));
    setModels(cachedModels());
  }), [chatId]);

  useEffect(() => {
    void loadModels().then(setModels);
  }, []);

  const pick = (change: Parameters<typeof configureAgent>[1], toast: string) => {
    configureAgent(chatId, change);
    getActions().showNotification({ message: toast });
    onClose();
  };

  const isCurrentModel = (model: ModelInfo) => model.provider === agent.model?.provider
    && model.id === agent.model?.modelId;

  return (
    <Menu
      isOpen={isOpen}
      positionX="right"
      style={`left: ${x}px;top: ${y}px;`}
      onClose={onClose}
      shouldCloseFast={shouldCloseFast}
    >
      {canSearch && <MenuItem icon="search" onClick={onSearch}>{STRINGS.MenuSearch}</MenuItem>}
      <NestedMenuItem
        icon="settings"
        submenu={models ? models.map((model) => (
          <MenuItem
            key={`${model.provider}/${model.id}`}
            icon={isCurrentModel(model) ? 'check' : 'placeholder'}
            onClick={() => pick({ model: { provider: model.provider, modelId: model.id } }, `Model: ${model.name}`)}
          >
            <MenuItemTitle>{model.name}</MenuItemTitle>
            <MenuItemSubtitle>{model.provider}</MenuItemSubtitle>
          </MenuItem>
        )) : <MenuItem disabled>{STRINGS.MenuLoading}</MenuItem>}
      >
        <MenuItemTitle>{STRINGS.MenuModel}</MenuItemTitle>
        <MenuItemSubtitle>{modelName(agent.model)}</MenuItemSubtitle>
      </NestedMenuItem>
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
