import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient } from "@tanstack/react-query";
import "./styles.css";
import { App } from "./App";
import { readBootstrap } from "./bootstrap";
import { detectLanguage, setupI18n } from "./i18n";

const data = readBootstrap();
const stored = (() => {
  try {
    return JSON.parse(localStorage.getItem("atoll.language") ?? '""') as string;
  } catch {
    return null;
  }
})();

setupI18n(detectLanguage(stored, navigator.languages ?? [navigator.language]));

const container = document.getElementById("root");

if (container) {
  container.replaceChildren();
  createRoot(container).render(
    <StrictMode>
      <App data={data} client={new QueryClient()} />
    </StrictMode>,
  );
}
