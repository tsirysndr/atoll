import { Checkbox, Chip } from "@heroui/react";
import { useAtom, useAtomValue, useSetAtom } from "jotai";
import { useTranslation } from "react-i18next";
import { IconChevronRight, IconPackages } from "@tabler/icons-react";
import type { Permission } from "../bootstrap";
import {
  allPermissionsGrantedAtom,
  grantedCountAtom,
  permissionsAtom,
  setAllPermissionsAtom,
} from "../atoms";

function PermissionCard({ permission }: { permission: Permission }) {
  const { t } = useTranslation();
  const [granted, setGranted] = useAtom(permissionsAtom);
  const checked = granted[permission.field] ?? permission.checked;
  const isSet = permission.kind === "set";

  return (
    <div
      data-checked={checked}
      className="mb-3 break-inside-avoid rounded-md border border-default-200 bg-content1 p-3 transition-colors data-[checked=true]:border-primary-200 data-[checked=true]:bg-brand-soft/40 dark:data-[checked=true]:bg-primary-500/5"
    >
      <Checkbox
        name={permission.field}
        value="yes"
        isSelected={checked}
        onValueChange={(value) => setGranted({ ...granted, [permission.field]: value })}
        classNames={{ label: "text-sm leading-snug", base: "items-start max-w-full" }}
      >
        <span className="flex flex-wrap items-center gap-1.5">
          {permission.title}
          {isSet ? (
            <Chip
              size="sm"
              variant="flat"
              color="primary"
              radius="sm"
              startContent={<IconPackages size={12} stroke={2} />}
              classNames={{ base: "h-5 px-1", content: "text-[0.65rem] px-1" }}
            >
              {t("authorize.set")}
            </Chip>
          ) : null}
        </span>
      </Checkbox>

      {permission.detail || permission.includes.length > 0 ? (
        <details className="group mt-2 pl-7">
          <summary className="flex cursor-pointer list-none items-center gap-1 text-xs font-medium text-primary">
            <IconChevronRight
              size={14}
              stroke={2}
              className="transition-transform group-open:rotate-90"
              aria-hidden
            />
            {isSet ? t("authorize.included") : t("common.details")}
          </summary>
          <div className="mt-2 space-y-2 text-xs text-default-500">
            {permission.detail ? <p className="wrap-anywhere">{permission.detail}</p> : null}
            <p className="font-mono wrap-anywhere text-default-400">{permission.scope}</p>
            {permission.includes.length > 0 ? (
              <ul className="list-disc space-y-1 pl-4">
                {permission.includes.map((item) => (
                  <li key={item} className="wrap-anywhere">
                    {item}
                  </li>
                ))}
              </ul>
            ) : null}
            {isSet ? <p className="text-default-400">{t("authorize.setNote")}</p> : null}
          </div>
        </details>
      ) : null}
    </div>
  );
}

function Group({ title, permissions }: { title: string; permissions: Permission[] }) {
  if (permissions.length === 0) return null;

  return (
    <section aria-label={title} className="flex flex-col gap-2">
      <h3 className="text-xs font-semibold tracking-wide text-default-500 uppercase">{title}</h3>
      <div className="sm:columns-2 sm:gap-3">
        {permissions.map((permission) => (
          <PermissionCard key={permission.field} permission={permission} />
        ))}
      </div>
    </section>
  );
}

export function PermissionList({ permissions }: { permissions: Permission[] }) {
  const { t } = useTranslation();
  const granted = useAtomValue(grantedCountAtom);
  const all = useAtomValue(allPermissionsGrantedAtom);
  const setAll = useSetAtom(setAllPermissionsAtom);

  if (permissions.length === 0) return null;

  const sets = permissions.filter((permission) => permission.kind === "set");
  const scopes = permissions.filter((permission) => permission.kind !== "set");

  return (
    <section aria-label={t("authorize.permissions")} className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-semibold">{t("authorize.permissions")}</h2>
          <Chip size="sm" variant="flat" color="primary" radius="sm">
            {t("authorize.granted", { granted, total: permissions.length })}
          </Chip>
        </div>
        <button
          type="button"
          onClick={() => setAll(!all)}
          className="text-xs font-medium text-primary hover:underline"
        >
          {all ? t("authorize.clearAll") : t("authorize.selectAll")}
        </button>
      </div>

      <div className="max-h-[24rem] overflow-y-auto pr-1">
        {sets.length > 0 && scopes.length > 0 ? (
          <div className="flex flex-col gap-4">
            <Group title={t("authorize.sets")} permissions={sets} />
            <Group title={t("authorize.individual")} permissions={scopes} />
          </div>
        ) : (
          <div className="sm:columns-2 sm:gap-3">
            {permissions.map((permission) => (
              <PermissionCard key={permission.field} permission={permission} />
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
