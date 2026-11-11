// A tool call's card, as the iOS app draws it (`toolCardContent` in ios/Tau/Chat/ChatMessageItem.swift): the tool, what
// it works on, the command, the output's last lines; a click shows it all. While it runs, a spinner and its time.
import { memo, useState } from '../../lib/teact/teact';

import type { ApiTauPart } from '../api/types';

import buildClassName from '../../util/buildClassName';
import { clipLines, formatDuration, formatElapsed } from './format';

import useIntervalForceUpdate from '../../hooks/schedulers/useIntervalForceUpdate';
import useAsync from '../../hooks/useAsync';

import Spinner from '../../components/ui/Spinner';

import styles from './TauMessage.module.scss';

// A collapsed card shows a command's first lines and its output's last, as iOS does
const COMMAND_LINES = 3;
const OUTPUT_LINES = 6;
const DIFF_LINES = 10;
const EXPANDED_LINES = 200;
const TICK_MS = 1000;

const ToolCard = ({ part }: { part: Extract<ApiTauPart, { type: 'tool' }> }) => {
  const [isExpanded, setIsExpanded] = useState(false);
  const isActive = part.status === 'running';
  // While it runs, its time ticks; then how long it took
  useIntervalForceUpdate(isActive ? TICK_MS : undefined);
  const command = part.command
    && clipLines(part.command, isExpanded ? EXPANDED_LINES : part.commandLines ?? COMMAND_LINES, true);
  const output = part.output && clipLines(
    part.output, isExpanded ? EXPANDED_LINES : part.outputLines ?? OUTPUT_LINES, Boolean(part.isOutputFromStart),
  );
  const diff = part.diff && clipLines(part.diff, isExpanded ? EXPANDED_LINES : DIFF_LINES, true);
  const elapsed = isActive && part.startedAt ? Date.now() - part.startedAt : undefined;
  const time = elapsed !== undefined
    ? (elapsed >= 1000 ? formatElapsed(elapsed) : undefined)
    : part.durationMs !== undefined && part.durationMs >= 1000 ? formatDuration(part.durationMs) : undefined;
  const { result: highlighted } = useAsync(() => highlight(command, part.language), [command, part.language]);
  const { result: highlightedOutput } = useAsync(
    () => highlight(output, part.outputLanguage), [output, part.outputLanguage],
  );

  return (
    <div
      className={buildClassName(styles.card, styles.tool, isExpanded && styles.expanded)}
      data-tau-part="tool"
      data-tau-tool={part.title}
      data-tau-status={part.status}
      onClick={() => setIsExpanded(!isExpanded)}
    >
      <div className={styles.toolTitle}>
        <span className={buildClassName(styles.toolName, part.status === 'failed' && styles.failed)}>
          {part.title}
        </span>
        {part.summary && <span className={styles.toolSummary}>{part.summary}</span>}
        {time && <span className={styles.toolTime}>{time}</span>}
        {isActive && <Spinner className={styles.spinner} color="gray" />}
      </div>
      {(command || output || diff) && (
        <pre className={styles.toolBody}>
          {command && <span className={styles.toolCommand}>{highlighted ?? command}</span>}
          {diff && diff.split('\n').map((line, index) => (
            <span
              key={index}
              className={kindOf(line) && (kindOf(line) === 'added' ? styles.diffAdded : styles.toolError)}
              data-tau-diff={kindOf(line)}
            >
              {index > 0 && '\n'}
              {line}
            </span>
          ))}
          {(command || diff) && output && '\n'}
          {output && (
            <span className={part.status === 'failed' ? styles.toolError : undefined}>
              {highlightedOutput ?? output}
            </span>
          )}
        </pre>
      )}
    </div>
  );
};

function kindOf(line: string) {
  return line.startsWith('+') ? 'added' : line.startsWith('-') ? 'removed' : undefined;
}

function highlight(text: string | undefined, language: string | undefined) {
  if (!text || !language) return Promise.resolve(undefined);
  return import('../../util/highlightCode').then((lib) => lib.default(text, language));
}

export default memo(ToolCard);
