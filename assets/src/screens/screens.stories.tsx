import type { Meta, StoryObj } from "@storybook/react-vite";
import { QueryClient } from "@tanstack/react-query";
import { App } from "../App";
import type { Bootstrap } from "../bootstrap";
import {
  authorizeFixture,
  loginFixture,
  messageFixture,
  passkeysFixture,
  securityFixture,
  sessionsFixture,
  signupFixture,
} from "../test/fixtures";

const meta = {
  title: "Screens",
  component: App,
  render: (args: { data: Bootstrap }) => (
    <App data={args.data} client={new QueryClient({ defaultOptions: { queries: { retry: false } } })} />
  ),
} satisfies Meta<{ data: Bootstrap }>;

export default meta;

type Story = StoryObj<typeof meta>;

export const Login: Story = { args: { data: loginFixture } };

export const LoginFromApplication: Story = {
  args: {
    data: {
      ...loginFixture,
      identifier: "alice.example.com",
      client: { id: "https://app.example.com/client-metadata.json", name: "app.example.com" },
    },
  },
};

export const LoginWithError: Story = {
  args: { data: { ...loginFixture, error: "invalid_credentials", showTwoFactor: true } },
};

export const Signup: Story = { args: { data: signupFixture } };

export const SignupWithInvite: Story = {
  args: { data: { ...signupFixture, inviteRequired: true, customDomainEnabled: true } },
};

export const Authorize: Story = { args: { data: authorizeFixture } };

export const AuthorizeManyPermissions: Story = {
  args: {
    data: {
      ...authorizeFixture,
      permissions: [
        "Create and delete posts",
        "Upload images and video",
        "Read your email address",
        "Follow and unfollow accounts",
        "Like and unlike posts",
        "Manage your lists",
        "Send direct messages",
        "Read your preferences",
        "Write your preferences",
        "Manage your feeds",
        "Mute and unmute accounts",
        "Block and unblock accounts",
      ].map((title, index) => ({
        field: `permission_${index}`,
        scope: index < 3 ? `include:app.bsky.set.${index}` : `repo:app.bsky.example.${index}`,
        kind: (index < 3 ? "set" : "scope") as "set" | "scope",
        title,
        detail: "This permission set can change over time within its namespace.",
        includes: ["app.bsky.example.read", "app.bsky.example.write"],
        checked: index % 3 !== 2,
      })),
    },
  },
};

export const Sessions: Story = { args: { data: sessionsFixture } };

export const Security: Story = { args: { data: securityFixture } };

export const SecurityEnabled: Story = {
  args: {
    data: {
      ...securityFixture,
      state: "enabled",
      recoveryRemaining: 8,
      recoveryCodes: ["ABCD-2345-EFGH", "IJKL-6789-MNPQ"],
    },
  },
};

export const Passkeys: Story = { args: { data: passkeysFixture } };

export const Message: Story = { args: { data: messageFixture } };
