// tau's own message content: what a tau row draws (src/tau/components/TauMessage.tsx). The message's `content`
// keeps a rich-message rendering of the same, for previews, copy and the typing draft's handoff.
import type { ApiPageBlock } from '../../api/types';

export type ApiTauToolStatus = 'running' | 'done' | 'failed';

export type ApiTauPart =
  | { type: 'thinking'; text: string }
  | { type: 'text'; blocks: ApiPageBlock[] }
  | {
    type: 'tool';
    id: string;
    // The card's title ("Bash", "Read") and what the call works on, after it
    title: string;
    summary?: string;
    // A command, as `$ …`, or the arguments; then the result's text
    command?: string;
    // The command's language, to color it
    language?: string;
    output?: string;
    startedAt?: number;
    status: ApiTauToolStatus;
    durationMs?: number;
  }
  | {
    type: 'subagent';
    name: string;
    // "working", "worked 5s", "answered", "failed"
    state: string;
    isFailed?: boolean;
    isWorking?: boolean;
    task: string;
    answer?: ApiPageBlock[];
  };

export interface ApiTauContent {
  role: 'assistant' | 'notice';
  parts: ApiTauPart[];
  // The last message of a run: its footer, how long the run took
  runEnd?: { workedForMs?: number };
}
