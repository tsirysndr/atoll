import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Divider } from "@heroui/react";
import { useAtom } from "jotai";
import { useTranslation } from "react-i18next";
import { IconAt, IconChevronRight, IconFingerprint, IconLock } from "@tabler/icons-react";
import type { LoginData } from "../bootstrap";
import { loginSchema, type LoginValues } from "../schemas";
import { AuthCard } from "../components/AuthCard";
import { ForgotPassword } from "../components/ForgotPassword";
import { Alert } from "../components/Alert";
import { ClientPanel } from "../components/ClientPanel";
import { TextField, PasswordField } from "../components/Field";
import { ServerForm, useServerForm } from "../components/ServerForm";
import { PostForm, SubmitButton } from "../components/SubmitButton";
import { twoFactorOpenAtom } from "../atoms";
import { useServerDescription } from "../api";
import { errorMessage } from "../i18n";

export function LoginScreen({ data }: { data: LoginData }) {
  const { t } = useTranslation();
  const [open, setOpen] = useAtom(twoFactorOpenAtom);
  const description = useServerDescription();

  const form = useForm<LoginValues>({
    resolver: zodResolver(loginSchema),
    mode: "onSubmit",
    defaultValues: {
      identifier: data.identifier,
      password: "",
      authFactorToken: "",
      totpCode: "",
    },
  });

  const api = useServerForm(form);
  const showTwoFactor = open || data.showTwoFactor;
  const links = description.data?.links;
  const domain = description.data?.availableUserDomains?.[0] ?? ".example.com";

  return (
    <AuthCard
      title={t("login.title")}
      service={data.service}
      subtitle={data.client ? undefined : t("login.subtitle")}
    >
      {data.client ? <ClientPanel client={data.client} /> : null}

      <Alert>{errorMessage(data.error, t)}</Alert>

      <ServerForm action="/account/login" csrf={data.csrf} api={api}>
        <TextField
          label={t("login.identifier")}
          placeholder={t("login.identifierPlaceholder", { domain })}
          registration={form.register("identifier")}
          error={form.formState.errors.identifier}
          startContent={<IconAt size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="username"
          autoFocus={!data.identifier}
          maxLength={2048}
        />

        <PasswordField
          label={t("login.password")}
          placeholder={t("login.passwordPlaceholder")}
          registration={form.register("password")}
          error={form.formState.errors.password}
          startContent={<IconLock size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="current-password"
          autoFocus={Boolean(data.identifier)}
          maxLength={1024}
        />

        <p className="flex items-center gap-1.5 text-xs text-default-500">
          <IconLock size={14} stroke={1.75} aria-hidden />
          {t("login.trust")}
        </p>

        {showTwoFactor ? (
          <div className="flex flex-col gap-4 rounded-xl border border-default-200 p-4">
            <p className="text-sm font-medium">{t("login.twoFactor")}</p>
            <TextField
              label={t("login.emailCode")}
              description={t("login.emailCodeHint")}
              registration={form.register("authFactorToken")}
              error={form.formState.errors.authFactorToken}
              autoComplete="one-time-code"
              maxLength={32}
              isRequired={false}
              autoFocus
            />
            <TextField
              label={t("login.totpCode")}
              description={t("login.totpCodeHint")}
              registration={form.register("totpCode")}
              error={form.formState.errors.totpCode}
              autoComplete="one-time-code"
              inputMode="numeric"
              maxLength={26}
              isRequired={false}
            />
          </div>
        ) : (
          <button
            type="button"
            onClick={() => setOpen(true)}
            className="flex items-center gap-1 self-start text-sm font-medium text-primary hover:underline"
          >
            <IconChevronRight size={15} stroke={2} aria-hidden />
            {t("login.useTwoFactor")}
          </button>
        )}

        <SubmitButton
          color="primary"
          size="lg"
          className="mt-1 font-medium"
          isLoading={api.submitting}
        >
          {t("common.signIn")}
        </SubmitButton>
      </ServerForm>

      {data.passkeysEnabled ? (
        <>
          <div className="flex items-center gap-3">
            <Divider className="flex-1" />
            <span className="text-xs text-default-400">{t("common.or")}</span>
            <Divider className="flex-1" />
          </div>

          <PostForm action="/account/passkeys/login/begin" csrf={data.csrf}>
            {(submitting) => (
              <SubmitButton
                variant="bordered"
                size="lg"
                fullWidth
                isLoading={submitting}
                startContent={<IconFingerprint size={18} stroke={1.75} />}
              >
                {t("login.passkey")}
              </SubmitButton>
            )}
          </PostForm>
        </>
      ) : null}

      <ForgotPassword />

      {data.signupEnabled ? (
        <p className="text-center text-sm text-default-500">
          {t("login.noAccount")}{" "}
          <a href="/account/signup" className="font-medium text-primary hover:underline">
            {t("login.createOne")}
          </a>
        </p>
      ) : null}

      {links?.privacyPolicy || links?.termsOfService ? (
        <p className="text-center text-xs text-default-400">
          {links.termsOfService ? (
            <a href={links.termsOfService} className="hover:underline">
              {t("common.terms")}
            </a>
          ) : null}
          {links.termsOfService && links.privacyPolicy ? " · " : null}
          {links.privacyPolicy ? (
            <a href={links.privacyPolicy} className="hover:underline">
              {t("common.privacy")}
            </a>
          ) : null}
        </p>
      ) : null}
    </AuthCard>
  );
}
