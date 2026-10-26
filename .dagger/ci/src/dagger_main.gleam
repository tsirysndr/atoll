import ci
import dagger/client
import dagger/container
import dagger/directory
import dagger/mod
import dagger/mod/argument
import dagger/mod/codec
import dagger/types
import gleam/result

fn elixir(
  context: mod.Context,
  source: types.Directory,
  database: String,
) -> types.Container {
  ci.image(
    context.client,
    "hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim",
  )
  |> ci.commands([
    ["apt-get", "update"],
    [
      "apt-get",
      "install",
      "-y",
      "--no-install-recommends",
      "build-essential",
      "git",
      "curl",
      "ca-certificates",
      "python3",
      "chromium",
    ],
    ["mix", "local.hex", "--force"],
    ["mix", "local.rebar", "--force"],
  ])
  |> container.with_file(
    "/usr/local/bin/bun",
    ci.image(context.client, "oven/bun:1.4.2")
      |> container.file("/usr/local/bin/bun"),
  )
  |> container.with_file(
    "/usr/local/bin/node",
    ci.node(context.client) |> container.file("/usr/local/bin/node"),
  )
  |> container.with_env_variable("MIX_ENV", "test")
  |> container.with_env_variable("ATOLL_DATABASE", database)
  |> container.with_env_variable("ATOLL_BLOB_STORAGE", "postgres")
  |> container.with_env_variable("ATOLL_BLOB_CLEANUP_ENABLED", "false")
  |> container.with_env_variable("ATOLL_IDENTITY_REFRESH_ENABLED", "false")
  |> container.with_mounted_cache(
    "/root/.hex",
    client.cache_volume(context.client, "atoll-hex"),
  )
  |> container.with_mounted_cache(
    "/root/.bun/install/cache",
    client.cache_volume(context.client, "atoll-bun"),
  )
  |> container.with_directory("/src", ci.clean(source))
  |> container.with_workdir("/src")
  // A disposable index checks every source file after precommit and supplies
  // revision metadata to the existing recovery tests. No host Git data enters CI.
  |> ci.commands([
    ["git", "init"],
    ["git", "add", "."],
    [
      "git",
      "-c",
      "user.name=Dagger CI",
      "-c",
      "user.email=ci@example.invalid",
      "commit",
      "-m",
      "Test source snapshot",
    ],
    ["mix", "deps.get"],
    ["mix", "format", "--check-formatted"],
  ])
}

pub fn sqlite(
  context: mod.Context,
  source: types.Directory,
) -> Result(String, codec.Error) {
  elixir(context, source, "sqlite")
  |> ci.commands([["mix", "precommit"], ["git", "diff", "--exit-code"]])
  |> ci.finish
}

pub fn postgres(
  context: mod.Context,
  source: types.Directory,
) -> Result(String, codec.Error) {
  let db =
    ci.image(context.client, "postgres:18.6-bookworm")
    |> container.with_env_variable("POSTGRES_PASSWORD", "postgres")
    |> container.with_exposed_port(5432)
    |> container.as_service
  let minio =
    source
    |> directory.directory("scripts/minio")
    |> directory.docker_build
    |> container.with_env_variable("MINIO_ROOT_USER", "atoll-test")
    |> container.with_env_variable(
      "MINIO_ROOT_PASSWORD",
      "atoll-minio-test-only",
    )
    |> container.with_default_args(["server", "/data"])
    |> container.with_exposed_port(9000)
    |> container.as_service
  let tested =
    elixir(context, source, "postgres")
    |> container.with_service_binding("postgres", db)
    |> container.with_service_binding("minio", minio)
    |> container.with_env_variable("PGHOST", "postgres")
    |> container.with_env_variable("PGUSER", "postgres")
    |> container.with_env_variable("PGPASSWORD", "postgres")
    |> container.with_env_variable(
      "ATOLL_MINIO_TEST_ENDPOINT",
      "http://minio:9000",
    )
    |> container.with_env_variable("CHROME_BIN", "chromium")
    |> container.with_env_variable("ATOLL_BROWSER_NO_SANDBOX", "true")
    |> container.with_exec([
      "curl",
      "-fsSL",
      "https://www.postgresql.org/media/keys/ACCC4CF8.asc",
      "-o",
      "/usr/share/keyrings/pgdg.asc",
    ])
    |> container.with_new_file(
      "/etc/apt/sources.list.d/pgdg.list",
      "deb [signed-by=/usr/share/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main\n",
    )
    |> ci.commands([
      ["apt-get", "update"],
      [
        "apt-get",
        "install",
        "-y",
        "--no-install-recommends",
        "postgresql-client-18",
      ],
      ["mix", "precommit"],
      ["python3", "scripts/test_recovery_set.py"],
      ["python3", "scripts/test_database_backup.py"],
      ["python3", "scripts/test_atoll_database_backup.py"],
      [
        "mix",
        "test",
        "--include",
        "browser",
        "test/atoll_web/passkey_browser_e2e_test.exs",
      ],
      [
        "mix",
        "test",
        "--only",
        "minio",
        "test/atoll/blobs_minio_test.exs",
        "test/atoll_web/controllers/blob_upload_controller_test.exs",
      ],
      ["python3", "scripts/test_atoll_database_backup.py", "--s3"],
      ["git", "diff", "--exit-code"],
    ])
  use _ <- result.try(ci.finish(tested))
  use metrics <- result.try(
    tested
    |> container.with_exec([
      "mix",
      "run",
      "--no-start",
      "--no-compile",
      "scripts/metrics_fixture.exs",
    ])
    |> container.stdout
    |> result.map_error(codec.SdkError),
  )
  ci.image(
    context.client,
    "prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996",
  )
  |> container.with_directory(
    "/rules",
    directory.directory(source, "ops/prometheus"),
  )
  |> container.with_workdir("/rules")
  |> ci.commands([
    ["/bin/promtool", "check", "rules", "alerts.yml"],
    ["/bin/promtool", "test", "rules", "alerts.test.yml"],
  ])
  |> container.with_exec_with(["/bin/promtool", "check", "metrics"], [
    container.WithExecStdin(metrics),
  ])
  |> ci.finish
}

pub fn frontend(
  context: mod.Context,
  source: types.Directory,
) -> Result(String, codec.Error) {
  let built =
    ci.frontend(context.client, source, "assets")
    |> container.with_exec(["bun", "run", "storybook:build"])
    |> container.with_workdir("/src")
    |> ci.commands([
      ["apt-get", "update"],
      ["apt-get", "install", "-y", "--no-install-recommends", "python3"],
      ["python3", "scripts/bun2nix.py"],
    ])
  ci.unchanged(
    directory.directory(source, "nix"),
    container.directory(built, "/src/nix"),
  )
}

pub fn nix(
  context: mod.Context,
  args: #(types.Directory, String),
) -> Result(String, codec.Error) {
  let #(source, target) = args
  case target {
    "sqlite" | "postgres" ->
      ci.nix(context.client, source, "atoll-" <> target)
      |> container.with_env_variable("RELEASE_COOKIE", "nix-smoke-test")
      |> ci.commands([
        ["nix", "build", ".#" <> target, "--print-build-logs"],
        ["./result/bin/atoll", "version"],
        ["nix", "develop", ".#" <> target, "--command", "mix", "--version"],
      ])
      |> ci.finish
    _ -> Error(codec.FunctionError("Target must be sqlite or postgres"))
  }
}

pub fn main() {
  let source = argument.required("source", directory.codec())
  let root =
    mod.object("ProjectCi")
    |> mod.with_function(mod.function(
      "postgres",
      source,
      codec.string(),
      postgres,
    ))
    |> mod.with_function(mod.function("sqlite", source, codec.string(), sqlite))
    |> mod.with_function(mod.function(
      "frontend",
      source,
      codec.string(),
      frontend,
    ))
    |> mod.with_function(mod.function(
      "nix",
      argument.pair(source, argument.required("target", codec.string())),
      codec.string(),
      nix,
    ))
  ci.serve(root)
}
