import { describe, expect, it } from "vitest";
import en from "./locales/en.json";
import fr from "./locales/fr.json";
import pt from "./locales/pt.json";
import italian from "./locales/it.json";
import spanish from "./locales/es.json";
import { detectLanguage, errorMessage, isLanguage, setupI18n } from ".";

const keys = (value: object, prefix = ""): string[] =>
  Object.entries(value).flatMap(([key, entry]) =>
    typeof entry === "object" && entry !== null
      ? keys(entry as object, `${prefix}${key}.`)
      : [`${prefix}${key}`],
  );

describe("translations", () => {
  it("covers the same keys in every language", () => {
    for (const locale of [fr, pt, spanish, italian]) {
      expect(keys(locale).sort()).toEqual(keys(en).sort());
    }
  });

  it("detects a stored language first, then the browser", () => {
    expect(detectLanguage("fr", ["en-GB"])).toBe("fr");
    expect(detectLanguage(null, ["pt-BR", "en"])).toBe("pt");
    expect(detectLanguage(null, ["it-CH"])).toBe("it");
    expect(detectLanguage(null, ["es-MX"])).toBe("es");
    expect(detectLanguage(null, ["de"])).toBe("en");
    expect(isLanguage("de")).toBe(false);
    expect(isLanguage("es")).toBe(true);
  });

  it("falls back to a generic message for unknown error codes", () => {
    const i18n = setupI18n("en");

    expect(errorMessage("invalid_credentials", i18n.t)).toMatch(/sign-in failed/i);
    expect(errorMessage("not_a_real_code", i18n.t)).toBe(en.errors.generic);
    expect(errorMessage("", i18n.t)).toBe("");
  });
});
