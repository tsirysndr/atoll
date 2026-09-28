import { describe, expect, it } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient } from "@tanstack/react-query";
import { App } from "../App";
import { signupFixture } from "../test/fixtures";
import { takenHandles } from "../mocks/handlers";

const client = () => new QueryClient({ defaultOptions: { queries: { retry: false } } });

describe("SignupScreen", () => {
  it("works without an OAuth request", () => {
    const { container } = render(<App data={signupFixture} client={client()} />);

    expect(screen.getByRole("heading", { name: /create an account/i })).toBeInTheDocument();
    expect(container.querySelector("input[name='view']")).not.toBeInTheDocument();
  });

  it("keeps the OAuth view token when one is present", () => {
    const { container } = render(
      <App data={{ ...signupFixture, view: "view-token" }} client={client()} />,
    );

    expect(container.querySelector("input[name='view']")).toHaveValue("view-token");
  });

  it("reports an available username from the identity API", async () => {
    const user = userEvent.setup();
    render(<App data={signupFixture} client={client()} />);

    await user.type(screen.getByLabelText(/username/i), "alice.example.com");

    await waitFor(
      () => expect(screen.getByText(/that username is available/i)).toBeInTheDocument(),
      { timeout: 3000 },
    );
  });

  it("reports a taken username from the identity API", async () => {
    const user = userEvent.setup();
    render(<App data={signupFixture} client={client()} />);

    await user.type(screen.getByLabelText(/username/i), [...takenHandles][0]!);

    await waitFor(() => expect(screen.getByText(/that username is taken/i)).toBeInTheDocument(), {
      timeout: 3000,
    });
  });

  it("only asks for an invitation code when the server requires one", () => {
    const { rerender } = render(<App data={signupFixture} client={client()} />);
    expect(screen.queryByLabelText(/invitation code/i)).not.toBeInTheDocument();

    rerender(<App data={{ ...signupFixture, inviteRequired: true }} client={client()} />);
    expect(screen.getByLabelText(/invitation code/i)).toBeInTheDocument();
  });
});
