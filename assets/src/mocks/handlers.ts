import { http, HttpResponse } from "msw";

export const describeServer = {
  availableUserDomains: [".example.com"],
  inviteCodeRequired: false,
  links: {
    privacyPolicy: "https://example.com/privacy",
    termsOfService: "https://example.com/terms",
  },
  contact: { email: "admin@example.com" },
};

export const takenHandles = new Set(["taken.example.com"]);

export const handlers = [
  http.get("/xrpc/com.atproto.server.describeServer", () => HttpResponse.json(describeServer)),

  http.get("/xrpc/com.atproto.identity.resolveHandle", ({ request }) => {
    const handle = new URL(request.url).searchParams.get("handle") ?? "";

    return takenHandles.has(handle)
      ? HttpResponse.json({ did: "did:plc:taken" })
      : HttpResponse.json({ error: "InvalidRequest" }, { status: 400 });
  }),
];
