import i18n, { type TFunction } from "i18next";
import { initReactI18next } from "react-i18next";
import en from "./locales/en.json";
import fr from "./locales/fr.json";
import pt from "./locales/pt.json";
import it from "./locales/it.json";
import es from "./locales/es.json";

export const languages = [
  { key: "en", label: "English" },
  { key: "fr", label: "Français" },
  { key: "pt", label: "Português" },
  { key: "es", label: "Español" },
  { key: "it", label: "Italiano" },
] as const;

export type LanguageKey = (typeof languages)[number]["key"];

export function isLanguage(value: string): value is LanguageKey {
  return languages.some((language) => language.key === value);
}

export function detectLanguage(stored: string | null, navigatorLanguages: readonly string[]) {
  if (stored && isLanguage(stored)) return stored;

  for (const candidate of navigatorLanguages) {
    const base = candidate.split("-")[0]?.toLowerCase() ?? "";
    if (isLanguage(base)) return base;
  }

  return "en";
}

export function setupI18n(language: string) {
  if (!i18n.isInitialized) {
    void i18n.use(initReactI18next).init({
      resources: {
        en: { translation: en },
        fr: { translation: fr },
        pt: { translation: pt },
        es: { translation: es },
        it: { translation: it },
      },
      lng: language,
      fallbackLng: "en",
      interpolation: { escapeValue: false },
      returnNull: false,
    });
  }

  return i18n;
}

export function errorMessage(code: string, translate: TFunction) {
  if (!code) return "";
  return translate(`errors.${code}`, { defaultValue: translate("errors.generic") }) as string;
}

export default i18n;
