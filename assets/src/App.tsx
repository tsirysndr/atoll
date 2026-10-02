import { HeroUIProvider } from "@heroui/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Provider as JotaiProvider } from "jotai";
import { I18nextProvider } from "react-i18next";
import type { Bootstrap } from "./bootstrap";
import i18n from "./i18n";
import { LoginScreen } from "./screens/LoginScreen";
import { ResetScreen } from "./screens/ResetScreen";
import { SignupScreen } from "./screens/SignupScreen";
import { AuthorizeScreen } from "./screens/AuthorizeScreen";
import { SessionsScreen } from "./screens/SessionsScreen";
import { SecurityScreen } from "./screens/SecurityScreen";
import { PasskeysScreen } from "./screens/PasskeysScreen";
import { MessageScreen } from "./screens/MessageScreen";

export function Screen({ data }: { data: Bootstrap }) {
  switch (data.screen) {
    case "login":
      return <LoginScreen data={data} />;
    case "reset":
      return <ResetScreen data={data} />;
    case "signup":
      return <SignupScreen data={data} />;
    case "authorize":
      return <AuthorizeScreen data={data} />;
    case "sessions":
      return <SessionsScreen data={data} />;
    case "security":
      return <SecurityScreen data={data} />;
    case "passkeys":
      return <PasskeysScreen data={data} />;
    case "message":
      return <MessageScreen data={data} />;
  }
}

export function App({ data, client }: { data: Bootstrap; client?: QueryClient }) {
  const queryClient = client ?? new QueryClient();

  return (
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={queryClient}>
        <JotaiProvider>
          <HeroUIProvider>
            <Screen data={data} />
          </HeroUIProvider>
        </JotaiProvider>
      </QueryClientProvider>
    </I18nextProvider>
  );
}
