// Settings > Usage (dd77100; iOS's UsageController, after Telegram's statistics screens): the span, an overview of the
// totals with their change, the days as a stacked bar chart by model with a day to select (hover, or a click to keep
// it), then the models and the costliest chats, which open on a click. From every server's ledger, merged
// (api/usageReport.ts). In Web A's settings, in place of its Privacy and Security, which tau has no use for.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions, getGlobal } from '../../global';

import type { UsageMetric, UsageReport } from '../api/usageReport';

import buildClassName from '../../util/buildClassName';
import { buildChatId } from '../api/builders';
import { formatCost, formatTokens } from '../api/numbers';
import { usageReport } from '../api/session';
import {
  answersText, changeText, dayTitle, dayTotal, formatMetric, metricValue, niceCeiling, percentText, repliesText,
  shortModelName, tokensOf,
} from '../api/usageReport';
import { STRINGS } from '../strings';

import useHistoryBack from '../../hooks/useHistoryBack';

import Avatar from '../../components/common/Avatar';
import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import ListItem from '../../components/ui/ListItem';

import styles from './UsageSettings.module.scss';

type OwnProps = {
  isActive?: boolean;
  onReset: () => void;
};

// Telegram's statistics charts' series colors, for the models
const SERIES_COLORS = ['#3497ED', '#F5BD25', '#5FB641', '#E65850', '#9C6BEE', '#36C7D0', '#F79E39', '#8E8E93'];
const SPANS = [7, 30, 90];
const TOP_CHATS = 10;
// The chart, in the SVG's own units
const CHART_WIDTH = 300;
const CHART_HEIGHT = 120;

const UsageSettings = ({ isActive, onReset }: OwnProps) => {
  useHistoryBack({ isActive, onBack: onReset });
  const [span, setSpan] = useState(30);
  const [report, setReport] = useState<UsageReport | undefined>();
  const [isFailed, setIsFailed] = useState(false);
  const [chosenMetric, setChosenMetric] = useState<UsageMetric | undefined>();
  const [hoveredDay, setHoveredDay] = useState<number | undefined>();
  const [pinnedDay, setPinnedDay] = useState<number | undefined>();

  useEffect(() => {
    if (!isActive) return undefined;
    let isCurrent = true;
    setPinnedDay(undefined);
    void usageReport(span).then((result) => {
      if (!isCurrent) return;
      setReport(result);
      setIsFailed(!result);
    });
    return () => {
      isCurrent = false;
    };
  }, [isActive, span]);

  const spans = (
    <div className={styles.spans} role="tablist">
      {SPANS.map((days) => (
        <button
          key={days}
          type="button"
          role="tab"
          aria-selected={days === span}
          className={buildClassName(styles.span, days === span && styles.selected)}
          onClick={() => setSpan(days)}
        >
          {`${days} ${STRINGS.UsageDays}`}
        </button>
      ))}
    </div>
  );

  if (!report) {
    return (
      <div className="settings-content custom-scroll" data-tau-usage="loading">
        <Island>{spans}</Island>
        <IslandDescription>{isFailed ? STRINGS.UsageFailed : STRINGS.UsageLoading}</IslandDescription>
      </div>
    );
  }

  // Cost, unless nothing cost anything (free models): then tokens
  const metric = chosenMetric ?? (report.total.cost > 0 ? 'cost' : 'tokens');
  const colors = new Map(report.models.map((each, index) => [each.model, SERIES_COLORS[index % SERIES_COLORS.length]]));
  const selectedDay = hoveredDay ?? pinnedDay;
  const { total, previous } = report;
  const overview: [string, string, string | undefined, boolean][] = [
    [formatCost(total.cost), STRINGS.UsageSpent, changeText(total.cost, previous.cost), true],
    [formatTokens(tokensOf(total)), STRINGS.UsageTokens, changeText(tokensOf(total), tokensOf(previous)), true],
    [String(total.replies), STRINGS.UsageAnswers, changeText(total.replies, previous.replies), false],
    [String(total.conversations), STRINGS.UsageChats, undefined, false],
  ];
  const share = (value: number, all: number) => percentText(all > 0 ? value / all : 0);
  const allOfMetric = metricValue(total, metric);
  const chats = report.conversations
    .map((entry) => ({ entry, user: getGlobal().users.byId[buildChatId(entry.conversationId)] }))
    .filter(({ user }) => user)
    .slice(0, TOP_CHATS);

  return (
    <div className="settings-content custom-scroll" data-tau-usage="ready">
      <Island>{spans}</Island>

      <IslandTitle>{STRINGS.UsageOverview}</IslandTitle>
      <Island>
        <div className={styles.overview}>
          {overview.map(([value, title, change, isRiseBad]) => (
            <div key={title} className={styles.cell} data-tau-usage-cell={title}>
              <div className={styles.value}>
                {value}
                {change && (
                  <span className={change.startsWith('+') === isRiseBad ? styles.bad : styles.good}>
                    {` ${change}`}
                  </span>
                )}
              </div>
              <div className={styles.cellTitle}>{title}</div>
            </div>
          ))}
        </div>
      </Island>

      <IslandTitle>{STRINGS.UsageByDay}</IslandTitle>
      <Island>
        <UsageChart
          report={report}
          metric={metric}
          colors={colors}
          selectedDay={selectedDay}
          onHover={setHoveredDay}
          onPick={(index) => setPinnedDay(pinnedDay === index ? undefined : index)}
          onToggleMetric={() => setChosenMetric(metric === 'cost' ? 'tokens' : 'cost')}
        />
      </Island>

      {report.models.length > 0 && (
        <>
          <IslandTitle>{STRINGS.UsageByModel}</IslandTitle>
          <Island>
            {report.models.map((entry) => (
              <ListItem
                key={entry.model}
                narrow
                multiline
                inactive
                leftElement={<span className={styles.swatch} style={`background-color: ${colors.get(entry.model)}`} />}
                rightElement={(
                  <span className="settings-item__current-value">
                    {`${formatMetric(metricValue(entry, metric), metric)} `
                      + `(${share(metricValue(entry, metric), allOfMetric)})`}
                  </span>
                )}
              >
                <span className="title">{shortModelName(entry.model)}</span>
                <span className="subtitle">
                  {`${formatTokens(tokensOf(entry))} ${STRINGS.UsageTokensWord}, `
                    + repliesText(entry.model, entry.replies)}
                </span>
              </ListItem>
            ))}
          </Island>
          <IslandDescription>
            {`${STRINGS.UsageInput} ${formatTokens(total.input)}, `
              + `${STRINGS.UsageOutput} ${formatTokens(total.output)}, `
              + `${STRINGS.UsageCacheRead} ${formatTokens(total.cacheRead)}, `
              + `${STRINGS.UsageCacheWrite} ${formatTokens(total.cacheWrite)}.`}
          </IslandDescription>
        </>
      )}

      {chats.length > 0 && (
        <>
          <IslandTitle>{STRINGS.UsageTopChats}</IslandTitle>
          <Island>
            {chats.map(({ entry, user }) => (
              <ListItem
                key={entry.conversationId}
                className="tau-usage-chat"
                narrow
                multiline
                leftElement={<Avatar peer={user} size="small" className={styles.avatar} />}
                rightElement={(
                  <span className="settings-item__current-value">
                    {formatMetric(metricValue(entry, metric), metric)}
                  </span>
                )}
                onClick={() => getActions().openChat({ id: buildChatId(entry.conversationId) })}
              >
                <span className="title">{user.firstName}</span>
                <span className="subtitle">{answersText(entry.replies)}</span>
              </ListItem>
            ))}
          </Island>
        </>
      )}
      <IslandDescription>{STRINGS.UsageFooter}</IslandDescription>
    </div>
  );
};

type ChartProps = {
  report: UsageReport;
  metric: UsageMetric;
  colors: Map<string, string>;
  selectedDay?: number;
  onHover: (index: number | undefined) => void;
  onPick: (index: number) => void;
  onToggleMetric: NoneToVoidFunction;
};

/**
 * The days as Telegram's stacked bar chart: a bar a day, a segment a model, three grid lines with their values, the
 * first, middle and last dates under it. A day hovered or clicked shows its total and models, the others dimmed.
 */
const UsageChart = ({
  report, metric, colors, selectedDay, onHover, onPick, onToggleMetric,
}: ChartProps) => {
  const { days } = report;
  const dayValues = days.map((day) => metricValue(dayTotal(day), metric));
  const top = niceCeiling(Math.max(0, ...dayValues));
  const step = days.length ? CHART_WIDTH / days.length : CHART_WIDTH;
  const barWidth = Math.max(1, step * (days.length > 40 ? 0.8 : 0.66));
  const selected = selectedDay !== undefined ? days[selectedDay] : undefined;
  const header = selected
    ? `${dayTitle(selected.day)}: ${formatMetric(metricValue(dayTotal(selected), metric), metric)}`
    : `${formatMetric(metricValue(report.total, metric), metric)} ${STRINGS.UsageIn} ${days.length} `
      + STRINGS.UsageDaysWord;
  const legend = selected
    ? report.models.filter((each) => selected.models[each.model])
      .map((each) => [each.model, metricValue(selected.models[each.model], metric)] as const)
    : report.models.map((each) => [each.model, metricValue(each, metric)] as const);
  const marks = [...new Set([0, Math.floor(days.length / 2), days.length - 1])].filter((index) => index >= 0);

  const indexAt = (e: React.MouseEvent<SVGSVGElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * CHART_WIDTH;
    return Math.max(0, Math.min(days.length - 1, Math.floor(x / step)));
  };

  return (
    <div className={styles.chart} data-tau-usage-chart>
      <div className={styles.chartHeader}>
        <span className={styles.chartTitle}>{header}</span>
        <button type="button" className={styles.metric} onClick={onToggleMetric}>
          {metric === 'cost' ? STRINGS.UsageTokens : STRINGS.UsageCost}
        </button>
      </div>
      <div className={styles.plot}>
        {[1, 0.5, 0].map((fraction) => (
          <div key={fraction} className={styles.grid} style={`bottom: ${fraction * 100}%`}>
            {top > 0 && <span>{formatMetric(top * fraction, metric)}</span>}
          </div>
        ))}
        <svg
          viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}
          preserveAspectRatio="none"
          className={styles.bars}
          onMouseMove={(e) => days.length && onHover(indexAt(e))}
          onMouseLeave={() => onHover(undefined)}
          onClick={(e) => days.length && onPick(indexAt(e))}
        >
          {top > 0 && days.map((day, index) => {
            let y = CHART_HEIGHT;
            const x = step * index + (step - barWidth) / 2;
            const isDimmed = selectedDay !== undefined && selectedDay !== index;
            return report.models.map((each) => {
              const totals = day.models[each.model];
              const height = totals ? (CHART_HEIGHT * metricValue(totals, metric)) / top : 0;
              if (!(height > 0)) return undefined;
              y -= height;
              return (
                <rect
                  key={`${day.day} ${each.model}`}
                  x={x}
                  y={y}
                  width={barWidth}
                  height={height}
                  fill={colors.get(each.model)}
                  opacity={isDimmed ? 0.35 : 1}
                />
              );
            });
          })}
        </svg>
      </div>
      <div className={styles.dates}>
        {marks.map((index) => (
          <span key={index} style={`left: ${((index + 0.5) / days.length) * 100}%`}>{dayTitle(days[index].day)}</span>
        ))}
      </div>
      <div className={styles.legend}>
        {legend.map(([model, value]) => (
          <span key={model}>
            <span style={`color: ${colors.get(model)}`}>{'\u25CF '}</span>
            {`${shortModelName(model)} ${formatMetric(value, metric)}`}
          </span>
        ))}
      </div>
    </div>
  );
};

export default memo(UsageSettings);
