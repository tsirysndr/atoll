import { useEffect, useRef, useState, useId, useLayoutEffect } from "react";
import { Input } from "@heroui/react";
import { createPortal } from "react-dom";
import { IconUserCircle } from "@tabler/icons-react";
import type { FieldError, UseFormRegisterReturn } from "react-hook-form";
import type { ReactNode } from "react";

export type HandleProfile = { handle: string; displayName?: string; avatar?: string };

type Props = {
  value: string;
  onValueChange: (value: string) => void;
  registration: UseFormRegisterReturn;
  label: string;
  placeholder?: string;
  error?: FieldError;
  startContent?: ReactNode;
  autoComplete?: string;
  autoFocus?: boolean;
  maxLength?: number;
};

async function profileFor(handle: string, signal: AbortSignal): Promise<HandleProfile> {
  const profile: HandleProfile = { handle };
  try {
    const url = new URL("/xrpc/com.atproto.repo.getRecord", window.location.origin);
    url.search = new URLSearchParams({ repo: handle, collection: "app.bsky.actor.profile", rkey: "self" }).toString();
    const response = await fetch(url, { signal, credentials: "omit" });
    if (!response.ok) return profile;
    const body = await response.json();
    const name = body.value?.displayName;
    if (typeof name === "string" && name.trim()) profile.displayName = name.trim();
    const cid = body.value?.avatar?.ref?.$link;
    const did = typeof body.uri === "string" ? body.uri.match(/^at:\/\/(did:[^/]+)\//)?.[1] : undefined;
    if (did && typeof cid === "string") {
      const avatar = new URL("/xrpc/com.atproto.sync.getBlob", window.location.origin);
      avatar.search = new URLSearchParams({ did, cid }).toString();
      profile.avatar = avatar.toString();
    }
  } catch {
    // A missing profile must never prevent selecting a valid local handle.
  }
  return profile;
}

export function ProfileAvatar({ profile }: { profile: HandleProfile }) {
  const [failed, setFailed] = useState<string>();
  return (
    <span className="flex size-10 shrink-0 items-center justify-center overflow-hidden rounded-full border border-default-200 bg-default-100 text-default-400">
      {profile.avatar && failed !== profile.avatar ? (
        <img src={profile.avatar} alt="" className="size-full object-cover" referrerPolicy="no-referrer" onError={() => setFailed(profile.avatar)} />
      ) : (
        <IconUserCircle size={28} stroke={1.5} aria-hidden />
      )}
    </span>
  );
}

/** The server scopes candidates; profile and image requests stay on this origin. */
export function HandleAutocomplete({ value, onValueChange, registration, label, placeholder, error, startContent, autoComplete, autoFocus, maxLength }: Props) {
  const query = value.trim().toLowerCase();
  const cache = useRef(new Map<string, { profile: HandleProfile; expires: number }>());
  const [result, setResult] = useState<{ query: string; profiles: HandleProfile[] }>({ query: "", profiles: [] });

  useEffect(() => {
    if (!/^[a-z0-9.-]{2,253}$/.test(query)) return;
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const url = new URL("/xrpc/social.rocksky.auth.searchHandles", window.location.origin);
        url.searchParams.set("q", query);
        const response = await fetch(url, { signal: controller.signal, credentials: "omit" });
        if (!response.ok) return;
        const body = await response.json() as { handles?: unknown };
        if (controller.signal.aborted || !Array.isArray(body.handles)) return;
        const handles = [...new Set(body.handles.filter((handle): handle is string =>
          typeof handle === "string" && handle.startsWith(query)))].sort().slice(0, 10);
        const cached = (handle: string) => {
          const entry = cache.current.get(handle);
          return entry && entry.expires > Date.now() ? entry.profile : undefined;
        };
        setResult({ query, profiles: handles.map((handle) => cached(handle) ?? { handle }) });
        await Promise.all(handles.map(async (handle) => {
          if (cached(handle)) return;
          const profile = await profileFor(handle, controller.signal);
          if (controller.signal.aborted) return;
          if (cache.current.size >= 100) cache.current.delete(cache.current.keys().next().value!);
          cache.current.set(handle, { profile, expires: Date.now() + 60_000 });
          setResult((current) => current.query === query ? {
            query, profiles: current.profiles.map((item) => item.handle === handle ? profile : item),
          } : current);
        }));
      } catch {
        // Manual sign-in stays available when suggestions cannot be loaded.
      }
    }, 250);
    return () => { clearTimeout(timer); controller.abort(); };
  }, [query]);

  const profiles = result.query === query ? result.profiles : [];
  const listId = useId();
  const wrapper = useRef<HTMLDivElement>(null);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [active, setActive] = useState(-1);
  const [position, setPosition] = useState({ left: 0, top: 0, width: 0, maxHeight: 320 });
  const open = focused && !dismissed && profiles.length > 0;

  useLayoutEffect(() => {
    if (!open) return;
    const anchor = wrapper.current?.querySelector('[data-slot="input-wrapper"]');
    if (!anchor) return;
    const update = () => {
      const rect = anchor.getBoundingClientRect();
      const below = window.innerHeight - rect.bottom - 14;
      const above = rect.top - 14;
      const upward = below < Math.min(220, profiles.length * 64 + 8) && above > below;
      const maxHeight = Math.max(64, Math.min(320, upward ? above : below));
      setPosition({ left: rect.left, width: rect.width,
        top: upward ? rect.top - 6 - Math.min(maxHeight, profiles.length * 64 + 8) : rect.bottom + 6,
        maxHeight });
    };
    update();
    const observer = new ResizeObserver(update);
    observer.observe(anchor);
    window.addEventListener("resize", update);
    window.addEventListener("scroll", update, true);
    return () => { observer.disconnect(); window.removeEventListener("resize", update); window.removeEventListener("scroll", update, true); };
  }, [open, profiles.length]);

  useEffect(() => { setActive(-1); }, [query]);
  useEffect(() => {
    if (open && active >= 0) document.getElementById(`${listId}-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active, open, listId]);

  const choose = (profile: HandleProfile) => {
    onValueChange(profile.handle);
    setDismissed(true);
    setActive(-1);
  };

  return (
    <div ref={wrapper} className="w-full">
      <Input
        name={registration.name}
        ref={registration.ref}
        onBlur={(event) => { setFocused(false); void registration.onBlur(event); }}
        onFocus={() => setFocused(true)}
        label={label}
        placeholder={placeholder}
        value={value}
        onValueChange={(next) => { setDismissed(false); onValueChange(next); }}
        onKeyDown={(event) => {
          if (event.key === "Escape") { setDismissed(true); setActive(-1); }
          if (profiles.length && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
            event.preventDefault();
            setDismissed(false);
            setActive((index) => event.key === "ArrowDown" ? (index + 1) % profiles.length : (index <= 0 ? profiles.length - 1 : index - 1));
          }
          if (open && active >= 0 && event.key === "Enter") {
            event.preventDefault();
            choose(profiles[active]!);
          }
        }}
        role="combobox"
        aria-autocomplete="list"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-activedescendant={open && active >= 0 ? `${listId}-${active}` : undefined}
        variant="bordered"
        radius="sm"
        labelPlacement="outside"
        isRequired
        isInvalid={Boolean(error)}
        errorMessage={error?.message}
        startContent={startContent}
        autoComplete={autoComplete}
        autoFocus={autoFocus}
        maxLength={maxLength}
        autoCapitalize="none"
        spellCheck="false"
        classNames={{
          inputWrapper: "h-12 rounded-md border border-default-200 bg-default-50/60 data-[hover=true]:border-default-300 group-data-[focus=true]:border-primary",
          label: "text-sm font-medium text-foreground", input: "text-base",
        }}
      />
      {open ? createPortal(
        <ul id={listId} role="listbox" aria-label={label}
          className="fixed z-50 m-0 list-none overflow-y-auto rounded-xl border border-default-200 bg-content1 p-1 shadow-lg"
          style={position}>
          {profiles.map((profile, index) => (
            <li key={profile.handle} id={`${listId}-${index}`} role="option" aria-selected={index === active}
              className={`flex min-h-16 cursor-pointer items-center gap-3 rounded-lg px-3 py-2 ${index === active ? "bg-default-100" : "hover:bg-default-100"}`}
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActive(index)}
              onClick={() => choose(profile)}>
              <ProfileAvatar profile={profile} />
              <div className="flex min-w-0 flex-col gap-0.5">
                <span className="truncate text-sm font-medium text-foreground">{profile.displayName || profile.handle}</span>
                {profile.displayName ? <span className="truncate text-xs text-default-500">@{profile.handle}</span> : null}
              </div>
            </li>
          ))}
        </ul>, document.body,
      ) : null}
    </div>
  );
}
