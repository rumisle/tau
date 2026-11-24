// The model picker (ios/Tau after Telegram's LanguageSelectionScreen): the server's models in Web A's searchable
// picker, the recent ones first, then by provider; the search matches a name, an ID or a provider; Enter takes the
// first match. Its own root, so it outlives the menu that opened it.
import { memo, useEffect, useMemo, useRef, useState } from '../../lib/teact/teact';
import TeactDOM from '../../lib/teact/teact-dom';
import { getActions } from '../../global';

import type { ItemPickerOption } from '../../components/common/pickers/ItemPicker';
import type { ModelInfo } from '../api/agent';

import {
  agentOf, cachedModels, configureAgent, loadModels, recentModels, rememberModel,
} from '../api/agent';
import { slotOfChat } from '../api/session';
import { STRINGS } from '../strings';

import useLastCallback from '../../hooks/useLastCallback';

import ItemPicker from '../../components/common/pickers/ItemPicker';
import Modal from '../../components/ui/Modal';

type OwnProps = {
  chatId: string;
  isOpen: boolean;
  onClose: NoneToVoidFunction;
};

const keyOf = (model: { provider: string; id: string }) => `${model.provider}/${model.id}`;

/** The models in the picker's order: recent first, then by provider and name; those the search matches */
export function orderModels(models: ModelInfo[], recent: string[], filter: string) {
  const query = filter.trim().toLowerCase();
  const matches = (model: ModelInfo) => query.split(/\s+/).every((word) =>
    `${model.name} ${model.provider}/${model.id}`.toLowerCase().includes(word));
  const byKey = new Map(models.map((model) => [keyOf(model), model]));
  const first = recent.map((key) => byKey.get(key)).filter((model): model is ModelInfo => Boolean(model));
  const rest = models.filter((model) => !recent.includes(keyOf(model)))
    .sort((a, b) => a.provider.localeCompare(b.provider) || a.name.localeCompare(b.name));
  return [...first, ...rest].filter(matches);
}

const ModelPicker = ({ chatId, isOpen, onClose }: OwnProps) => {
  // The chat's server's
  const slot = slotOfChat(chatId);
  const [models, setModels] = useState<ModelInfo[] | undefined>(() => cachedModels(slot));
  const [filter, setFilter] = useState('');
  const current = agentOf(chatId).model;

  useEffect(() => {
    let disposed = false;
    void loadModels(slot, undefined, true).then((result) => {
      if (!disposed && result) setModels(result);
    });
    return () => {
      disposed = true;
    };
  }, [slot]);

  const ordered = useMemo(() => orderModels(models ?? [], recentModels(), filter), [models, filter]);
  const searchedRef = useRef(new Set<string>());
  useEffect(() => {
    const query = filter.trim();
    const key = `${slot}:${query.toLowerCase()}`;
    if (!isOpen || !models || !query || ordered.length || searchedRef.current.has(key)) return undefined;
    let disposed = false;
    const timeout = window.setTimeout(() => {
      searchedRef.current.add(key);
      void loadModels(slot, query).then((result) => {
        if (!disposed && result) setModels(result);
      });
    }, 500);
    return () => {
      disposed = true;
      window.clearTimeout(timeout);
    };
  }, [slot, filter, ordered.length, isOpen, models]);
  const items: ItemPickerOption[] = ordered.map((model) => ({
    value: keyOf(model), label: model.name, subLabel: `${model.provider}/${model.id}`,
  }));

  const pick = useLastCallback((key: string) => {
    const model = ordered.find((each) => keyOf(each) === key);
    if (!model) return;
    configureAgent(chatId, { model: { provider: model.provider, modelId: model.id } });
    rememberModel(key);
    getActions().showNotification({ message: `Model changed to **${model.name}**` });
    onClose();
  });

  // Enter takes the first match
  const takeFirst = useLastCallback(() => {
    if (ordered[0]) pick(keyOf(ordered[0]));
  });

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={STRINGS.MenuModel}
      className="tau-model-picker"
      isSlim
      hasCloseButton
      onEnter={takeFirst}
    >
      <ItemPicker
        items={items}
        selectedValue={current ? `${current.provider}/${current.modelId}` : undefined}
        onSelectedValueChange={pick}
        itemInputType="radio"
        isSearchable
        filterValue={filter}
        onFilterChange={setFilter}
        filterPlaceholder={STRINGS.ModelSearch}
        isLoading={!models}
        forceRenderAllItems
        withDefaultPadding
      />
    </Modal>
  );
};

const Memo = memo(ModelPicker);

let root: HTMLDivElement | undefined;
let opened = 0;

/** Opens the picker for a chat, over everything */
export function openModelPicker(chatId: string) {
  if (!root) {
    root = document.createElement('div');
    document.body.appendChild(root);
  }
  const container = root;
  const render = (isOpen: boolean) => TeactDOM.render(
    <Memo chatId={chatId} isOpen={isOpen} onClose={() => close()} />, container,
  );
  const token = ++opened;
  const close = () => {
    render(false);
    // After the modal's closing animation, unless it opened again meanwhile
    window.setTimeout(() => {
      if (opened === token) TeactDOM.render(undefined, container);
    }, CLOSE_MS);
  };
  render(true);
}

const CLOSE_MS = 300;
