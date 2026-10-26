import dagger
import dagger/cache_sharing_mode
import dagger/client
import dagger/connection
import dagger/container
import dagger/directory
import dagger/file
import dagger/mod
import dagger/mod/codec
import dagger/types
import gleam/dict
import gleam/list
import gleam/result
import gleam/string

pub fn image(client: types.Query, address: String) -> types.Container {
  client |> client.container |> container.from(address)
}

pub fn clean(source: types.Directory) -> types.Directory {
  list.fold(
    [
      ".git",
      ".dagger",
      "target",
      "_build",
      "deps",
      "node_modules",
      "ui/node_modules",
      "assets/node_modules",
      "frontend/node_modules",
      "interop/node_modules",
      ".elixir_ls",
      ".cpcache",
    ],
    source,
    fn(source, path) { directory.without_directory(source, path) },
  )
}

pub fn commands(
  ctr: types.Container,
  commands: List(List(String)),
) -> types.Container {
  list.fold(commands, ctr, container.with_exec)
}

pub fn finish(ctr: types.Container) -> Result(String, codec.Error) {
  ctr
  |> container.sync
  |> result.map(fn(_) { "Checks passed" })
  |> result.map_error(codec.SdkError)
}

pub fn node(client: types.Query) -> types.Container {
  image(client, "node:24-bookworm-slim")
  |> container.with_file(
    "/usr/local/bin/bun",
    image(client, "oven/bun:1.4.2") |> container.file("/usr/local/bin/bun"),
  )
}

pub fn frontend(
  client: types.Query,
  source: types.Directory,
  path: String,
) -> types.Container {
  node(client)
  |> container.with_mounted_cache(
    "/root/.bun/install/cache",
    client.cache_volume(client, "frontend-bun-1.4.2"),
  )
  |> container.with_directory("/src", clean(source))
  |> container.with_workdir("/src/" <> path)
  |> commands([
    ["bun", "install", "--frozen-lockfile"],
    ["bun", "run", "check"],
    ["bun", "run", "test"],
    ["bun", "run", "build"],
  ])
}

// Directory digests include ownership and permissions. Compare paths and file
// bytes so rebuilding a bundle as root does not invalidate unchanged assets.
fn content_manifest(
  source: types.Directory,
) -> Result(List(#(String, String)), codec.Error) {
  use paths <- result.try(
    directory.glob(source, "**") |> result.map_error(codec.SdkError),
  )
  paths
  |> list.filter(fn(path) { !string.ends_with(path, "/") })
  |> list.sort(string.compare)
  |> list.try_map(fn(path) {
    use digest <- result.try(
      directory.file(source, path)
      |> file.digest_with([file.DigestExcludeMetadata(True)])
      |> result.map_error(codec.SdkError),
    )
    Ok(#(path, digest))
  })
}

pub fn unchanged(
  before: types.Directory,
  after: types.Directory,
) -> Result(String, codec.Error) {
  use old <- result.try(content_manifest(before))
  use new <- result.try(content_manifest(after))
  let old = dict.from_list(old)
  let new = dict.from_list(new)
  let changed =
    list.append(dict.keys(old), dict.keys(new))
    |> list.unique
    |> list.sort(string.compare)
    |> list.filter(fn(path) { dict.get(old, path) != dict.get(new, path) })
  case changed {
    [] -> Ok("Generated files match committed files")
    _ ->
      Error(codec.FunctionError(
        "Generated files differ from committed files: "
        <> string.join(changed, ", ")
        <> ". Regenerate and commit them.",
      ))
  }
}

pub fn nix(
  client: types.Query,
  source: types.Directory,
  name: String,
) -> types.Container {
  let base = image(client, "nixos/nix:2.28.5")
  base
  |> container.with_mounted_cache_with(
    "/nix",
    client.cache_volume(client, name <> "-nix-2.28.5"),
    [
      container.WithMountedCacheSource(container.directory(base, "/nix")),
      container.WithMountedCacheSharing(cache_sharing_mode.Locked),
    ],
  )
  |> container.with_env_variable("NIX_REMOTE", "local")
  |> container.with_env_variable(
    "NIX_CONFIG",
    "experimental-features = nix-command flakes\nsandbox = false\nbuild-users-group =\n",
  )
  |> container.with_directory("/src", clean(source))
  |> container.with_workdir("/src")
}

// Builds can legitimately take longer than the SDK's five-minute default.
pub fn serve(root: mod.Object) {
  let assert Ok(connection) = connection.connect_with_timeout(3_600_000)
  let client = dagger.from_connection(connection)
  let outcome = mod.serve_with_client(client, root, [])
  dagger.close(client)
  let assert Ok(_) = outcome
}
