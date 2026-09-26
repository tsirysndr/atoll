// Served locally under a script-src 'self' CSP; no network calls or inline code.
(() => {
  const form = document.querySelector('[data-passkey-ceremony]');
  if (!form) return;
  const button = form.querySelector('button');
  const status = document.getElementById('passkey-status');
  const decode = value => Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
  const encode = value => btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  if (!window.isSecureContext || !window.PublicKeyCredential || !navigator.credentials) {
    status.textContent = 'Passkeys are unavailable in this browser. Use your password to sign in.';
    button.disabled = true;
    return;
  }
  button.addEventListener('click', async () => {
    button.disabled = true;
    status.textContent = 'Follow your device’s instructions.';
    try {
      const registering = form.dataset.passkeyCeremony === 'register';
      const publicKey = JSON.parse(form.dataset.publicKey);
      publicKey.challenge = decode(publicKey.challenge);
      if (registering) {
        publicKey.user.id = decode(publicKey.user.id);
        publicKey.excludeCredentials = publicKey.excludeCredentials.map(item => ({...item, id: decode(item.id)}));
      }
      const credential = registering
        ? await navigator.credentials.create({publicKey})
        : await navigator.credentials.get({publicKey});
      if (!credential) throw new Error('No credential');
      const response = {clientDataJSON: encode(credential.response.clientDataJSON)};
      if (registering) {
        response.attestationObject = encode(credential.response.attestationObject);
      } else {
        response.authenticatorData = encode(credential.response.authenticatorData);
        response.signature = encode(credential.response.signature);
        response.userHandle = credential.response.userHandle ? encode(credential.response.userHandle) : null;
      }
      form.elements.credential.value = JSON.stringify({
        id: credential.id, rawId: encode(credential.rawId), type: credential.type, response,
      });
      form.requestSubmit();
    } catch (error) {
      status.textContent = error.name === 'InvalidStateError'
        ? 'This passkey is already registered. Use another authenticator or return to your account.'
        : 'The passkey request was cancelled or could not complete. Try again, or use your password.';
      button.disabled = false;
    }
  });
})();
