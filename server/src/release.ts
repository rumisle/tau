// The entry of a release's bundle (scripts/build-release.sh). pi-ai loads its OAuth flows (token refresh) through a
// specifier bundlers cannot follow; registered here, they are in the bundle instead.
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";

registerBunOAuthFlows();
await import("./main.ts");
