import { IconAlertTriangle, IconInfoCircle } from "@tabler/icons-react";

export type AlertProps = {
  tone?: "danger" | "info";
  children: React.ReactNode;
};

export function Alert({ tone = "danger", children }: AlertProps) {
  if (!children) return null;

  const Icon = tone === "danger" ? IconAlertTriangle : IconInfoCircle;
  const palette =
    tone === "danger"
      ? "bg-danger-50 text-danger-600 dark:bg-danger-500/10 dark:text-danger-400"
      : "bg-brand-soft text-primary-700 dark:bg-primary-500/10 dark:text-primary-300";

  return (
    <div
      role={tone === "danger" ? "alert" : "status"}
      className={`flex items-start gap-2 rounded-xl px-3 py-2.5 text-sm ${palette}`}
    >
      <Icon size={18} stroke={1.75} className="mt-0.5 shrink-0" aria-hidden />
      <span className="wrap-anywhere">{children}</span>
    </div>
  );
}
