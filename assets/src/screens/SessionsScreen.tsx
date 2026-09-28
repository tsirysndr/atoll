import { Button, Chip } from "@heroui/react";
import { useTranslation } from "react-i18next";
import { IconApps, IconShieldLock } from "@tabler/icons-react";
import type { SessionsData } from "../bootstrap";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { PostForm, SubmitButton } from "../components/SubmitButton";
import { errorMessage } from "../i18n";

function formatDate(seconds: number, language: string) {
  return new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(seconds * 1000),
  );
}

export function SessionsScreen({ data }: { data: SessionsData }) {
  const { t, i18n } = useTranslation();

  return (
    <AuthCard title={t("sessions.title")} service={data.service} width="wide">
      <Alert>{errorMessage(data.error, t)}</Alert>

      <div className="flex flex-wrap gap-3">
        <Button
          as="a"
          href="/account/security"
          variant="bordered"
          radius="sm"
          size="sm"
          startContent={<IconShieldLock size={16} stroke={1.75} />}
        >
          {t("sessions.security")}
        </Button>
      </div>

      {data.sessions.length === 0 ? (
        <p className="rounded-xl border border-dashed border-default-200 p-6 text-center text-sm text-default-500">
          {t("sessions.empty")}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {data.sessions.map((session) => (
            <li
              key={session.id}
              className="flex flex-col gap-3 rounded-xl border border-default-200 p-4"
            >
              <div className="flex items-start gap-3">
                <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand dark:bg-primary-500/15">
                  <IconApps size={20} stroke={1.75} aria-hidden />
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold wrap-anywhere">{session.clientId}</p>
                  <p className="text-xs text-default-500">
                    {t("sessions.expires", { date: formatDate(session.expiresAt, i18n.language) })}
                  </p>
                </div>
              </div>

              <div className="flex flex-wrap gap-1">
                {session.scope.split(" ").map((scope) => (
                  <Chip key={scope} size="sm" variant="flat" radius="sm" className="font-mono text-[0.7rem]">
                    {scope}
                  </Chip>
                ))}
              </div>

              <PostForm
                action="/account/sessions/revoke"
                csrf={data.csrf}
                fields={{ id: session.id }}
                className="self-start"
              >
                {(submitting) => (
                  <SubmitButton size="sm" variant="flat" color="danger" isLoading={submitting}>
                    {t("sessions.revoke")}
                  </SubmitButton>
                )}
              </PostForm>
            </li>
          ))}
        </ul>
      )}

      {data.cursor ? (
        <a
          href={`/account/sessions?cursor=${encodeURIComponent(data.cursor)}`}
          className="text-center text-sm text-primary hover:underline"
        >
          {t("sessions.next")}
        </a>
      ) : null}

      <PostForm
        action="/account/logout"
        csrf={data.csrf}
        className="border-t border-default-200 pt-4"
      >
        {(submitting) => (
          <SubmitButton variant="bordered" fullWidth isLoading={submitting}>
            {t("sessions.signOutAll")}
          </SubmitButton>
        )}
      </PostForm>
    </AuthCard>
  );
}
