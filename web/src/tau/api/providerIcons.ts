// Model providers' logos on their colors (docs/accounts.md; iOS's ProviderIcon.swift, the same logos and colors): the
// avatars of their accounts. The logos are LobeHub's (scripts/provider-icons.py); a provider without one has its initial.

const LOGOS = import.meta.glob<string>('../assets/providers/*.svg', { eager: true, import: 'default' });

export type ProviderLook = {
  logo: string;
  background: string;
  // The logo's color, which a one-color logo is drawn in; undefined for a logo in its own colors
  foreground?: string;
};

const WHITE = '#FFFFFF';
const BLACK = '#000000';

function look(asset: string, background: string, foreground: string | undefined = WHITE) {
  return { asset, background, foreground };
}

const KIMI = look('kimi', BLACK);
const MINIMAX = look('minimax', '#E73562');
const ZAI = look('zai', BLACK);
const QWEN = look('qwen', '#615CED');
const XIAOMI = look('xiaomimimo', '#FF6900');
const CLOUDFLARE = look('cloudflare', '#F38020');
const OPENCODE = look('opencode', BLACK);

const LOOKS: Record<string, { asset: string; background: string; foreground?: string }> = {
  anthropic: look('claude-color', '#F4F1EA', undefined),
  openai: look('openai', BLACK),
  'openai-codex': look('openai', BLACK),
  'github-copilot': look('githubcopilot', BLACK),
  google: look('gemini-color', WHITE, undefined),
  'google-vertex': look('vertexai', '#4285F4'),
  xai: look('xai', BLACK),
  deepseek: look('deepseek', '#4D6BFE'),
  mistral: look('mistral', '#FA520F'),
  moonshotai: KIMI,
  'moonshotai-cn': KIMI,
  'kimi-coding': KIMI,
  openrouter: look('openrouter', '#6467F2'),
  fireworks: look('fireworks', '#5019C5'),
  groq: look('groq', '#F55036'),
  together: look('together', '#0F6FFF'),
  cerebras: look('cerebras', '#F15A29'),
  meta: look('meta', '#0668E1'),
  minimax: MINIMAX,
  'minimax-cn': MINIMAX,
  zai: ZAI,
  'zai-coding-cn': ZAI,
  nvidia: look('nvidia', '#76B900'),
  huggingface: look('huggingface', '#FFD21E', BLACK),
  'amazon-bedrock': look('bedrock', '#01A88D'),
  azure: look('azure', '#0078D4'),
  'cloudflare-ai-gateway': CLOUDFLARE,
  'cloudflare-workers-ai': CLOUDFLARE,
  'vercel-ai-gateway': look('vercel', BLACK),
  'qwen-token-plan': QWEN,
  'qwen-token-plan-cn': QWEN,
  'qwen-token-plan-individual': QWEN,
  'qwen-token-plan-individual-cn': QWEN,
  xiaomi: XIAOMI,
  'xiaomi-token-plan-ams': XIAOMI,
  'xiaomi-token-plan-cn': XIAOMI,
  'xiaomi-token-plan-sgp': XIAOMI,
  baseten: look('baseten', BLACK),
  opencode: OPENCODE,
  'opencode-go': OPENCODE,
};

/** The provider's logo and colors; undefined for one without a logo */
export function providerLook(provider: string): ProviderLook | undefined {
  const found = LOOKS[provider];
  const logo = found && LOGOS[`../assets/providers/${found.asset}.svg`];
  if (!found || !logo) return undefined;
  return { logo, background: found.background, foreground: found.foreground };
}
