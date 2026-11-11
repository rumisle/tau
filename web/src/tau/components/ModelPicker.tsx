// The model picker (ios/Tau after Telegram's LanguageSelectionScreen): the server's models in Web A's searchable
// picker, the recent ones first, then by provider; the search matches a name, an ID or a provider; Enter takes the
// first match. Its own root, so it outlives the menu that opened it.
import { memo, useEffect, useMemo, useState } from '../../lib/teact/teact';
import TeactDOM from '../../lib/teact/teact-dom';
import { getActions } from '../../global';

import type { ItemPickerOption } from '../../components/common/pickers/ItemPicker';
import type { ModelInfo } from '../api/agent';

import captureKeyboardListeners from '../../util/captureKeyboardListeners';
import {
  agentOf, cachedModels, configureAgent, loadModels, recentModels, rememberModel,
} from '../api/agent';
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
  const matches = (model: ModelInfo) => !query || [model.name, model.id, model.provider]
    .some((text) => text.toLowerCase().includes(query));
  const byKey = new Map(models.map((model) => [keyOf(model), model]));
  const first = recent.map((key) => byKey.get(key)).filter((model): model is ModelInfo => Boolean(model));
  const rest = models.filter((model) => !recent.includes(keyOf(model)))
    .sort((a, b) => a.provider.localeCompare(b.provider) || a.name.localeCompare(b.name));
  return [...first, ...rest].filter(matches);
}

const ModelPicker = ({ chatId, isOpen, onClose }: OwnProps) => {
  const [models, setModels] = useState<ModelInfo[] | undefined>(cachedModels);
  const [filter, setFilter] = useState('');
  const current = agentOf(chatId).model;

  useEffect(() => {
    void loadModels().then(setModels);
  }, []);

  const ordered = useMemo(() => orderModels(models ?? [], recentModels(), filter), [models, filter]);
  const items: ItemPickerOption[] = ordered.map((model) => ({
    value: keyOf(model), label: model.name, subLabel: `${model.provider} · ${model.id}`,
  }));

  const pick = useLastCallback((key: string) => {
    const model = ordered.find((each) => keyOf(each) === key);
    if (!model) return;
    configureAgent(chatId, { model: { provider: model.provider, modelId: model.id } });
    rememberModel(key);
    getActions().showNotification({ message: `Model: ${model.name}` });
    onClose();
  });

  useEffect(() => (isOpen ? captureKeyboardListeners({
    onEnter: (e: KeyboardEvent) => {
      e.preventDefault();
      if (ordered[0]) pick(keyOf(ordered[0]));
    },
  }) : undefined), [isOpen, ordered, pick]);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={STRINGS.MenuModel}
      className="tau-model-picker"
      isSlim
      hasCloseButton
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
  const close = () => {
    render(false);
    // After the modal's closing animation
    window.setTimeout(() => TeactDOM.render(undefined, container), CLOSE_MS);
  };
  render(true);
}

const CLOSE_MS = 300;
