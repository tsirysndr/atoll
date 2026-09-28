import { atom } from "jotai";
import { atomWithStorage } from "jotai/utils";

export const languageAtom = atomWithStorage("atoll.language", "en");

export const twoFactorOpenAtom = atom(false);

export const permissionsAtom = atom<Record<string, boolean>>({});

export const grantedCountAtom = atom(
  (get) => Object.values(get(permissionsAtom)).filter(Boolean).length,
);

export const allPermissionsGrantedAtom = atom((get) => {
  const values = Object.values(get(permissionsAtom));
  return values.length > 0 && values.every(Boolean);
});

export const setAllPermissionsAtom = atom(null, (get, set, granted: boolean) => {
  const next: Record<string, boolean> = {};
  for (const field of Object.keys(get(permissionsAtom))) next[field] = granted;
  set(permissionsAtom, next);
});

export const passkeyStatusAtom = atom<{ message: string; busy: boolean }>({
  message: "",
  busy: false,
});
