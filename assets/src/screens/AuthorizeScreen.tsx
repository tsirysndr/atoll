import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { useSetAtom } from "jotai";
import { useTranslation } from "react-i18next";
import type { AuthorizeData } from "../bootstrap";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { ClientPanel } from "../components/ClientPanel";
import { PermissionList } from "../components/PermissionList";
import { ServerForm, useServerForm } from "../components/ServerForm";
import { SubmitButton } from "../components/SubmitButton";
import { permissionsAtom } from "../atoms";
import { errorMessage } from "../i18n";

export function AuthorizeScreen({ data }: { data: AuthorizeData }) {
  const { t } = useTranslation();
  const setPermissions = useSetAtom(permissionsAtom);
  const form = useForm();
  const api = useServerForm(form);

  useEffect(() => {
    setPermissions(
      Object.fromEntries(data.permissions.map((permission) => [permission.field, permission.checked])),
    );
  }, [data.permissions, setPermissions]);

  return (
    <AuthCard
      title={t("authorize.title")}
      service={data.service}
      width={data.permissions.length > 3 ? "full" : "wide"}
    >
      <ClientPanel client={data.client} account={data.account} />

      <Alert>{errorMessage(data.error, t)}</Alert>

      <p className="text-sm text-default-500">{t("authorize.learnsDid")}</p>

      <ServerForm
        action="/oauth/authorize"
        csrf={data.csrf}
        api={api}
        hidden={{ view: data.view }}
        className="flex flex-col gap-5"
      >
        <PermissionList permissions={data.permissions} />

        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <SubmitButton
            variant="bordered"
            size="lg"
            isLoading={api.submitting}
            onPress={() => api.submitWith("decision", "deny")}
          >
            {t("authorize.deny")}
          </SubmitButton>
          <SubmitButton
            color="primary"
            size="lg"
            className="font-medium sm:min-w-40"
            isLoading={api.submitting}
            onPress={() => api.submitWith("decision", "approve")}
          >
            {t("authorize.approve")}
          </SubmitButton>
        </div>
      </ServerForm>

      <div className="space-y-2 border-t border-default-200 pt-4 text-xs text-default-500">
        <p>{t("authorize.revokeNote")}</p>
        <a href="/account/sessions" className="text-primary hover:underline">
          {t("authorize.manage")}
        </a>
      </div>
    </AuthCard>
  );
}
