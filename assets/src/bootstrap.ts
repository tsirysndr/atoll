export type Client = {
  id: string;
  name: string;
};

export type Account = {
  did: string;
  handle: string | null;
};

export type Permission = {
  field: string;
  scope: string;
  kind: "set" | "scope";
  title: string;
  detail: string;
  includes: string[];
  checked: boolean;
};

export type OAuthSession = {
  id: string;
  clientId: string;
  scope: string;
  expiresAt: number;
};

export type Passkey = {
  id: string;
  name: string;
  createdAt: string | null;
  lastUsedAt: string | null;
};

export type Ceremony = {
  kind: "register" | "login";
  action: string;
  publicKey: Record<string, unknown>;
};

export type Reservation = {
  did: string;
  handle: string;
  dnsName: string;
  dnsValue: string;
  httpsUrl: string;
};

type Common = {
  csrf: string;
  title: string;
  error: string;
  notice: string;
  service: string;
};

export type LoginData = Common & {
  screen: "login";
  identifier: string;
  passkeysEnabled: boolean;
  showTwoFactor: boolean;
  signupEnabled: boolean;
  client: Client | null;
};

export type SignupData = Common & {
  screen: "signup";
  view: string | null;
  handle: string;
  email: string;
  handleDomains: string[];
  inviteRequired: boolean;
  customDomainEnabled: boolean;
  reservation: Reservation | null;
  client: Client | null;
};

export type AuthorizeData = Common & {
  screen: "authorize";
  view: string;
  account: Account;
  client: Client;
  permissions: Permission[];
};

export type SessionsData = Common & {
  screen: "sessions";
  sessions: OAuthSession[];
  cursor: string | null;
};

export type SecurityData = Common & {
  screen: "security";
  state: "disabled" | "pending" | "enabled";
  recoveryRemaining: number;
  secret: string | null;
  recoveryCodes: string[] | null;
};

export type PasskeysData = Common & {
  screen: "passkeys";
  passkeys: Passkey[];
  ceremony: Ceremony | null;
  enabled: boolean;
};

export type MessageData = Common & {
  screen: "message";
  text: string;
  link: { href: string; label: string } | null;
};

export type Bootstrap =
  | LoginData
  | SignupData
  | AuthorizeData
  | SessionsData
  | SecurityData
  | PasskeysData
  | MessageData;

declare global {
  interface Window {
    __ATOLL__?: Bootstrap;
  }
}

export const BOOTSTRAP_ELEMENT_ID = "atoll-bootstrap";

export function readBootstrap(source: Window = window): Bootstrap {
  const element = source.document?.getElementById(BOOTSTRAP_ELEMENT_ID);
  let data: Bootstrap | undefined;

  if (element?.textContent) {
    try {
      data = JSON.parse(element.textContent) as Bootstrap;
    } catch {
      data = undefined;
    }
  }

  data ??= source.__ATOLL__;

  if (!data) {
    return {
      screen: "message",
      csrf: "",
      title: "Atoll account",
      error: "",
      notice: "",
      service: "",
      text: "This page could not load. Reload and try again.",
      link: { href: "/account/login", label: "Sign in" },
    };
  }

  return data;
}
