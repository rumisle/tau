# Model catalogs

The server's model list comes from pi-ai's built-in providers, overlaid with newer provider catalogs from pi.dev.
A newly published model does not require rebuilding or restarting tau. Credentials still decide which providers'
models are available; catalog discovery alone does not prove an account can run a model.

`server/src/model-catalog.ts` wraps static providers, preserving their auth, streaming and model filters. Providers
with native discovery keep it. Remote models override matching built-ins by model type and ID, and built-ins missing
from the remote list remain as fallbacks. The overlay includes chat, image and classifier models, not just what the
picker displays. A remote catalog older than the model data shipped with pi is not applied.

## When updates happen

- Before resuming conversations, restore the last good catalog from disk without network requests.
- After startup, check catalogs in the background; a successful check less than four hours old can be reused.
- Every four hours, check again in the background, using ETag revalidation where available.
- When a user's search has no matches, the picker asks `models.list` with `query`. The server checks its current
  models first and, only on a miss, refreshes and returns the list again. Miss-triggered checks bypass the four-hour
  freshness window, but are limited to one per minute across clients.

Opening the picker reads the server's local list; it does not trigger an upstream refresh. Both clients debounce
empty-result searches, avoid repeating the same query within a picker, and ignore results from an abandoned search.
Concurrent checks share one operation. Each HTTP request has a four-second deadline; an entire refresh is bounded to
15 seconds. Closing the host cancels outstanding requests and the interval.

## Cache and failures

For `tau.db`, the cache is `tau.models/` beside it, one JSON file per provider, written atomically with owner-only
permissions. A memory host keeps it in memory. The files contain model metadata and HTTP validators, not credentials.
Catalog requests go to public pi.dev endpoints without provider login cookies or API keys; expired OAuth credentials
are not refreshed to fetch a catalog.

A network failure, timeout or malformed response leaves the last good cache and built-ins usable. An unavailable
provider shard (404/501) keeps the built-ins and is checked again later. Failures are logged rather than interrupting
a conversation. This is separate from an inference request failing because an account lacks access to a model.

Tests use an injected fetcher and fake clock; no model invocation is needed. `HostOptions.modelCatalog: false` skips
the remote overlay and background loop for test hosts.
