import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient } from "@tanstack/react-query";
import { App } from "../App";
import { http, HttpResponse } from "msw";
import { loginFixture } from "../test/fixtures";
import { describeServer } from "../mocks/handlers";
import { server } from "../mocks/server";

const client = () => new QueryClient({ defaultOptions: { queries: { retry: false } } });

describe("LoginScreen", () => {
  it("asks for a username or email address, never a DID", () => {
    render(<App data={loginFixture} client={client()} />);

    expect(screen.getByLabelText(/username or email address/i)).toBeInTheDocument();
    expect(screen.queryByText(/DID/)).not.toBeInTheDocument();
  });

  it("offers an example handle on the server's own domain", async () => {
    server.use(
      http.get("/xrpc/com.atproto.server.describeServer", () =>
        HttpResponse.json({ ...describeServer, availableUserDomains: [".rocksky.social"] }),
      ),
    );
    render(<App data={loginFixture} client={client()} />);

    expect(await screen.findByPlaceholderText("alice.rocksky.social")).toBeInTheDocument();
  });

  it("prefills the identifier the OAuth request asked for", () => {
    render(
      <App data={{ ...loginFixture, identifier: "alice.example.com" }} client={client()} />,
    );

    expect(screen.getByLabelText(/username or email address/i)).toHaveValue("alice.example.com");
  });

  it("posts to the server form endpoint with the CSRF token", () => {
    const { container } = render(<App data={loginFixture} client={client()} />);
    const form = container.querySelector("form[action='/account/login']");

    expect(form).toHaveAttribute("method", "post");
    expect(form?.querySelector("input[name='_csrf_token']")).toHaveValue("test-csrf-token");
  });

  it("blocks submission until the password is long enough", async () => {
    const user = userEvent.setup();
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit");
    render(<App data={loginFixture} client={client()} />);

    await user.type(screen.getByLabelText(/username or email address/i), "alice.example.com");
    await user.type(screen.getByLabelText(/^password$/i), "short");
    await user.click(screen.getByRole("button", { name: /sign in$/i }));

    await waitFor(() => expect(screen.getByText(/at least 8 characters/i)).toBeInTheDocument());
    expect(submit).not.toHaveBeenCalled();
  });

  it("submits natively once the form is valid", async () => {
    const user = userEvent.setup();
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit");
    render(<App data={loginFixture} client={client()} />);

    await user.type(screen.getByLabelText(/username or email address/i), "alice.example.com");
    await user.type(screen.getByLabelText(/^password$/i), "correct horse battery");
    await user.click(screen.getByRole("button", { name: /sign in$/i }));

    await waitFor(() => expect(submit).toHaveBeenCalled());
  });

  it("shows the translated server error", () => {
    render(<App data={{ ...loginFixture, error: "invalid_credentials" }} client={client()} />);

    expect(screen.getByRole("alert")).toHaveTextContent(/sign-in failed/i);
  });
});

describe("LoginScreen progress", () => {
  it("shows the button busy while the request is in flight", async () => {
    const user = userEvent.setup();
    render(<App data={loginFixture} client={client()} />);

    await user.type(screen.getByLabelText(/username or email address/i), "alice.example.com");
    await user.type(screen.getByLabelText(/^password$/i), "correct horse battery");

    const button = screen.getByRole("button", { name: /sign in$/i });
    await user.click(button);

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /sign in$/i })).toHaveAttribute(
        "data-loading",
        "true",
      ),
    );
  });
});
