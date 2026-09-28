import type { Ceremony } from "./bootstrap";

const decode = (value: string) =>
  Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));

const encode = (value: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(value)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");

export function passkeysSupported(): boolean {
  return Boolean(
    typeof window !== "undefined" &&
      window.isSecureContext &&
      window.PublicKeyCredential &&
      navigator.credentials,
  );
}

export async function runCeremony(ceremony: Ceremony): Promise<string> {
  const registering = ceremony.kind === "register";
  const publicKey = structuredClone(ceremony.publicKey) as Record<string, unknown> & {
    challenge: unknown;
    user?: { id: unknown };
    excludeCredentials?: { id: unknown }[];
  };

  publicKey.challenge = decode(publicKey.challenge as string);

  if (registering && publicKey.user) {
    publicKey.user.id = decode(publicKey.user.id as string);
    publicKey.excludeCredentials = (publicKey.excludeCredentials ?? []).map((item) => ({
      ...item,
      id: decode(item.id as string),
    }));
  }

  const options = publicKey as unknown as PublicKeyCredentialCreationOptions &
    PublicKeyCredentialRequestOptions;

  const credential = (await (registering
    ? navigator.credentials.create({ publicKey: options })
    : navigator.credentials.get({ publicKey: options }))) as PublicKeyCredential | null;

  if (!credential) throw new Error("No credential");

  const response: Record<string, string | null> = {
    clientDataJSON: encode(credential.response.clientDataJSON),
  };

  if (registering) {
    const attestation = credential.response as AuthenticatorAttestationResponse;
    response.attestationObject = encode(attestation.attestationObject);
  } else {
    const assertion = credential.response as AuthenticatorAssertionResponse;
    response.authenticatorData = encode(assertion.authenticatorData);
    response.signature = encode(assertion.signature);
    response.userHandle = assertion.userHandle ? encode(assertion.userHandle) : null;
  }

  return JSON.stringify({
    id: credential.id,
    rawId: encode(credential.rawId),
    type: credential.type,
    response,
  });
}

export function ceremonyError(error: unknown): string {
  return error instanceof Error && error.name === "InvalidStateError"
    ? "This passkey is already registered. Use another authenticator or return to your account."
    : "The passkey request was cancelled or could not complete. Try again, or use your password.";
}
