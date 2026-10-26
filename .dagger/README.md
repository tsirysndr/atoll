# Dagger CI

The thin entrypoint `.dagger/ci/src/dagger_main.gleam` starts the module. Pipeline registration lives in `src/project_ci.gleam`, with checks in `src/*_checks.gleam` modules and shared container helpers kept separately. The Gleam SDK is vendored in `.dagger/sdk/`. GitHub Actions supplies the checkout and Dagger CLI; containers supply the build tools.

Use Dagger **v1.0.0-beta.21** with a supported container engine:

```sh
cd .dagger
dagger api call -m ci postgres --source ..
dagger api call -m ci sqlite --source ..
dagger api call -m ci frontend --source ..
dagger api call -m ci nix --target sqlite --source ..
dagger api call -m ci nix --target postgres --source ..
```

Functions return success only after the checks finish. Build, test, and service errors fail the workflow. Node-based tools use **Node 24**, and Bun is pinned to 1.4.2. Image manifests are pinned in `dagger.lock`.

Dagger manages service lifetimes and private networking. Named cache volumes stay inside the Dagger engine; these workflows do not snapshot or upload volumes to GitHub Actions cache. A fresh hosted runner may start with cold caches. Module requests allow up to one hour, with the GitHub job timeout providing the outer limit.

## Editing the pipeline

Keep orchestration in the module language and invoke tools with argument arrays. SDK-generated bindings are ignored under the module directory. Dagger generates them automatically when loading the module. The SDK provenance and licenses are under `.dagger/sdk/`.

For an engine-free syntax/type check against the vendored API snapshot:

```sh
cd .dagger/ci
mkdir -p dagger_sdk
cp -R ../sdk/gleam/. dagger_sdk/
gleam format --check src
gleam check
gleam run -m content_check
```

The PostgreSQL check provisions PostgreSQL 18 and MinIO as Dagger services and runs `mix precommit`, browser tests, restore drills, and Prometheus validation. The SQLite check runs `mix precommit` separately. `PGHOST` selects the test database host, defaulting to localhost for development. `ATOLL_BROWSER_NO_SANDBOX=true` is set only for the disposable browser test container; normal local browser tests retain Chromium's sandbox.

The frontend check verifies the generated Nix dependency file. Nix release checks preserve both database variants. Native multi-architecture image publishing remains in the existing Docker workflow.

Generated-file checks compare relative file paths and content-only hashes, ignoring filesystem ownership and permissions. Failures list the changed, added, or removed files. Engine-free regression tests cover these cases.
