import json
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.request import Request, urlopen

from RecipeWebService.app import (
    RecipeGenerator,
    RecipeHTTPServer,
    RecipeRepository,
    RecipeRequest,
    RecipeService,
    RecipeValidationError,
    make_handler,
)


def make_recipe(
    recipe_id: str = "com.example.demo",
    name: str = "Demo",
    bundle_id: str | None = "com.example.demo",
    official_host: str | None = "example.com",
) -> dict:
    return {
        "id": recipe_id,
        "name": name,
        "recipePrompt": "测试规则",
        "match": {
            "bundleIdentifier": bundle_id,
            "appName": name,
            "officialHost": official_host,
        },
        "checks": [
            {
                "url": "https://example.com/releases",
                "extract": {
                    "type": "regex",
                    "pattern": "version ([0-9.]+)",
                    "versionGroup": 1,
                },
            }
        ],
        "updatePageURL": "https://example.com/download",
        "download": None,
    }


class StubGenerator(RecipeGenerator):
    def __init__(self, recipe: dict):
        self.recipe = recipe
        self.calls: list[RecipeRequest] = []

    def generate(self, request: RecipeRequest) -> dict:
        self.calls.append(request)
        return self.recipe


class RecipeRepositoryTests(unittest.TestCase):
    def test_existing_path_only_database_is_migrated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            database = root / "recipes.sqlite3"
            built_in.mkdir()
            generated.mkdir()
            (built_in / "demo.json").write_text(
                json.dumps(make_recipe()), encoding="utf-8"
            )
            with sqlite3.connect(database) as connection:
                connection.execute(
                    """
                    CREATE TABLE recipes (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        normalized_name TEXT NOT NULL,
                        bundle_identifier TEXT,
                        normalized_bundle_identifier TEXT,
                        official_host TEXT,
                        source TEXT NOT NULL,
                        source_path TEXT NOT NULL,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )
                    """
                )

            repository = RecipeRepository([built_in], generated, database)
            result = repository.find(RecipeRequest("Demo", "com.example.demo", None))

            self.assertIsNotNone(result)
            with sqlite3.connect(database) as connection:
                stored_json = connection.execute(
                    "SELECT recipe_json FROM recipes WHERE id = ?",
                    ("com.example.demo",),
                ).fetchone()[0]
            self.assertEqual(json.loads(stored_json), make_recipe())

    def test_database_stores_recipe_path_and_json_body(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            recipe_path = built_in / "demo.json"
            recipe_path.write_text(json.dumps(make_recipe()), encoding="utf-8")

            repository = RecipeRepository([built_in], generated)
            with sqlite3.connect(repository.database_path) as connection:
                columns = {
                    row[1] for row in connection.execute("PRAGMA table_info(recipes)")
                }
                stored_path = connection.execute(
                    "SELECT source_path FROM recipes WHERE id = ?",
                    ("com.example.demo",),
                ).fetchone()[0]
                stored_file_name = connection.execute(
                    "SELECT file_name FROM recipes WHERE id = ?",
                    ("com.example.demo",),
                ).fetchone()[0]
                stored_json = connection.execute(
                    "SELECT recipe_json FROM recipes WHERE id = ?",
                    ("com.example.demo",),
                ).fetchone()[0]

            self.assertIn("recipe_json", columns)
            self.assertEqual(stored_path, str(recipe_path))
            self.assertEqual(stored_file_name, "demo.json")
            self.assertEqual(json.loads(stored_json), make_recipe())

    def test_missing_json_file_is_restored_from_database_body(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generated = root / "generated"
            database = root / "recipes.sqlite3"
            repository = RecipeRepository([], generated, database)
            missing_path = root / "cdn" / "demo.json"
            recipe = make_recipe()
            with repository._connect() as connection:
                repository._upsert(connection, recipe, missing_path, "generated")

            restored_repository = RecipeRepository([], generated, database)
            record = restored_repository.find(
                RecipeRequest("Demo", "com.example.demo", None)
            )

            self.assertIsNotNone(record)
            self.assertTrue(missing_path.is_file())
            self.assertEqual(json.loads(missing_path.read_text()), recipe)

    def test_query_uses_database_without_rescanning_or_rereading_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            recipe_path = built_in / "demo.json"
            recipe_path.write_text(
                json.dumps(make_recipe()), encoding="utf-8"
            )
            repository = RecipeRepository([built_in], generated)
            repository._read_directory = lambda *_: self.fail("查询时不应扫描目录")
            recipe_path.write_text("{broken", encoding="utf-8")

            result = repository.find(RecipeRequest("Demo", "com.example.demo", None))

            self.assertIsNotNone(result)

    def test_bundle_identifier_has_priority_over_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            (built_in / "demo.json").write_text(
                json.dumps(make_recipe()), encoding="utf-8"
            )

            repository = RecipeRepository([built_in], generated)
            result = repository.find(
                RecipeRequest("Wrong Name", "com.example.demo", None)
            )

            self.assertIsNotNone(result)
            self.assertEqual(result.recipe["id"], "com.example.demo")

    def test_generated_recipe_overrides_built_in_recipe_with_same_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            (built_in / "demo.json").write_text(
                json.dumps(make_recipe(name="Old Demo")), encoding="utf-8"
            )
            (generated / "demo.json").write_text(
                json.dumps(make_recipe(name="New Demo")), encoding="utf-8"
            )

            recipes = RecipeRepository([built_in], generated).load()

            self.assertEqual(len(recipes), 1)
            self.assertEqual(recipes[0].recipe["name"], "New Demo")
            self.assertEqual(recipes[0].source, "generated")

    def test_name_and_website_can_match_without_bundle_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            recipe = make_recipe(bundle_id=None)
            (built_in / "demo.json").write_text(json.dumps(recipe), encoding="utf-8")

            result = RecipeRepository([built_in], generated).find(
                RecipeRequest("demo", None, "https://www.example.com/products/demo")
            )

            self.assertIsNotNone(result)

    def test_name_does_not_hide_conflicting_bundle_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            (built_in / "demo.json").write_text(
                json.dumps(make_recipe()), encoding="utf-8"
            )

            result = RecipeRepository([built_in], generated).find(
                RecipeRequest("Demo", "com.example.other", None)
            )

            self.assertIsNone(result)


class RecipeServiceTests(unittest.TestCase):
    def test_resolve_returns_existing_recipe_without_generation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            built_in = root / "built-in"
            generated = root / "generated"
            built_in.mkdir()
            generated.mkdir()
            recipe = make_recipe()
            (built_in / "demo.json").write_text(json.dumps(recipe), encoding="utf-8")
            generator = StubGenerator(make_recipe(name="Generated"))
            service = RecipeService(RecipeRepository([built_in], generated), generator)

            result = service.resolve(RecipeRequest("Demo", "com.example.demo", None))

            self.assertFalse(result.generated)
            self.assertEqual(generator.calls, [])

    def test_resolve_generates_validates_and_persists_missing_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generated = root / "generated"
            recipe = make_recipe()
            generator = StubGenerator(recipe)
            service = RecipeService(RecipeRepository([], generated), generator)

            result = service.resolve(
                RecipeRequest("Demo", "com.example.demo", "https://example.com")
            )

            self.assertTrue(result.generated)
            self.assertEqual(result.record.recipe, recipe)
            saved_files = list(generated.glob("*.json"))
            self.assertEqual(len(saved_files), 1)
            self.assertEqual(json.loads(saved_files[0].read_text()), recipe)

    def test_rejects_generated_recipe_that_does_not_match_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / "generated"
            generator = StubGenerator(
                make_recipe(recipe_id="com.other", name="Other", bundle_id="com.other")
            )
            service = RecipeService(RecipeRepository([], generated), generator)

            with self.assertRaises(RecipeValidationError):
                service.resolve(RecipeRequest("Demo", "com.example.demo", None))

            self.assertFalse(generated.exists())

    def test_app_name_is_required(self) -> None:
        with self.assertRaises(RecipeValidationError):
            RecipeRequest.from_mapping({"appName": "  "})


class RecipeHTTPTests(unittest.TestCase):
    def test_search_resolve_and_download(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / "generated"
            service = RecipeService(
                RecipeRepository([], generated), StubGenerator(make_recipe())
            )
            server = RecipeHTTPServer(("127.0.0.1", 0), make_handler(service))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = f"http://127.0.0.1:{server.server_port}"
            try:
                with urlopen(f"{base_url}/api/recipes/search?appName=Demo") as response:
                    self.assertEqual(json.load(response), {"found": False})

                request = Request(
                    f"{base_url}/api/recipes/resolve",
                    data=json.dumps(
                        {"appName": "Demo", "bundleId": "com.example.demo"}
                    ).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urlopen(request) as response:
                    self.assertEqual(response.status, 201)
                    payload = json.load(response)
                self.assertTrue(payload["generated"])
                self.assertEqual(payload["downloadURL"], "/recipes/com.example.demo-adb2f015.json")

                with urlopen(base_url + payload["downloadURL"]) as response:
                    downloaded = json.load(response)
                self.assertEqual(downloaded["id"], "com.example.demo")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
