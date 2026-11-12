import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";

type TurnstileApi = {
  render: (element: HTMLElement, options: Record<string, unknown>) => string;
  remove: (id: string) => void;
};

declare global {
  interface Window { turnstile?: TurnstileApi }
}

let loading: Promise<TurnstileApi> | undefined;

function load(): Promise<TurnstileApi> {
  if (window.turnstile) return Promise.resolve(window.turnstile);
  if (!loading) {
    loading = new Promise<TurnstileApi>((resolve, reject) => {
      const script = document.createElement("script");
      const timer = window.setTimeout(() => fail(), 15_000);
      const fail = () => {
        window.clearTimeout(timer);
        script.remove();
        loading = undefined;
        reject(new Error("Verification unavailable"));
      };
      script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
      script.async = true;
      script.onerror = fail;
      script.onload = () => {
        window.clearTimeout(timer);
        if (window.turnstile) resolve(window.turnstile);
        else fail();
      };
      document.head.appendChild(script);
    });
  }
  return loading;
}

export function Turnstile({ siteKey, onToken }: { siteKey: string; onToken: (token: string) => void }) {
  const { t } = useTranslation();
  const element = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let cancelled = false;
    let widget: string | undefined;
    let api: TurnstileApi | undefined;
    onToken("");
    setFailed(false);
    const reject = () => { if (!cancelled) { onToken(""); setFailed(true); } };
    void load().then((loaded) => {
      if (cancelled || !element.current) return;
      api = loaded;
      widget = api.render(element.current, {
        sitekey: siteKey,
        action: "signup",
        "response-field": false,
        callback: (token: string) => { if (!cancelled) { setFailed(false); onToken(token); } },
        "expired-callback": () => { if (!cancelled) onToken(""); },
        "error-callback": reject,
      });
    }).catch(reject);

    return () => {
      cancelled = true;
      if (widget !== undefined) api?.remove(widget);
    };
  }, [siteKey, onToken, attempt]);

  return <div>
    <div ref={element} />
    {failed && <p role="alert" className="text-sm text-danger">
      {t("turnstile.error")}{" "}
      <button type="button" className="underline" onClick={() => setAttempt((value) => value + 1)}>
        {t("turnstile.retry")}
      </button>
    </p>}
  </div>;
}
