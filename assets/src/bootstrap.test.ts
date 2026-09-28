import { afterEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ELEMENT_ID, readBootstrap } from "./bootstrap";
import { loginFixture } from "./test/fixtures";

function render(json: string) {
  const element = document.createElement("script");
  element.type = "application/json";
  element.id = BOOTSTRAP_ELEMENT_ID;
  element.textContent = json;
  document.body.append(element);
}

afterEach(() => {
  document.getElementById(BOOTSTRAP_ELEMENT_ID)?.remove();
});

describe("readBootstrap", () => {
  it("reads the payload the server rendered", () => {
    render(JSON.stringify(loginFixture));

    expect(readBootstrap()).toEqual(loginFixture);
  });

  it("keeps markup in the payload inert", () => {
    render(JSON.stringify({ ...loginFixture, identifier: "</script><script>alert(1)</script>" }));

    const data = readBootstrap();
    expect(data.screen).toBe("login");
    expect(document.querySelectorAll("script").length).toBe(1);
  });

  it("falls back to a message screen when the payload is missing", () => {
    expect(readBootstrap().screen).toBe("message");
  });

  it("falls back to a message screen when the payload is not JSON", () => {
    render("{ not json");

    expect(readBootstrap().screen).toBe("message");
  });
});
