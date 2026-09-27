// Optional browser integration: run via passkey_browser_e2e_test.exs. Node 22+ and Chrome.
// Uses a new temporary profile and synthetic CTAP2 credential, never user data.
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';

const binary = process.env.CHROME_BIN || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  : 'chromium');
const profile = await mkdtemp(join(tmpdir(), 'atoll-webauthn-'));
const [origin, did, password] = process.argv.slice(2);
if (!origin || !did || !password || new URL(origin).hostname !== 'localhost') {
  throw Error('Run through the synthetic local ExUnit browser test');
}
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
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true, userGesture: true});
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const navigate = async action => {
    let timer;
    const load = new Promise(resolve => { loaded = resolve; });
    try {
      await action();
      await Promise.race([load, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Navigation timed out')), 10000); })]);
    } finally { clearTimeout(timer); }
  };
  const visit = path => navigate(() => call('Page.navigate', {url: origin + path}));
  const submit = (path, values = {}) => navigate(() => evaluate(`(() => {
    const form = document.querySelector('form[action="' + ${JSON.stringify(path)} + '"]');
    if (!form) throw Error('Missing form: ' + ${JSON.stringify(path)});
    for (const [key, value] of Object.entries(${JSON.stringify(values)})) form.elements.namedItem(key).value = value;
    form.requestSubmit();
  })()`));
  const assertPage = async text => {
    const content = await evaluate('document.body.innerText');
    if (!content.includes(text)) throw Error('Expected ' + text + '; received: ' + content);
  };
  await visit('/account/login');
  await submit('/account/login', {identifier: did, password});
  await assertPage('Connected applications');
  await visit('/account/security');
  await assertPage('Manage passkeys');
  await visit('/account/passkeys');
  await assertPage('You have no passkeys yet');
  await submit('/account/passkeys/register/begin', {name: 'Virtual test key', password});
  await assertPage('Save your passkey');
  for (const [name, width, height, mobile, dark] of [['desktop', 1280, 900, false, false], ['mobile', 390, 844, true, false], ['dark', 1280, 900, false, true]]) {
    await call('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 1, mobile});
    await call('Emulation.setEmulatedMedia', {features: [{name: 'prefers-color-scheme', value: dark ? 'dark' : 'light'}]});
    const dimensions = await evaluate('({width: innerWidth, content: document.documentElement.scrollWidth})');
    if (dimensions.content > dimensions.width) throw Error('Horizontal overflow on ' + name);
    const screenshot = await call('Page.captureScreenshot', {format: 'png'});
    await writeFile(join(tmpdir(), 'atoll-passkey-' + name + '.png'), Buffer.from(screenshot.data, 'base64'));
  }
  await navigate(() => evaluate('document.querySelector("[data-passkey-ceremony] button").click()'));
  await assertPage('Virtual test key');
  await visit('/account/sessions');
  await submit('/account/logout');
  await assertPage('Sign in');
  await submit('/account/passkeys/login/begin');
  await assertPage('Sign in with a passkey');
  await evaluate(`(async () => {
    const original = navigator.credentials.get.bind(navigator.credentials);
    try {
      navigator.credentials.get = async () => { throw new DOMException('Cancelled', 'NotAllowedError'); };
      document.querySelector('[data-passkey-ceremony] button').click();
      await new Promise(queueMicrotask);
      if (document.querySelector('[data-passkey-ceremony] button').disabled) throw Error('Retry is disabled');
    } finally { navigator.credentials.get = original; }
  })()`);
  await assertPage('was cancelled');
  await navigate(() => evaluate('document.querySelector("[data-passkey-ceremony] button").click()'));
  await assertPage('Connected applications');
  await visit('/account/passkeys');
  await submit('/account/passkeys/revoke', {password});
  await assertPage('Enter your account credentials');
  await submit('/account/login', {identifier: did, password});
  await assertPage('Connected applications');
  await visit('/account/passkeys');
  await assertPage('You have no passkeys yet');
  console.log('Passkey browser flow passed with ' + version.product);

} finally {
  socket?.close();
  if (browser.pid && browser.exitCode === null && browser.signalCode === null) {
    const exited = once(browser, 'exit');
    browser.kill('SIGTERM');
    const force = setTimeout(() => browser.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(force);
  }
  // Chrome helpers can finish writing the profile after the main process exits.
  // Retry transient ENOTEMPTY/EBUSY failures, but still fail if cleanup cannot finish.
  await rm(profile, {recursive: true, force: true, maxRetries: 10, retryDelay: 100});
}
