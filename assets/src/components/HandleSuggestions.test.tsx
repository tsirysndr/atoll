import { afterEach, describe, expect, it, vi } from "vitest";
import { act, render, waitFor } from "@testing-library/react";
import { HandleSuggestions } from "./HandleSuggestions";

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("HandleSuggestions", () => {
  it("debounces rapid typing into one request for the latest prefix", async () => {
    vi.useFakeTimers();
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ handles: [] }) });
    vi.stubGlobal("fetch", fetcher);
    const { rerender } = render(<HandleSuggestions id="handles" value="al" />);
    await act(() => vi.advanceTimersByTimeAsync(200));
    rerender(<HandleSuggestions id="handles" value="alice" />);
    await act(() => vi.advanceTimersByTimeAsync(249));
    expect(fetcher).not.toHaveBeenCalled();
    await act(() => vi.advanceTimersByTimeAsync(1));
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect((fetcher.mock.calls[0]![0] as URL).searchParams.get("q")).toBe("alice");
  });

  it("asks only the current PDS and renders matching unique handles", async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ handles: ["alice.local.test", "alice.local.test", "bob.local.test"] }) });
    vi.stubGlobal("fetch", fetcher);
    const { container } = render(<HandleSuggestions id="handles" value="Ali" />);
    await waitFor(() => expect(container.querySelectorAll("option")).toHaveLength(1));
    expect(container.querySelector("option")?.value).toBe("alice.local.test");
    const url = fetcher.mock.calls[0]![0] as URL;
    expect(url.origin).toBe(window.location.origin);
    expect(url.pathname).toBe("/xrpc/social.rocksky.auth.searchHandles");
    expect(url.searchParams.get("q")).toBe("ali");
  });

  it("clears stale results immediately and never searches emails", async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ handles: ["alice.local.test"] }) });
    vi.stubGlobal("fetch", fetcher);
    const { container, rerender } = render(<HandleSuggestions id="handles" value="ali" />);
    await waitFor(() => expect(container.querySelector("option")).not.toBeNull());
    rerender(<HandleSuggestions id="handles" value="alice@example.com" />);
    expect(container.querySelector("option")).toBeNull();
    expect(fetcher.mock.calls[0]![1].signal.aborted).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("leaves suggestions empty if lookup fails", async () => {
    const fetcher = vi.fn().mockRejectedValue(new Error("offline"));
    vi.stubGlobal("fetch", fetcher);
    const { container } = render(<HandleSuggestions id="handles" value="ali" />);
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
    expect(container.querySelector("option")).toBeNull();
  });
});
