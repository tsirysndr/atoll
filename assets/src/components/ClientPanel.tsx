import { IconApps, IconUserCircle } from "@tabler/icons-react";
import type { Account, Client } from "../bootstrap";

export function ClientPanel({ client, account }: { client: Client; account?: Account }) {
  return (
    <section
      aria-label="Application"
      className="flex flex-col gap-3 rounded-xl border border-default-200 bg-default-50/60 p-4"
    >
      <div className="flex items-start gap-3">
        <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand dark:bg-primary-500/15">
          <IconApps size={20} stroke={1.75} aria-hidden />
        </span>
        <div className="min-w-0">
          <p className="text-sm font-semibold wrap-anywhere">{client.name}</p>
          <p className="text-xs text-default-500">wants to access your account</p>
        </div>
      </div>

      {account ? (
        <div className="flex items-start gap-3 border-t border-default-200 pt-3">
          <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-default-100 text-default-500">
            <IconUserCircle size={20} stroke={1.75} aria-hidden />
          </span>
          <div className="min-w-0">
            <p className="text-sm font-semibold wrap-anywhere">{account.handle ?? account.did}</p>
            {account.handle ? (
              <p className="font-mono text-xs text-default-400 wrap-anywhere">{account.did}</p>
            ) : null}
          </div>
        </div>
      ) : null}
    </section>
  );
}
