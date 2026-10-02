import { useState } from "react";
import { Button, Input } from "@heroui/react";
import { useTranslation } from "react-i18next";

/// "Forgot password?" under the sign-in form. Asks for the account email and
/// requests a reset; the answer is the same whether the address exists or not,
/// so nothing here says who has an account.
export function ForgotPassword() {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [state, setState] = useState<{ busy: boolean; sent: boolean; error: string }>({
    busy: false,
    sent: false,
    error: "",
  });

  const request = async () => {
    if (!email.trim()) return;
    setState({ busy: true, sent: false, error: "" });
    try {
      const response = await fetch("/xrpc/com.atproto.server.requestPasswordReset", {
        method: "POST",
        headers: { "content-type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({ email: email.trim() }),
      });
      if (!response.ok) {
        setState({ busy: false, sent: false, error: t("forgot.failed") });
        return;
      }
      setState({ busy: false, sent: true, error: "" });
    } catch {
      setState({ busy: false, sent: false, error: t("forgot.failed") });
    }
  };

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="self-center text-sm font-medium text-primary hover:underline"
      >
        {t("forgot.link")}
      </button>
    );
  }

  if (state.sent) {
    return <p className="text-center text-sm text-default-500">{t("forgot.sent")}</p>;
  }

  return (
    <div className="flex flex-col gap-2">
      <Input
        label={t("forgot.email")}
        placeholder={t("forgot.emailPlaceholder")}
        type="email"
        size="sm"
        variant="bordered"
        radius="sm"
        value={email}
        onValueChange={setEmail}
        autoComplete="email"
      />
      {state.error ? <p className="text-sm text-danger">{state.error}</p> : null}
      <Button
        size="sm"
        variant="bordered"
        radius="sm"
        isLoading={state.busy}
        onPress={() => void request()}
      >
        {t("forgot.submit")}
      </Button>
    </div>
  );
}
