# Account frontend

The browser screens — sign in, account creation, OAuth authorization, connected
applications, two-factor setup and passkeys — are a React application in
`assets/`, built with Bun and served by Phoenix from `priv/static/assets`.

## Stack

| Piece           | Choice                                                       |
| --------------- | ------------------------------------------------------------ |
| Framework       | React 19 with TypeScript, built by Vite                      |
| Package manager | Bun (`assets/bun.lock` is the only lockfile)                 |
| Styling         | Tailwind CSS 4 and HeroUI, purple brand, Roboto Mono Variable |
| State           | Jotai for screen state, TanStack Query for server reads       |
| Forms           | React Hook Form with Zod schemas                              |
| Icons           | Tabler                                                        |
| Translations    | i18next: English, French, Portuguese, Spanish, Italian        |
| Tests           | Vitest, React Testing Library, MSW                            |
| Catalogue       | Storybook, sharing the MSW handlers                           |

## Commands

```sh
cd assets
bun install
bun run test        # Vitest and React Testing Library
bun run check       # TypeScript
bun run build       # bundle into ../priv/static/assets
bun run storybook   # component and screen catalogue on :6006
```

`mix assets.build` runs the Bun build, so `mix setup`, `mix precommit` and
release builds pick it up without a separate step. Set `ATOLL_SKIP_ASSETS=true`
to skip it when the bundle was built elsewhere.

## How a screen is rendered

Phoenix owns every route, session and redirect. `AtollWeb.Shell` renders a small
HTML document containing an empty root element, the screen's data as JSON, and a
no-script fallback form:

```html
<div id="root"></div>
<script type="application/json" id="atoll-bootstrap">{"screen":"login", ...}</script>
```

React reads that payload and renders the matching screen. Forms post back to the
same endpoints as before, so CSRF tokens, 303 redirects and the OAuth callback
are unchanged, and the flows still work with JavaScript disabled.

The payload shapes are declared in `assets/src/bootstrap.ts` and must match what
the controllers send. Server messages travel as codes (`invalid_credentials`,
`authorize_request_invalid`, …) and are translated in the browser, so every
language sees the same error in its own words.

Two reads go through TanStack Query against public XRPC endpoints:
`com.atproto.server.describeServer` for handle domains and policy links, and
`com.atproto.identity.resolveHandle` for live username availability during
signup.

## Content security policy

Account pages allow `script-src 'self'` for the bundle and `font-src 'self'` for
the self-hosted font. `style-src` also allows `'unsafe-inline'`, which HeroUI and
its animations require for element style attributes. Inline *scripts* remain
forbidden, and the bootstrap payload is a non-executable JSON block with its
markup escaped.

## Translations

Locale files live in `assets/src/i18n/locales`. Every locale carries the same
keys — a test enforces it — so adding a string means adding it to all five. The
language selector persists a choice; otherwise the browser's languages decide.

## Nix

`nix/bun-deps.nix` is generated from `assets/bun.lock` by `scripts/bun2nix.py`.
Bun records an SRI hash for each package, so the Nix build fetches them without
network access at evaluation time and without a second lockfile. Regenerate it
whenever `bun.lock` changes:

```sh
python3 scripts/bun2nix.py
```

CI fails if the generated file is out of date.
