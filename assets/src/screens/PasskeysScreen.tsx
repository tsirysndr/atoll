import { useEffect, useRef } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Button } from "@heroui/react";
import { useAtom } from "jotai";
import { useTranslation } from "react-i18next";
import { IconFingerprint, IconTrash } from "@tabler/icons-react";
import type { Ceremony, PasskeysData } from "../bootstrap";
import { passkeyNameSchema, type PasskeyNameValues } from "../schemas";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { PasswordField, TextField } from "../components/Field";
import { ServerForm, useServerForm } from "../components/ServerForm";
import { SubmitButton } from "../components/SubmitButton";
import { passkeyStatusAtom } from "../atoms";
import { ceremonyError, passkeysSupported, runCeremony } from "../passkeys";
import { errorMessage } from "../i18n";

function CeremonyPanel({ ceremony, csrf }: { ceremony: Ceremony; csrf: string }) {
  const { t } = useTranslation();
  const [status, setStatus] = useAtom(passkeyStatusAtom);
  const formRef = useRef<HTMLFormElement>(null);
  const credentialRef = useRef<HTMLInputElement>(null);
  const supported = passkeysSupported();

  useEffect(() => {
    if (!supported) setStatus({ message: t("passkeys.unsupported"), busy: true });
  }, [supported, setStatus, t]);

  const start = async () => {
    setStatus({ message: t("passkeys.followDevice"), busy: true });

    try {
      const credential = await runCeremony(ceremony);
      if (credentialRef.current) credentialRef.current.value = credential;
      formRef.current?.submit();
    } catch (error) {
      setStatus({ message: ceremonyError(error), busy: false });
    }
  };

  return (
    <form
      ref={formRef}
      method="post"
      action={ceremony.action}
      data-passkey-ceremony={ceremony.kind}
      className="flex flex-col gap-4"
    >
      <input type="hidden" name="_csrf_token" value={csrf} />
      <input type="hidden" name="credential" ref={credentialRef} />

      <p aria-live="polite" role="status" className="text-sm text-default-500">
        {status.message}
      </p>

      <Button
        type="button"
        color="primary"
        size="lg"
        radius="sm"
        className="font-medium"
        isDisabled={!supported || status.busy}
        onPress={() => void start()}
        startContent={<IconFingerprint size={18} stroke={1.75} />}
      >
        {t("passkeys.continue")}
      </Button>
    </form>
  );
}

function EnrollForm({ csrf }: { csrf: string }) {
  const { t } = useTranslation();
  const form = useForm<PasskeyNameValues>({ resolver: zodResolver(passkeyNameSchema) });
  const api = useServerForm(form);

  return (
    <ServerForm action="/account/passkeys/register/begin" csrf={csrf} api={api}>
      <TextField
        label={t("passkeys.name")}
        placeholder={t("passkeys.namePlaceholder")}
        registration={form.register("name")}
        error={form.formState.errors.name}
        maxLength={64}
      />
      <PasswordField
        label={t("security.password")}
        registration={form.register("password")}
        error={form.formState.errors.password}
        autoComplete="current-password"
        maxLength={1024}
      />
      <TextField
        label={t("security.code")}
        registration={form.register("totpCode")}
        error={form.formState.errors.totpCode}
        autoComplete="one-time-code"
        inputMode="numeric"
        maxLength={26}
        isRequired={false}
      />
      <SubmitButton color="primary" size="lg" className="font-medium" isLoading={api.submitting}>
        {t("passkeys.add")}
      </SubmitButton>
    </ServerForm>
  );
}

export function PasskeysScreen({ data }: { data: PasskeysData }) {
  const { t, i18n } = useTranslation();

  const formatDate = (value: string | null) =>
    value
      ? new Intl.DateTimeFormat(i18n.language, { dateStyle: "medium" }).format(new Date(value))
      : null;

  if (data.ceremony) {
    return (
      <AuthCard title={data.title} service={data.service}>
        <Alert>{errorMessage(data.error, t)}</Alert>
        <CeremonyPanel ceremony={data.ceremony} csrf={data.csrf} />
        <a href="/account/passkeys" className="text-center text-sm text-primary hover:underline">
          {t("common.back")}
        </a>
      </AuthCard>
    );
  }

  return (
    <AuthCard title={t("passkeys.title")} service={data.service} width="wide">
      <Alert>{errorMessage(data.error, t)}</Alert>

      {data.passkeys.length === 0 ? (
        <p className="rounded-xl border border-dashed border-default-200 p-6 text-center text-sm text-default-500">
          {t("passkeys.empty")}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {data.passkeys.map((passkey) => (
            <li key={passkey.id} className="rounded-xl border border-default-200 p-4">
              <div className="flex items-start gap-3">
                <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand dark:bg-primary-500/15">
                  <IconFingerprint size={20} stroke={1.75} aria-hidden />
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold wrap-anywhere">{passkey.name}</p>
                  <p className="text-xs text-default-500">
                    {passkey.createdAt
                      ? t("passkeys.created", { date: formatDate(passkey.createdAt) })
                      : null}
                    {passkey.lastUsedAt
                      ? ` · ${t("passkeys.lastUsed", { date: formatDate(passkey.lastUsedAt) })}`
                      : ` · ${t("passkeys.neverUsed")}`}
                  </p>
                </div>
              </div>

              <details className="mt-3">
                <summary className="cursor-pointer text-xs font-medium text-danger">
                  {t("passkeys.remove")}
                </summary>
                <form
                  method="post"
                  action="/account/passkeys/revoke"
                  className="mt-3 flex flex-col gap-3"
                >
                  <input type="hidden" name="_csrf_token" value={data.csrf} />
                  <input type="hidden" name="id" value={passkey.id} />
                  <input
                    name="password"
                    type="password"
                    autoComplete="current-password"
                    placeholder={t("security.password")}
                    required
                    minLength={8}
                    maxLength={1024}
                    className="h-11 rounded-md border border-default-200 bg-default-50/60 px-3 text-base"
                  />
                  <input
                    name="totpCode"
                    autoComplete="one-time-code"
                    placeholder={t("security.code")}
                    maxLength={26}
                    className="h-11 rounded-md border border-default-200 bg-default-50/60 px-3 text-base"
                  />
                  <SubmitButton
                    color="danger"
                    variant="flat"
                    size="sm"
                    className="self-start"
                    startContent={<IconTrash size={16} stroke={1.75} />}
                  >
                    {t("passkeys.remove")}
                  </SubmitButton>
                </form>
              </details>
            </li>
          ))}
        </ul>
      )}

      {data.enabled ? (
        <section className="flex flex-col gap-4 border-t border-default-200 pt-5">
          <h2 className="text-sm font-semibold">{t("passkeys.add")}</h2>
          <EnrollForm csrf={data.csrf} />
        </section>
      ) : null}

      <a href="/account/security" className="text-center text-sm text-primary hover:underline">
        {t("common.back")}
      </a>
    </AuthCard>
  );
}
