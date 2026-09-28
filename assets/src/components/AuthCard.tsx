import { useEffect, type ReactNode } from "react";
import { Card, CardBody, Select, SelectItem } from "@heroui/react";
import { useAtom } from "jotai";
import { useTranslation } from "react-i18next";
import { IconCloudLock } from "@tabler/icons-react";
import { languageAtom } from "../atoms";
import { languages } from "../i18n";

const widths = {
  narrow: "max-w-[26rem]",
  wide: "max-w-[34rem]",
  full: "max-w-3xl",
} as const;

export type AuthCardProps = {
  title: string;
  subtitle?: ReactNode;
  service?: string;
  width?: keyof typeof widths;
  children: ReactNode;
  footer?: ReactNode;
};

export function AuthCard({
  title,
  subtitle,
  service,
  width = "narrow",
  children,
  footer,
}: AuthCardProps) {
  const [language, setLanguage] = useAtom(languageAtom);
  const { t, i18n } = useTranslation();

  useEffect(() => {
    if (i18n.language !== language) void i18n.changeLanguage(language);
  }, [i18n, language]);

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4 px-4 py-8 sm:py-12">
      <Card
        className={`w-full ${widths[width]} border border-default-200/60 bg-content1 shadow-sm`}
        shadow="none"
        radius="lg"
      >
        <CardBody className="gap-6 px-6 py-8 sm:px-8">
          <header className="flex flex-col items-center gap-3 text-center">
            <span className="flex size-11 items-center justify-center rounded-2xl bg-brand-soft text-brand dark:bg-primary-500/15">
              <IconCloudLock size={24} stroke={1.75} aria-hidden />
            </span>
            <div className="space-y-1">
              <h1 className="text-xl font-semibold tracking-tight text-balance">{title}</h1>
              {service ? <p className="text-sm text-default-500">{service}</p> : null}
            </div>
            {subtitle ? <div className="text-sm text-default-500">{subtitle}</div> : null}
          </header>

          {children}
        </CardBody>
      </Card>

      <div className="flex w-full max-w-[26rem] flex-col items-center gap-3">
        {footer}
        <Select
          aria-label={t("common.language")}
          size="sm"
          variant="bordered"
          radius="sm"
          className="max-w-[12rem]"
          selectedKeys={[language]}
          onSelectionChange={(keys) => setLanguage(String(Array.from(keys)[0] ?? "en"))}
        >
          {languages.map((entry) => (
            <SelectItem key={entry.key}>{entry.label}</SelectItem>
          ))}
        </Select>
      </div>
    </div>
  );
}
