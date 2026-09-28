import { useQuery } from "@tanstack/react-query";

export type ServerDescription = {
  availableUserDomains: string[];
  inviteCodeRequired: boolean;
  links: { privacyPolicy?: string; termsOfService?: string };
  contact: { email?: string };
};

async function xrpc<T>(method: string, params?: Record<string, string>): Promise<T> {
  const url = new URL(`/xrpc/${method}`, window.location.origin);
  for (const [key, value] of Object.entries(params ?? {})) url.searchParams.set(key, value);

  const response = await fetch(url, {
    headers: { accept: "application/json" },
    credentials: "same-origin",
  });

  if (!response.ok) throw new Error(`${method} failed with ${response.status}`);

  return (await response.json()) as T;
}

export function useServerDescription() {
  return useQuery({
    queryKey: ["describeServer"],
    queryFn: () => xrpc<ServerDescription>("com.atproto.server.describeServer"),
    staleTime: 5 * 60 * 1000,
    retry: false,
  });
}

export function useHandleAvailability(handle: string, enabled: boolean) {
  return useQuery({
    queryKey: ["resolveHandle", handle],
    enabled: enabled && handle.includes(".") && handle.length > 2,
    retry: false,
    staleTime: 30 * 1000,
    queryFn: async () => {
      try {
        await xrpc<{ did: string }>("com.atproto.identity.resolveHandle", { handle });
        return "taken" as const;
      } catch {
        return "available" as const;
      }
    },
  });
}
