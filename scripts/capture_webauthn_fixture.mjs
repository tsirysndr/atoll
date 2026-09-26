// Optional fixture regeneration: Node 22+ and Chrome/Chromium, no npm packages.
// Uses a new temporary profile and synthetic CTAP2 credential, never user data.
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';

const binary = process.env.CHROME_BIN || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  : 'chromium');
const profile = await mkdtemp(join(tmpdir(), 'atoll-webauthn-'));
const server = createServer((_req, res) => {
  res.writeHead(200, {'content-type': 'text/html'});
  res.end('<!doctype html><title>Atoll synthetic WebAuthn fixture</title>');
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const origin = `http://localhost:${server.address().port}`;
const browser = spawn(binary, ['--headless', '--disable-gpu', '--no-first-run',
  '--disable-background-networking', '--disable-component-update',
  '--no-default-browser-check', '--password-store=basic', '--use-mock-keychain',
  `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], {stdio: 'ignore'});
let launchError;
browser.on('error', error => { launchError = error; });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let socket;
try {
  let port;
  for (let i = 0; i < 300; i++) {
    if (launchError) throw launchError;
    try { port = Number((await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]); break; }
    catch { await pause(100); }
  }
  if (!port) throw Error('Chrome did not expose its debugging port within 30 seconds');
  const target = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {method: 'PUT'}).then(r => r.json());
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  let id = 0;
  const pending = new Map();
  let loaded;
  socket.onmessage = ({data}) => {
    const message = JSON.parse(data);
    if (message.id) {
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (request) { clearTimeout(request.timer); message.error ? request.reject(message.error) : request.resolve(message.result); }
    } else if (message.method === 'Page.loadEventFired') loaded?.();
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const n = ++id;
    const timer = setTimeout(() => { pending.delete(n); reject(Error(`Timed out: ${method}`)); }, 30000);
    pending.set(n, {resolve, reject, timer});
    socket.send(JSON.stringify({id: n, method, params}));
  });
  const version = await call('Browser.getVersion');
  await call('Page.enable');
  await call('WebAuthn.enable');
  await call('WebAuthn.addVirtualAuthenticator', {options: {
    protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true,
  }});
  const load = new Promise(resolve => { loaded = resolve; });
  await call('Page.navigate', {url: origin});
  let timer;
  try { await Promise.race([load, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Page load timeout')), 10000); })]); }
  finally { clearTimeout(timer); }
  const result = await call('Runtime.evaluate', {awaitPromise: true, returnByValue: true, expression: `(async () => {
    const encode = x => btoa(String.fromCharCode(...new Uint8Array(x))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
    const registrationChallenge = crypto.getRandomValues(new Uint8Array(32));
    const loginChallenge = crypto.getRandomValues(new Uint8Array(32));
    const user = crypto.getRandomValues(new Uint8Array(32));
    const registration = await navigator.credentials.create({publicKey: {
      challenge: registrationChallenge, rp: {name: 'Atoll fixture', id: 'localhost'},
      user: {id: user, name: 'fixture', displayName: 'Test fixture'},
      pubKeyCredParams: [{type: 'public-key', alg: -7}],
      authenticatorSelection: {residentKey: 'required', userVerification: 'required'},
      attestation: 'none', timeout: 20000,
    }});
    const assertion = await navigator.credentials.get({publicKey: {
      challenge: loginChallenge, rpId: 'localhost', userVerification: 'required', timeout: 20000,
    }});
    return {origin: location.origin, registrationChallenge: encode(registrationChallenge),
      loginChallenge: encode(loginChallenge), userHandle: encode(user),
      registration: registration.toJSON(), assertion: assertion.toJSON()};
  })()`});
  if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
  const fixture = {
    source: `${version.product} CTAP2 virtual authenticator; synthetic credential, no real account`,
    ...result.result.value,
  };
  await writeFile(new URL('../test/fixtures/webauthn_chrome.json', import.meta.url), JSON.stringify(fixture, null, 2) + '\n');
  console.log('Captured synthetic WebAuthn registration and assertion. Run mix test test/atoll/web_authn_test.exs.');
} finally {
  socket?.close();
  if (browser.pid && browser.exitCode === null && browser.signalCode === null) {
    const exited = once(browser, 'exit');
    browser.kill('SIGTERM');
    const force = setTimeout(() => browser.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(force);
  }
  server.close();
  await rm(profile, {recursive: true, force: true});
}
