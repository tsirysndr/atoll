import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Snippet } from "@heroui/react";
import { useTranslation } from "react-i18next";
import { IconAt, IconCheck, IconLock, IconWorld, IconX } from "@tabler/icons-react";
import type { SignupData } from "../bootstrap";
import { signupSchema, type SignupValues } from "../schemas";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { ClientPanel } from "../components/ClientPanel";
import { TextField, PasswordField } from "../components/Field";
import { ServerForm, useServerForm } from "../components/ServerForm";
import { SubmitButton } from "../components/SubmitButton";
import { useHandleAvailability, useServerDescription } from "../api";
import { errorMessage } from "../i18n";

function useDebounced(value: string, delay = 400) {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debounced;
}

export function SignupScreen({ data }: { data: SignupData }) {
  const { t } = useTranslation();
  const description = useServerDescription();

  const form = useForm<SignupValues>({
    resolver: zodResolver(signupSchema),
    mode: "onSubmit",
    defaultValues: {
      handle: data.handle,
      email: data.email,
      password: "",
      confirmPassword: "",
      inviteCode: "",
    },
  });

  const api = useServerForm(form);
  const handle = form.watch("handle");
  const debouncedHandle = useDebounced(handle ?? "");
  const availability = useHandleAvailability(debouncedHandle, debouncedHandle.length > 3);

  const domains = data.handleDomains.length
    ? data.handleDomains
    : (description.data?.availableUserDomains ?? []);
  const inviteRequired = data.inviteRequired || Boolean(description.data?.inviteCodeRequired);

  const availabilityHint =
    availability.data === "available" ? (
      <span className="flex items-center gap-1 text-success-600">
        <IconCheck size={14} stroke={2} aria-hidden />
        {t("signup.handleAvailable")}
      </span>
    ) : availability.data === "taken" ? (
      <span className="flex items-center gap-1 text-danger-500">
        <IconX size={14} stroke={2} aria-hidden />
        {t("signup.handleTaken")}
      </span>
    ) : (
      t("signup.handleHint", { domain: domains[0] ?? ".example.com" })
    );

  return (
    <AuthCard
      title={t("signup.title")}
      service={data.service}
      subtitle={data.client ? t("signup.forClient") : t("signup.subtitle")}
    >
      {data.client ? <ClientPanel client={data.client} /> : null}

      <Alert>{errorMessage(data.error, t)}</Alert>

      {data.reservation ? (
        <section className="flex flex-col gap-3 rounded-xl border border-default-200 bg-default-50/60 p-4 text-sm">
          <h2 className="flex items-center gap-2 font-semibold">
            <IconWorld size={18} stroke={1.75} aria-hidden />
            {t("signup.reservationTitle")}
          </h2>
          <p className="text-default-500">
            {t("signup.reservationDid", { did: data.reservation.did })}
          </p>
          <Snippet size="sm" radius="sm" hideSymbol className="w-full">
            {`${data.reservation.dnsName} TXT ${data.reservation.dnsValue}`}
          </Snippet>
          <p className="text-xs text-default-500">
            {t("signup.reservationDns", {
              name: data.reservation.dnsName,
              value: data.reservation.dnsValue,
              url: data.reservation.httpsUrl,
            })}
          </p>
          <p className="text-xs text-default-500">{t("signup.reservationNext")}</p>
        </section>
      ) : null}

      <ServerForm
        action="/account/signup"
        csrf={data.csrf}
        api={api}
        hidden={{ view: data.view }}
      >
        <TextField
          label={t("signup.handle")}
          placeholder={`alice${domains[0] ?? ".example.com"}`}
          description={availabilityHint}
          registration={form.register("handle")}
          error={form.formState.errors.handle}
          startContent={<IconAt size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="username"
          autoFocus={!data.handle}
          maxLength={253}
        />

        <TextField
          label={t("signup.email")}
          description={t("signup.emailOptional")}
          registration={form.register("email")}
          error={form.formState.errors.email}
          type="email"
          autoComplete="email"
          inputMode="email"
          maxLength={320}
          isRequired={false}
        />

        <PasswordField
          label={t("signup.password")}
          description={t("signup.passwordHint")}
          registration={form.register("password")}
          error={form.formState.errors.password}
          startContent={<IconLock size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="new-password"
          maxLength={1024}
        />

        <PasswordField
          label={t("signup.confirmPassword")}
          registration={form.register("confirmPassword")}
          error={form.formState.errors.confirmPassword}
          startContent={<IconLock size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="new-password"
          maxLength={1024}
        />

        {inviteRequired ? (
          <TextField
            label={t("signup.invite")}
            registration={form.register("inviteCode")}
            error={form.formState.errors.inviteCode}
            maxLength={256}
          />
        ) : null}

        <p className="text-xs text-default-500">{t("signup.keepPassword")}</p>

        <SubmitButton
          color="primary"
          size="lg"
          className="font-medium"
          isLoading={api.submitting}
          onPress={() => api.submitWith("action", "create")}
        >
          {t("common.createAccount")}
        </SubmitButton>

        {data.customDomainEnabled ? (
          <>
            <p className="text-xs text-default-500">{t("signup.customDomain")}</p>
            <SubmitButton
              variant="bordered"
              size="lg"
              isLoading={api.submitting}
              onPress={() => api.submitWith("action", "reserve_custom")}
            >
              {t("signup.reserveCustom")}
            </SubmitButton>
          </>
        ) : null}
      </ServerForm>

      <p className="text-center text-sm text-default-500">
        {t("signup.haveAccount")}{" "}
        <a href="/account/login" className="font-medium text-primary hover:underline">
          {t("common.signIn")}
        </a>
      </p>
    </AuthCard>
  );
}
