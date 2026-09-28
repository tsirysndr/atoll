import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Button, Chip, Snippet } from "@heroui/react";
import { useTranslation } from "react-i18next";
import { IconFingerprint, IconShieldCheck, IconShieldOff } from "@tabler/icons-react";
import type { SecurityData } from "../bootstrap";
import {
  passwordOnlySchema,
  totpSchema,
  type PasswordOnlyValues,
  type TotpValues,
} from "../schemas";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { PasswordField, TextField } from "../components/Field";
import { ServerForm, useServerForm } from "../components/ServerForm";
import { SubmitButton } from "../components/SubmitButton";
import { errorMessage } from "../i18n";

function BeginForm({ csrf }: { csrf: string }) {
  const { t } = useTranslation();
  const form = useForm<PasswordOnlyValues>({ resolver: zodResolver(passwordOnlySchema) });
  const api = useServerForm(form);

  return (
    <ServerForm action="/account/security/begin" csrf={csrf} api={api}>
      <PasswordField
        label={t("security.password")}
        registration={form.register("password")}
        error={form.formState.errors.password}
        autoComplete="current-password"
        maxLength={1024}
      />
      <SubmitButton color="primary" size="lg" className="font-medium" isLoading={api.submitting}>
        {t("security.begin")}
      </SubmitButton>
    </ServerForm>
  );
}

function ConfirmForm({ csrf }: { csrf: string }) {
  const { t } = useTranslation();
  const form = useForm<TotpValues>({ resolver: zodResolver(totpSchema) });
  const api = useServerForm(form);

  return (
    <ServerForm action="/account/security/confirm" csrf={csrf} api={api}>
      <TextField
        label={t("security.code")}
        registration={form.register("totpCode")}
        error={form.formState.errors.totpCode}
        autoComplete="one-time-code"
        inputMode="numeric"
        maxLength={26}
        autoFocus
      />
      <SubmitButton color="primary" size="lg" className="font-medium" isLoading={api.submitting}>
        {t("security.confirm")}
      </SubmitButton>
    </ServerForm>
  );
}

function PasswordAndCodeForm({
  csrf,
  action,
  label,
  danger,
}: {
  csrf: string;
  action: string;
  label: string;
  danger?: boolean;
}) {
  const { t } = useTranslation();
  const form = useForm<PasswordOnlyValues & TotpValues>({
    resolver: zodResolver(passwordOnlySchema.merge(totpSchema)),
  });
  const api = useServerForm(form);

  return (
    <ServerForm action={action} csrf={csrf} api={api}>
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
      />
      <SubmitButton
        color={danger ? "danger" : "primary"}
        variant={danger ? "flat" : "solid"}
        size="lg"
        className="font-medium"
        isLoading={api.submitting}
      >
        {label}
      </SubmitButton>
    </ServerForm>
  );
}

export function SecurityScreen({ data }: { data: SecurityData }) {
  const { t } = useTranslation();

  const status =
    data.state === "enabled"
      ? { icon: IconShieldCheck, text: t("security.enabled"), color: "success" as const }
      : data.state === "pending"
        ? { icon: IconShieldOff, text: t("security.pending"), color: "warning" as const }
        : { icon: IconShieldOff, text: t("security.disabled"), color: "default" as const };

  const StatusIcon = status.icon;

  return (
    <AuthCard title={t("security.title")} service={data.service} width="wide">
      <Alert>{errorMessage(data.error, t)}</Alert>
      <Alert tone="info">{data.notice ? errorMessage(data.notice, t) : ""}</Alert>

      <div className="flex items-center justify-between gap-3 rounded-xl border border-default-200 p-4">
        <div className="flex items-center gap-3">
          <StatusIcon size={22} stroke={1.75} aria-hidden className="text-default-500" />
          <div>
            <p className="text-sm font-semibold">{t("security.subtitle")}</p>
            <p className="text-xs text-default-500">{status.text}</p>
          </div>
        </div>
        <Chip size="sm" variant="flat" color={status.color} radius="sm">
          {data.state === "enabled" ? t("security.enabled") : t("security.disabled")}
        </Chip>
      </div>

      {data.secret ? (
        <section className="flex flex-col gap-2">
          <p className="text-sm text-default-500">{t("security.secret")}</p>
          <Snippet size="sm" radius="sm" hideSymbol className="w-full font-mono tracking-wider">
            {data.secret}
          </Snippet>
        </section>
      ) : null}

      {data.recoveryCodes?.length ? (
        <section className="flex flex-col gap-2">
          <p className="text-sm font-medium">{t("security.recoveryCodes")}</p>
          <ul className="grid grid-cols-2 gap-2 rounded-xl bg-brand-soft p-4 font-mono text-sm text-primary-700 dark:bg-primary-500/10 dark:text-primary-200">
            {data.recoveryCodes.map((code) => (
              <li key={code} className="wrap-anywhere">
                {code}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {data.state === "enabled" ? (
        <div className="flex flex-col gap-6">
          <PasswordAndCodeForm
            csrf={data.csrf}
            action="/account/security/recovery"
            label={t("security.recovery")}
          />
          <PasswordAndCodeForm
            csrf={data.csrf}
            action="/account/security/disable"
            label={t("security.disable")}
            danger
          />
        </div>
      ) : data.state === "pending" ? (
        <ConfirmForm csrf={data.csrf} />
      ) : (
        <BeginForm csrf={data.csrf} />
      )}

      <div className="flex flex-wrap gap-3 border-t border-default-200 pt-4">
        <Button
          as="a"
          href="/account/passkeys"
          variant="bordered"
          radius="sm"
          size="sm"
          startContent={<IconFingerprint size={16} stroke={1.75} />}
        >
          {t("security.passkeys")}
        </Button>
        <Button as="a" href="/account/sessions" variant="light" radius="sm" size="sm">
          {t("common.back")}
        </Button>
      </div>
    </AuthCard>
  );
}
