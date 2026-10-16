import { useState } from "react";
import { useForm } from "react-hook-form";
import { HeroUIProvider } from "@heroui/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { HandleAutocomplete } from "./HandleAutocomplete";

function Harness({ initial = "" }: { initial?: string }) {
  const [value, setValue] = useState(initial);
  const form = useForm();
  return <HeroUIProvider disableAnimation><HandleAutocomplete value={value} onValueChange={setValue} registration={form.register("handle")} label="Handle" /></HeroUIProvider>;
}
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); vi.restoreAllMocks(); });

function mockFetch(withProfile = true) {
  const fetcher = vi.fn(async (input: URL, _options?: RequestInit) => ({ ok: true, json: async () => input.pathname.endsWith("searchHandles")
    ? { handles: ["alice.local.test", "alice.local.test", "bob.local.test"] }
    : withProfile ? { uri: "at://did:plc:alice/app.bsky.actor.profile/self", value: { displayName: "Alice", avatar: { ref: { $link: "avatar-cid" } } } } : { value: {} } }));
  vi.stubGlobal("fetch", fetcher);
  return fetcher;
}

describe("HandleAutocomplete", () => {
  it("debounces rapid typing into one request for the latest prefix", async () => {
    vi.useFakeTimers();
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ handles: [] }) });
    vi.stubGlobal("fetch", fetcher);
    render(<Harness />);
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "al" } });
    await act(() => vi.advanceTimersByTimeAsync(200));
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "alice" } });
    await act(() => vi.advanceTimersByTimeAsync(249));
    expect(fetcher).not.toHaveBeenCalled();
    await act(() => vi.advanceTimersByTimeAsync(1));
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect((fetcher.mock.calls[0]![0] as URL).searchParams.get("q")).toBe("alice");
  });

  it("shows scoped profiles and selects the complete handle with the keyboard", async () => {
    const fetcher = mockFetch();
    const user = userEvent.setup();
    render(<Harness />);
    const input = screen.getByRole("combobox");
    await user.type(input, "ali");
    expect(await screen.findByText("Alice")).toBeInTheDocument();
    expect(screen.getAllByRole("option")).toHaveLength(1);
    expect(screen.getByText("@alice.local.test")).toBeInTheDocument();
    const option = screen.getByRole("option");
    const img = option.querySelector("img")!;
    const url = new URL(img.src);
    expect(url.origin).toBe(window.location.origin);
    expect(url.searchParams.get("did")).toBe("did:plc:alice");
    fireEvent.error(img);
    expect(option.querySelector("img")).toBeNull();
    expect(option.querySelector("svg")).not.toBeNull();
    await user.keyboard("{ArrowDown}{Enter}");
    expect(input).toHaveValue("alice.local.test");
    expect(fetcher.mock.calls.every(([url]) => url.origin === window.location.origin)).toBe(true);
  });

  it("falls back to an outlined avatar and supports pointer selection without a profile", async () => {
    mockFetch(false);
    const user = userEvent.setup();
    render(<Harness />);
    await user.type(screen.getByRole("combobox"), "ali");
    const option = await screen.findByRole("option");
    expect(option.querySelector("svg")).not.toBeNull();
    await user.click(option);
    expect(screen.getByRole("combobox")).toHaveValue("alice.local.test");
  });

  it("aborts stale lookups and allows manual email entry", async () => {
    const fetcher = mockFetch();
    const user = userEvent.setup();
    render(<Harness />);
    const input = screen.getByRole("combobox");
    await user.type(input, "ali");
    await screen.findByRole("option");
    fireEvent.change(input, { target: { value: "alice@example.com" } });
    await waitFor(() => expect(screen.queryByRole("option")).toBeNull());
    expect(input).toHaveValue("alice@example.com");
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(fetcher.mock.calls[0]![1]?.signal?.aborted).toBe(true);
  });
  it("matches the input width and follows resizing", async () => {
    mockFetch(false);
    let width = 360;
    vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() =>
      ({ left: 24, right: 24 + width, top: 50, bottom: 98, width, height: 48, x: 24, y: 50, toJSON: () => ({}) }));
    const user = userEvent.setup();
    render(<Harness />);
    await user.type(screen.getByRole("combobox"), "ali");
    const list = await screen.findByRole("listbox");
    expect(list).toHaveStyle({ width: "360px", left: "24px" });
    width = 280;
    fireEvent(window, new Event("resize"));
    expect(list).toHaveStyle({ width: "280px" });
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("listbox")).toBeNull();
  });

});
