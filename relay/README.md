# tau push relay

A Cloudflare Worker that holds the APNs key and forwards tau servers' pushes to Apple (docs/notifications.md
"Through a relay"). Answers arrive sealed by the server with the phone's key; the relay sees ciphertext.

```bash
npm install
npx wrangler deploy
npx wrangler secret put APNS_KEY        # the .p8's contents
npx wrangler secret put APNS_KEY_ID     # e.g. F878SZRDN4
npx wrangler secret put APNS_TEAM       # the team ID
npx wrangler secret put RELAY_TOKENS    # name:token per server, by line or comma (openssl rand -hex 32)
```

`TOPIC` in wrangler.toml is the app's bundle ID; pushes to any other are refused. A server then runs with
`--push-relay https://tau-push.<subdomain>.workers.dev --push-relay-token-file ~/.config/tau/relay-token`.
