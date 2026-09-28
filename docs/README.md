# Atoll documentation site

The Markdown files in this directory are both the source of truth and the
source of a static site, built with [Lume](https://lume.land) on Deno.

## Commands

```sh
deno task serve    # build + dev server with live reload on http://localhost:3000
deno task build    # build once into _site/
```

Set `SITE_URL` when building for a real host so absolute URLs (the sitemap) are
correct:

```sh
SITE_URL=https://docs.example.com deno task build
```

Deploy the contents of `_site/` to any static host.

## Layout

| Path                    | Purpose                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `*.md`                  | Page content; the first `# Heading` becomes the page title    |
| `_config.ts`            | Lume config: sidebar order, TOC, link rewriting, search index |
| `_data.yml`             | Applies the default layout to every page                      |
| `_includes/layouts/`    | Vento templates (`base`, `doc`, `home`)                       |
| `assets/`               | Stylesheet, client script, logo, favicon                      |
| `_site/`                | Build output (git-ignored)                                    |

## Adding a page

1. Add `your-page.md` with a single `# Title` as the first line.
2. Add an entry to the `sidebar` array in `_config.ts`. The array also drives
   the previous/next links at the foot of each page.

Pages need no front matter. Links between documents are written as ordinary
relative Markdown links (`[keys](keys.md)`) and resolved to clean URLs at build
time; links to files outside this directory (`../ops/...`) are rewritten to the
repository.
