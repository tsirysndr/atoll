import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient } from "@tanstack/react-query";
import { App } from "../App";
import { authorizeFixture } from "../test/fixtures";

const client = () => new QueryClient({ defaultOptions: { queries: { retry: false } } });

describe("AuthorizeScreen", () => {
  it("lists every requested permission as a checkbox", () => {
    render(<App data={authorizeFixture} client={client()} />);

    const permissions = screen.getByRole("region", { name: "Permissions" });
    expect(within(permissions).getAllByRole("checkbox")).toHaveLength(3);
  });

  it("carries the permission field names for the server form post", () => {
    const { container } = render(<App data={authorizeFixture} client={client()} />);

    for (const permission of authorizeFixture.permissions) {
      expect(container.querySelector(`input[name='${permission.field}']`)).toBeInTheDocument();
    }
  });

  it("starts with the server's selection and counts it", () => {
    render(<App data={authorizeFixture} client={client()} />);

    expect(screen.getByText("2 of 3")).toBeInTheDocument();
  });

  it("selects and clears every permission at once", async () => {
    const user = userEvent.setup();
    render(<App data={authorizeFixture} client={client()} />);

    await user.click(screen.getByRole("button", { name: /select all/i }));
    expect(screen.getByText("3 of 3")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /clear all/i }));
    expect(screen.getByText("0 of 3")).toBeInTheDocument();
  });

  it("groups permission sets apart from individual permissions", () => {
    render(<App data={authorizeFixture} client={client()} />);

    expect(screen.getByRole("region", { name: /permission sets/i })).toBeInTheDocument();
    expect(screen.getByRole("region", { name: /individual permissions/i })).toBeInTheDocument();
    expect(screen.getByText("Set")).toBeInTheDocument();
  });

  it("sends the approve decision with the form", async () => {
    const user = userEvent.setup();
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit");
    const { container } = render(<App data={authorizeFixture} client={client()} />);

    await user.click(screen.getByRole("button", { name: /^authorize$/i }));

    await waitFor(() => expect(submit).toHaveBeenCalled());
    expect(container.querySelector("input[name='decision']")).toHaveValue("approve");
  });

  it("sends the deny decision with the form", async () => {
    const user = userEvent.setup();
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit");
    const { container } = render(<App data={authorizeFixture} client={client()} />);

    await user.click(screen.getByRole("button", { name: /deny access/i }));

    await waitFor(() => expect(submit).toHaveBeenCalled());
    expect(container.querySelector("input[name='decision']")).toHaveValue("deny");
  });
});
