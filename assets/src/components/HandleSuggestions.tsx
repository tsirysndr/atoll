import { useEffect, useState } from "react";

/** Suggestions come from this server only; a gateway merges its own fleet. */
export function HandleSuggestions({ value, id }: { value: string; id: string }) {
  const query = value.trim().toLowerCase();
  const [result, setResult] = useState<{ query: string; handles: string[] }>({ query: "", handles: [] });

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
        if (!controller.signal.aborted && Array.isArray(body.handles)) {
          const handles = body.handles.filter((handle): handle is string =>
            typeof handle === "string" && handle.startsWith(query));
          setResult({ query, handles: [...new Set(handles)].sort().slice(0, 10) });
        }
      } catch {
        // Suggestions are optional; manual login still works when lookup fails.
      }
    }, 250);
    return () => { clearTimeout(timer); controller.abort(); };
  }, [query]);

  return (
    <datalist id={id}>
      {result.query === query ? result.handles.map((handle) => <option key={handle} value={handle} />) : null}
    </datalist>
  );
}
