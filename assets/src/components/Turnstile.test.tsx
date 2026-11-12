import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { Turnstile } from "./Turnstile";

afterEach(() => { cleanup(); delete window.turnstile; });

describe("signup verification", () => {
  it("uses signup action, clears expired tokens and removes widgets", async () => {
    let options: Record<string, unknown> = {};
    const remove = vi.fn();
    window.turnstile = { render: vi.fn((_element: HTMLElement, value: Record<string, unknown>) => { options = value; return "widget"; }), remove };
    const onToken = vi.fn();
    const view = render(<StrictMode><Turnstile siteKey="site" onToken={onToken} /></StrictMode>);
    await waitFor(() => expect(window.turnstile?.render).toHaveBeenCalledTimes(1));
    expect(options.sitekey).toBe("site");
    expect(options.action).toBe("signup");
    expect(options["response-field"]).toBe(false);
    act(() => (options.callback as (token: string) => void)("verified-token"));
    expect(onToken).toHaveBeenLastCalledWith("verified-token");
    act(() => (options["expired-callback"] as () => void)());
    expect(onToken).toHaveBeenLastCalledWith("");
    view.unmount();
    expect(remove).toHaveBeenCalledWith("widget");
  });

  it("clears failed tokens and lets the visitor retry", async () => {
    let options: Record<string, unknown> = {};
    const renderWidget = vi.fn((_element: HTMLElement, value: Record<string, unknown>) => { options = value; return "widget"; });
    window.turnstile = { render: renderWidget, remove: vi.fn() };
    const onToken = vi.fn();
    render(<Turnstile siteKey="site" onToken={onToken} />);
    await waitFor(() => expect(renderWidget).toHaveBeenCalledTimes(1));
    act(() => (options["error-callback"] as () => void)());
    expect(onToken).toHaveBeenLastCalledWith("");
    expect(screen.getByRole("alert")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry verification" }));
    await waitFor(() => expect(renderWidget).toHaveBeenCalledTimes(2));
  });
});
