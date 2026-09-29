import type {
  AuthorizeData,
  LoginData,
  MessageData,
  PasskeysData,
  SecurityData,
  SessionsData,
  SignupData,
} from "../bootstrap";

const common = {
  csrf: "test-csrf-token",
  error: "",
  notice: "",
  service: "pds.example.com",
};

export const loginFixture: LoginData = {
  ...common,
  screen: "login",
  title: "Sign in",
  identifier: "",
  passkeysEnabled: true,
  showTwoFactor: false,
  signupEnabled: true,
  client: null,
};

export const signupFixture: SignupData = {
  ...common,
  screen: "signup",
  title: "Create an account",
  view: null,
  handle: "",
  email: "",
  handleDomains: [".example.com"],
  inviteRequired: false,
  customDomainEnabled: false,
  reservation: null,
  client: null,
};

export const authorizeFixture: AuthorizeData = {
  ...common,
  screen: "authorize",
  title: "Authorize",
  view: "view-token",
  account: { did: "did:plc:alice", handle: "alice.example.com" },
  client: { id: "https://app.example.com/client-metadata.json", name: "app.example.com" },
  permissions: [
    {
      field: "permission_0",
      scope: "include:app.bsky.default",
      kind: "set",
      title: "Create posts",
      detail: "Write posts on your behalf",
      includes: ["app.bsky.feed.post"],
      checked: true,
    },
    {
      field: "permission_1",
      scope: "blob:*/*",
      kind: "scope",
      title: "Upload media",
      detail: "",
      includes: [],
      checked: true,
    },
    {
      field: "permission_2",
      scope: "transition:email",
      kind: "scope",
      title: "Read your email address",
      detail: "",
      includes: [],
      checked: false,
    },
  ],
};

export const sessionsFixture: SessionsData = {
  ...common,
  screen: "sessions",
  title: "Connected applications",
  sessions: [
    {
      id: "session-1",
      clientId: "https://app.example.com/client-metadata.json",
      scope: "atproto transition:generic",
      expiresAt: 1800000000,
    },
  ],
  cursor: null,
};

export const securityFixture: SecurityData = {
  ...common,
  screen: "security",
  title: "Account security",
  state: "disabled",
  recoveryRemaining: 0,
  secret: null,
  uri: null,
  recoveryCodes: null,
};

export const passkeysFixture: PasskeysData = {
  ...common,
  screen: "passkeys",
  title: "Passkeys",
  passkeys: [
    {
      id: "passkey-1",
      name: "Personal laptop",
      createdAt: "2026-01-02T03:04:05Z",
      lastUsedAt: null,
    },
  ],
  ceremony: null,
  enabled: true,
};

export const messageFixture: MessageData = {
  ...common,
  screen: "message",
  title: "Atoll account",
  text: "authorize_request_invalid",
  error: "authorize_request_invalid",
  link: { href: "/account/login", label: "signIn" },
};
