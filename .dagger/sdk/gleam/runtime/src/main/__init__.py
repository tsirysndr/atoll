"""Dagger SDK bootstrap: scaffolding and compilation for Gleam modules.

Python is used only for the SDK's bootstrap hooks. User functions, schema
registration, argument decoding, and invocation run in Gleam on Erlang.
"""
from pathlib import PurePosixPath
import re
import json
import posixpath
import tomllib

import dagger
from dagger import dag, function, object_type


@object_type
class GleamSdk:
    async def _source(self) -> dagger.Directory:
        subpath = await dag.current_module().source_subpath()
        return dag.current_module().context_directory().directory(posixpath.dirname(subpath) or ".")

    async def _common(
        self, mod_source: dagger.ModuleSource, introspection_json: dagger.File | None
    ) -> tuple[dagger.Container, str, str]:
        sdk_source = await self._source()
        name = await mod_source.module_name()
        subpath = await mod_source.source_subpath()
        # Both paths are engine-provided, but ensure neither escapes /src.
        relative = PurePosixPath(subpath or ".")
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Invalid module source subpath: {subpath!r}")
        workdir = str(PurePosixPath("/src") / relative)
        package = re.sub(r"[^a-z0-9]+", "_", re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()).strip("_")
        if not package or not package[0].isalpha():
            package = "module_" + package
        # Avoid colliding with the SDK package and reserve a fixed entrypoint.
        if package == "dagger":
            package = "dagger_module"
        object_name = "".join(word[:1].upper() + word[1:] for word in package.split("_"))
        base = (
            dag.container()
            .from_("ghcr.io/gleam-lang/gleam:v1.18.0-erlang")
            .with_exec(["sh", "-c", "if ! command -v python3 >/dev/null; then if command -v apk >/dev/null; then apk add --no-cache python3; else apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates; fi; fi"])
            .with_directory("/src", mod_source.context_directory())
            .with_workdir(workdir)
        )
        # Runtime loading can omit introspection even on a clean checkout.
        # Preserve generated dependency bindings when present, otherwise use
        # the bundled core API. Always create the shipment launcher below.
        if introspection_json is not None or not await base.directory(".").exists("dagger_sdk/gleam.toml"):
            base = base.with_directory(
                "dagger_sdk", sdk_source, exclude=["build", "test", "examples", "runtime"]
            )
        if introspection_json is not None:
            base = (base
                .with_file("/schema.json", introspection_json)
                .with_exec(["python3", "dagger_sdk/codegen/generate.py", "/schema.json", "--output", "dagger_sdk/src/dagger"])
            )
        entries = await base.directory(".").entries()
        if "gleam.toml" not in entries:
            template = sdk_source.directory("runtime/template")
            config = (await template.file("gleam.toml").contents()).replace("__PACKAGE__", package)
            source = (await template.file("main.gleam").contents()).replace("__OBJECT__", object_name)
            base = base.with_new_file("gleam.toml", config).with_new_file("src/dagger_main.gleam", source)
        else:
            # Existing projects opt in explicitly instead of having their files overwritten.
            config = await base.file("gleam.toml").contents()
            if tomllib.loads(config).get("dependencies", {}).get("dagger") != {"path": "dagger_sdk"}:
                raise ValueError('Existing gleam.toml must include dagger = { path = "dagger_sdk" } in [dependencies]')
        actual_package = tomllib.loads(config)["name"]
        if not re.fullmatch(r"[a-z][a-z0-9_]*", actual_package):
            raise ValueError("Invalid Gleam package name")
        # Shipment scripts always invoke the package's main module; this SDK
        # reserves dagger_main so existing applications can keep their main().
        launcher = (
            '#!/bin/sh\nset -eu\n'
            'BASE="$(dirname "$0")/build/erlang-shipment"\n'
            f'exec erl -pa "$BASE"/*/ebin -noshell -eval "\'{actual_package}@@main\':run(dagger_main)"\n'
        )
        base = base.with_new_file("dagger_sdk_entrypoint.sh", launcher)
        return base, subpath, workdir

    @function
    async def codegen(
        self, mod_source: dagger.ModuleSource, introspection_json: dagger.File
    ) -> dagger.GeneratedCode:
        container, _, _ = await self._common(mod_source, introspection_json)
        return (
            dag.generated_code(container.directory("/src"))
            .with_vcs_generated_paths(["dagger_sdk/**", "dagger_sdk_entrypoint.sh"])
            .with_vcs_ignored_paths(["build", "erl_crash.dump"])
        )

    @function
    async def module_runtime(
        self, mod_source: dagger.ModuleSource, introspection_json: dagger.File | None = None
    ) -> dagger.Container:
        container, _, workdir = await self._common(mod_source, introspection_json)
        return (
            container
            .with_exec(["gleam", "deps", "download"])
            .with_exec(["gleam", "build"])
            .with_exec(["gleam", "export", "erlang-shipment"])
            .with_entrypoint(["sh", f"{workdir}/dagger_sdk_entrypoint.sh"])
        )

    @function
    async def find_client_root(self, ws: dagger.Workspace) -> str | None:
        """Find the nearest Gleam package in this workspace."""
        marker = await ws.find_up("gleam.toml")
        return (posixpath.dirname(marker).lstrip("/") or ".") if marker else None

    @function
    async def generate_scope(
        self, ws: dagger.Workspace, is_module: bool, name: str,
        clients: list[dagger.ModuleSource],
    ) -> dagger.Workspace:
        """Generate module configuration and dependency bindings ahead of execution."""
        if not is_module:
            raise ValueError("Standalone scopes are not supported yet; use a Gleam module scope")
        cwd = await ws.cwd()
        ref = await ws.sdk("gleam").ref()
        if ref.startswith((".", "/")) or not any(c in ref.split("/")[0] for c in ".:@"):
            ref = posixpath.relpath("/" + ref.lstrip("/"), "/" + cwd.lstrip("/"))
        if not await ws.directory(".").exists("dagger-module.toml"):
            manifest = (f"name = {json.dumps(name)}\n"
                        'engineVersion = "v1.0.0-beta.21"\n'
                        f"[runtime]\nsource = {json.dumps(ref)}\n")
            ws = ws.with_new_file("dagger-module.toml", manifest)
        source = ws.module_source("/" + cwd.lstrip("/")).with_name(name).with_sdk(ref).with_dependencies(clients)
        root = await source.source_root_subpath()
        return ws.with_directory(".", source.generated_context_directory().directory(root))
