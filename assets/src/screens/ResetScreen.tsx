import { useState } from "react";
import { Button } from "@heroui/react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { useTranslation } from "react-i18next";
import { IconCircleCheck, IconLock } from "@tabler/icons-react";
import type { ResetData } from "../bootstrap";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { TextField, PasswordField } from "../components/Field";

const schema = z
  .object({
    token: z.string().trim().min(1, "Enter the code from the email"),
    password: z.string().min(8, "Passwords need at least 8 characters").max(1024, "That password is too long"),
    confirmPassword: z.string().min(1, "Confirm your new password"),
  })
  .refine((values) => values.password === values.confirmPassword, {
    path: ["confirmPassword"],
    message: "Those passwords do not match",
  });

type Values = z.infer<typeof schema>;

/// The landing page of the email link: the token is in the URL, the new
/// password is typed twice, and the emailed token is the whole proof — no
/// browser session is involved.
export function ResetScreen({ data }: { data: ResetData }) {
  const { t } = useTranslation();
  const [state, setState] = useState<{ done: boolean; error: string; busy: boolean }>({
    done: false,
    error: "",
    busy: false,
  });

  const form = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { token: data.token, password: "", confirmPassword: "" },
  });

  const submit = form.handleSubmit(async (values) => {
    setState({ done: false, error: "", busy: true });
    try {
      const response = await fetch("/xrpc/com.atproto.server.resetPassword", {
        method: "POST",
        headers: { "content-type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({ token: values.token.trim(), password: values.password }),
      });
      if (!response.ok) {
        const body = (await response.json().catch(() => ({}))) as { message?: string };
        setState({ done: false, busy: false, error: body.message ?? t("reset.failed") });
        return;
      }
      setState({ done: true, error: "", busy: false });
    } catch {
      setState({ done: false, busy: false, error: t("reset.failed") });
    }
  });

  if (state.done) {
    return (
      <AuthCard title={t("reset.title")} service={data.service}>
        <div className="flex items-center gap-2 text-success">
          <IconCircleCheck size={20} aria-hidden />
          <p className="text-sm font-medium">{t("reset.done")}</p>
        </div>
        <Button as="a" href="/account/login" color="primary" size="lg" radius="sm" className="font-medium">
          {t("common.signIn")}
        </Button>
      </AuthCard>
    );
  }

  return (
    <AuthCard title={t("reset.title")} service={data.service} subtitle={t("reset.subtitle")}>
      {state.error ? <Alert tone="danger">{state.error}</Alert> : null}

      <form onSubmit={(event) => void submit(event)} className="flex flex-col gap-4" noValidate>
        {data.token ? null : (
          <TextField
            label={t("reset.code")}
            placeholder={t("reset.codePlaceholder")}
            registration={form.register("token")}
            error={form.formState.errors.token}
            autoComplete="one-time-code"
            maxLength={256}
          />
        )}
        <PasswordField
          label={t("reset.newPassword")}
          placeholder={t("reset.passwordPlaceholder")}
          registration={form.register("password")}
          error={form.formState.errors.password}
          startContent={<IconLock size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="new-password"
          autoFocus
          maxLength={1024}
        />
        <PasswordField
          label={t("reset.confirmPassword")}
          placeholder={t("reset.confirmPlaceholder")}
          registration={form.register("confirmPassword")}
          error={form.formState.errors.confirmPassword}
          startContent={<IconLock size={18} stroke={1.75} className="text-default-400" aria-hidden />}
          autoComplete="new-password"
          maxLength={1024}
        />
        <Button
          type="submit"
          color="primary"
          size="lg"
          radius="sm"
          isLoading={state.busy}
          className="mt-1 font-medium"
        >
          {t("reset.submit")}
        </Button>
      </form>
    </AuthCard>
  );
}
