// Before Web A starts: a `#token=` link's token taken (before Web A's hash routing reads the address), and the page
// for plain HTTP away from localhost, where the app does not run (docs/web.md "Secure contexts only")
import { takeLinkToken } from './auth';

const linkToken = window.isSecureContext ? takeLinkToken() : undefined;

/** Resolves when the link's token is stored, if there was one */
export function whenLinkTokenStored() {
  return linkToken ?? Promise.resolve();
}

/** False, with a page saying how to set up HTTPS, when the page is not a secure context */
export function checkSecureContext() {
  if (window.isSecureContext) return true;
  const port = window.location.port || '80';
  document.title = 'tau needs HTTPS';
  document.body.innerHTML = '';
  const page = document.createElement('main');
  page.className = 'tau-insecure';
  page.innerHTML = `
    <h1>tau needs HTTPS here</h1>
    <p>This page came over plain HTTP from another machine. Browsers keep what the app needs (service workers,
    notifications, secure storage) to HTTPS and to localhost, so the app does not run over plain HTTP.</p>
    <p>On the machine that runs the server, with Tailscale:</p>
    <pre>tailscale serve --bg ${port}</pre>
    <p>Then open the HTTPS address it prints (https://&lt;machine&gt;.&lt;tailnet&gt;.ts.net). On the server's own
    machine, http://localhost:${port} works as it is.</p>`;
  document.body.appendChild(page);
  return false;
}
