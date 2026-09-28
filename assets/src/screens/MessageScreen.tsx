import { Button } from "@heroui/react";
import { useTranslation } from "react-i18next";
import type { MessageData } from "../bootstrap";
import { AuthCard } from "../components/AuthCard";
import { Alert } from "../components/Alert";
import { errorMessage } from "../i18n";

export function MessageScreen({ data }: { data: MessageData }) {
  const { t } = useTranslation();
  const text = errorMessage(data.text, t);

  return (
    <AuthCard title={data.title} service={data.service}>
      <Alert tone={data.error ? "danger" : "info"}>{text}</Alert>

      {data.link ? (
        <Button
          as="a"
          href={data.link.href}
          color="primary"
          size="lg"
          radius="sm"
          className="font-medium"
        >
          {data.link.label === "signIn" ? t("common.signIn") : data.link.label}
        </Button>
      ) : null}
    </AuthCard>
  );
}
