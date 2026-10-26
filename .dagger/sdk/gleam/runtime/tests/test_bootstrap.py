"""Engine-free regression coverage for schema-less module runtime loading."""
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


class Graph:
    def __init__(self, existing=False):
        self.existing = existing
        self.calls = []

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return self
        return call

    async def exists(self, path):
        return self.existing

    async def entries(self):
        return ["gleam.toml", "src"]

    async def contents(self):
        return 'name = "project_ci"\n[dependencies]\ndagger = { path = "dagger_sdk" }\n'


class ModuleSource:
    async def module_name(self):
        return "ProjectCi"

    async def source_subpath(self):
        return ".dagger/ci"

    def context_directory(self):
        return Graph()


class BootstrapTest(unittest.IsolatedAsyncioTestCase):
    async def run_runtime(self, existing, schema):
        graph = Graph(existing)
        fake = types.ModuleType("dagger")
        fake.dag = graph
        fake.function = fake.object_type = lambda value: value
        fake.Directory = fake.Container = fake.File = fake.ModuleSource = fake.GeneratedCode = fake.Workspace = Graph
        path = Path(__file__).parents[1] / "src/main/__init__.py"
        spec = importlib.util.spec_from_file_location("bootstrap_under_test", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"dagger": fake}):
            spec.loader.exec_module(module)
        sdk = module.GleamSdk()
        async def source():
            return Graph()
        sdk._source = source
        await sdk.module_runtime(ModuleSource(), Graph() if schema else None)
        return graph.calls

    async def test_clean_checkout_without_schema(self):
        calls = await self.run_runtime(False, False)
        install = next(i for i, (name, args, _) in enumerate(calls)
                       if name == "with_directory" and args[0] == "dagger_sdk")
        resolve = next(i for i, (name, args, _) in enumerate(calls)
                       if name == "with_exec" and args[0] == ["gleam", "deps", "download"])
        self.assertLess(install, resolve)
        self.assertTrue(any(name == "with_new_file" and args[0] == "dagger_sdk_entrypoint.sh"
                            for name, args, _ in calls))
        self.assertFalse(any(name == "with_file" for name, _, _ in calls))

    async def test_preserves_generated_bindings_without_schema(self):
        calls = await self.run_runtime(True, False)
        self.assertFalse(any(name == "with_directory" and args[0] == "dagger_sdk"
                             for name, args, _ in calls))
        self.assertTrue(any(name == "with_new_file" and args[0] == "dagger_sdk_entrypoint.sh"
                            for name, args, _ in calls))

    async def test_schema_regenerates_bindings(self):
        calls = await self.run_runtime(True, True)
        self.assertTrue(any(name == "with_exec" and args[0][0:2] == ["python3", "dagger_sdk/codegen/generate.py"]
                            for name, args, _ in calls))


if __name__ == "__main__":
    unittest.main()
