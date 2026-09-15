#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import sqlite3
import subprocess
import tempfile
import threading
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from typing import Any, Mapping
from urllib.parse import parse_qs, quote, unquote, urlparse


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATIC_ROOT = Path(__file__).resolve().parent / "static"
GENERATION_PROMPT_PATH = Path(__file__).resolve().parent / "recipe-generation-prompt.md"
GENERATION_SCHEMA_PATH = Path(__file__).resolve().parent / "recipe-schema.json"
DEFAULT_BUILT_IN_DIRECTORY = PROJECT_ROOT / "Resources" / "UpdateRecipes"
DEFAULT_GENERATED_DIRECTORY = (
    Path.home() / "Library" / "Application Support" / "AppMan" / "update-recipes"
)
DEFAULT_DATABASE_PATH = (
    Path.home() / "Library" / "Application Support" / "AppMan" / "recipe-web-service.sqlite3"
)
MAX_REQUEST_BYTES = 16 * 1024


class RecipeHTTPServer(ThreadingHTTPServer):
    """避免 HTTPServer 启动时为监听地址执行可能很慢的反向 DNS 查询。"""

    def server_bind(self) -> None:
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class RecipeError(Exception):
    pass


class RecipeValidationError(RecipeError):
    pass


class RecipeGenerationError(RecipeError):
    pass


@dataclass(frozen=True)
class RecipeRequest:
    app_name: str
    bundle_id: str | None
    website: str | None

    def __post_init__(self) -> None:
        app_name = self.app_name.strip()
        bundle_id = self.bundle_id.strip() if self.bundle_id else None
        website = self.website.strip() if self.website else None
        if not app_name:
            raise RecipeValidationError("App 名称不能为空")
        if len(app_name) > 120:
            raise RecipeValidationError("App 名称不能超过 120 个字符")
        if bundle_id and len(bundle_id) > 255:
            raise RecipeValidationError("Bundle ID 不能超过 255 个字符")
        if website:
            parsed = urlparse(website)
            if parsed.scheme not in {"http", "https"} or not parsed.hostname:
                raise RecipeValidationError("官网必须是完整的 HTTP 或 HTTPS 地址")
        object.__setattr__(self, "app_name", app_name)
        object.__setattr__(self, "bundle_id", bundle_id)
        object.__setattr__(self, "website", website)

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "RecipeRequest":
        return cls(
            app_name=str(value.get("appName") or ""),
            bundle_id=_optional_string(value.get("bundleId")),
            website=_optional_string(value.get("website")),
        )

    @property
    def key(self) -> str:
        return "\0".join(
            [self.app_name.casefold(), (self.bundle_id or "").casefold(), self.website or ""]
        )


@dataclass(frozen=True)
class RecipeRecord:
    recipe: dict[str, Any]
    path: Path | None
    source: str

    def summary(self) -> dict[str, Any]:
        match = self.recipe.get("match") or {}
        return {
            "id": self.recipe["id"],
            "name": self.recipe["name"],
            "bundleId": match.get("bundleIdentifier"),
            "officialHost": match.get("officialHost"),
            "source": self.source,
        }


@dataclass(frozen=True)
class ResolveResult:
    record: RecipeRecord
    generated: bool


class RecipeRepository:
    def __init__(
        self,
        built_in_directories: list[Path],
        generated_directory: Path,
        database_path: Path | None = None,
    ):
        self.built_in_directories = built_in_directories
        self.generated_directory = generated_directory
        self.database_path = database_path or generated_directory.parent / "recipe-web-service.sqlite3"
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize_database()
        self.restore_missing_files()
        self.sync_from_files()

    def load(self) -> list[RecipeRecord]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT recipe_json, source_path, source
                FROM recipes
                ORDER BY normalized_name, id
                """
            ).fetchall()
        return [self._record_from_row(row) for row in rows]

    def find(self, request: RecipeRequest) -> RecipeRecord | None:
        normalized_bundle_id = request.bundle_id.casefold() if request.bundle_id else None
        with self._connect() as connection:
            if normalized_bundle_id:
                row = connection.execute(
                    """
                    SELECT recipe_json, source_path, source
                    FROM recipes
                    WHERE normalized_bundle_identifier = ?
                    LIMIT 1
                    """,
                    (normalized_bundle_id,),
                ).fetchone()
                if row:
                    return self._record_from_row(row)

            rows = connection.execute(
                """
                SELECT recipe_json, source_path, source, normalized_bundle_identifier, official_host
                FROM recipes
                WHERE normalized_name = ?
                """,
                (request.app_name.casefold(),),
            ).fetchall()

        request_host = _normalized_host(request.website)
        for row in rows:
            if normalized_bundle_id and row[3] and row[3] != normalized_bundle_id:
                continue
            if request_host and row[4] and not _hosts_match(request_host, row[4]):
                continue
            return self._record_from_row(row)
        return None

    def get_by_id(self, recipe_id: str) -> RecipeRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT recipe_json, source_path, source
                FROM recipes
                WHERE id = ?
                """,
                (recipe_id,),
            ).fetchone()
        return self._record_from_row(row) if row else None

    def get_by_file_name(self, file_name: str) -> RecipeRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT recipe_json, source_path, source
                FROM recipes
                WHERE file_name = ?
                LIMIT 1
                """,
                (file_name,),
            ).fetchone()
        return self._record_from_row(row) if row else None

    def save_generated(self, recipe: dict[str, Any]) -> RecipeRecord:
        self.generated_directory.mkdir(parents=True, exist_ok=True)
        slug = re.sub(r"[^A-Za-z0-9._-]+", "-", recipe["id"]).strip("-.") or "recipe"
        digest = hashlib.sha256(recipe["id"].encode("utf-8")).hexdigest()[:8]
        path = self.generated_directory / f"{slug[:100]}-{digest}.json"
        self._write_recipe_file(path, recipe)
        with self._connect() as connection:
            self._upsert(connection, recipe, path, "generated")
        return RecipeRecord(recipe=recipe, path=path, source="generated")

    def ensure_json_file(self, record: RecipeRecord) -> Path:
        if record.path is None:
            raise RecipeValidationError("数据库中的 Recipe 路径为空")
        if not record.path.is_file():
            self._write_recipe_file(record.path, record.recipe)
        return record.path

    def restore_missing_files(self) -> None:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT recipe_json, source_path, source
                FROM recipes
                WHERE recipe_json IS NOT NULL AND recipe_json != ''
                """
            ).fetchall()
        for row in rows:
            record = self._record_from_row(row)
            self.ensure_json_file(record)

    def sync_from_files(self) -> None:
        records_by_id: dict[str, RecipeRecord] = {}
        for directory in self.built_in_directories:
            for record in self._read_directory(directory, "built-in"):
                records_by_id[record.recipe["id"]] = record
        for record in self._read_directory(self.generated_directory, "generated"):
            records_by_id[record.recipe["id"]] = record

        with self._connect() as connection:
            for record in records_by_id.values():
                if record.path is None:
                    continue
                self._upsert(connection, record.recipe, record.path, record.source)

    def _read_directory(self, directory: Path, source: str) -> list[RecipeRecord]:
        if not directory.is_dir():
            return []
        records: list[RecipeRecord] = []
        for path in sorted(directory.glob("*.json")):
            try:
                recipe = json.loads(path.read_text(encoding="utf-8"))
                validate_recipe(recipe)
            except (OSError, json.JSONDecodeError, RecipeValidationError) as error:
                raise RecipeValidationError(f"Recipe 文件无效：{path.name}：{error}") from error
            records.append(RecipeRecord(recipe=recipe, path=path, source=source))
        return records

    def _initialize_database(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                CREATE TABLE IF NOT EXISTS recipes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    normalized_name TEXT NOT NULL,
                    bundle_identifier TEXT,
                    normalized_bundle_identifier TEXT,
                    official_host TEXT,
                    source TEXT NOT NULL CHECK (source IN ('built-in', 'generated')),
                    source_path TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    recipe_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS recipes_bundle_identifier_idx
                    ON recipes(normalized_bundle_identifier);
                CREATE INDEX IF NOT EXISTS recipes_name_idx
                    ON recipes(normalized_name);
                CREATE INDEX IF NOT EXISTS recipes_official_host_idx
                    ON recipes(official_host);
                """
            )
            columns = {
                row[1] for row in connection.execute("PRAGMA table_info(recipes)")
            }
            if "recipe_json" not in columns:
                connection.execute("ALTER TABLE recipes ADD COLUMN recipe_json TEXT")
            if "file_name" not in columns:
                connection.execute("ALTER TABLE recipes ADD COLUMN file_name TEXT")
            rows_without_file_name = connection.execute(
                "SELECT id, source_path FROM recipes WHERE file_name IS NULL OR file_name = ''"
            ).fetchall()
            connection.executemany(
                "UPDATE recipes SET file_name = ? WHERE id = ?",
                (
                    (Path(row["source_path"]).name, row["id"])
                    for row in rows_without_file_name
                    if row["source_path"]
                ),
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS recipes_file_name_idx ON recipes(file_name)"
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=5)
        connection.row_factory = sqlite3.Row
        return connection

    def _upsert(
        self,
        connection: sqlite3.Connection,
        recipe: dict[str, Any],
        path: Path,
        source: str,
    ) -> None:
        match = recipe.get("match") or {}
        bundle_identifier = match.get("bundleIdentifier")
        official_host = _normalized_host(match.get("officialHost"))
        connection.execute(
            """
            INSERT INTO recipes (
                id, name, normalized_name, bundle_identifier,
                normalized_bundle_identifier, official_host,
                source, source_path, file_name, recipe_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                normalized_name = excluded.normalized_name,
                bundle_identifier = excluded.bundle_identifier,
                normalized_bundle_identifier = excluded.normalized_bundle_identifier,
                official_host = excluded.official_host,
                source = excluded.source,
                source_path = excluded.source_path,
                file_name = excluded.file_name,
                recipe_json = excluded.recipe_json,
                updated_at = CURRENT_TIMESTAMP
            """,
            (
                recipe["id"],
                recipe["name"],
                recipe["name"].casefold(),
                bundle_identifier,
                bundle_identifier.casefold() if isinstance(bundle_identifier, str) else None,
                official_host,
                source,
                str(path),
                path.name,
                json.dumps(recipe, ensure_ascii=False, separators=(",", ":")),
            ),
        )

    def _write_recipe_file(self, path: Path, recipe: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        content = json.dumps(recipe, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_file.write(content)
            temporary_path = Path(temporary_file.name)
        temporary_path.replace(path)

    def _record_from_row(self, row: sqlite3.Row) -> RecipeRecord:
        source_path = row["source_path"]
        if not source_path:
            raise RecipeValidationError("数据库中的 Recipe 路径为空")
        path = Path(source_path)
        try:
            recipe = json.loads(row["recipe_json"])
            validate_recipe(recipe)
        except (TypeError, json.JSONDecodeError, RecipeValidationError) as error:
            raise RecipeValidationError(f"数据库中的 Recipe JSON 无效：{path.name}：{error}") from error
        return RecipeRecord(
            recipe=recipe,
            path=path,
            source=row["source"],
        )


class RecipeGenerator:
    def generate(self, request: RecipeRequest) -> dict[str, Any]:
        raise NotImplementedError


class CommandRecipeGenerator(RecipeGenerator):
    def __init__(self, command: str, timeout_seconds: int = 600):
        self.command = shlex.split(command)
        self.timeout_seconds = timeout_seconds
        if not self.command:
            raise RecipeGenerationError("APPMAN_RECIPE_GENERATOR_COMMAND 不能为空")

    def generate(self, request: RecipeRequest) -> dict[str, Any]:
        try:
            process = subprocess.run(
                self.command,
                input=json.dumps(_request_mapping(request), ensure_ascii=False),
                text=True,
                capture_output=True,
                timeout=self.timeout_seconds,
                check=False,
            )
        except FileNotFoundError as error:
            raise RecipeGenerationError(f"未找到内部生成命令：{self.command[0]}") from error
        except subprocess.TimeoutExpired as error:
            raise RecipeGenerationError("内部生成命令执行超时") from error
        if process.returncode != 0:
            detail = (process.stderr or process.stdout).strip()[-1500:]
            raise RecipeGenerationError(f"内部生成命令执行失败：{detail}")
        return _decode_generated_recipe(process.stdout)


class CodexRecipeGenerator(RecipeGenerator):
    def __init__(self, timeout_seconds: int = 600):
        self.timeout_seconds = timeout_seconds

    def generate(self, request: RecipeRequest) -> dict[str, Any]:
        try:
            base_prompt = GENERATION_PROMPT_PATH.read_text(encoding="utf-8")
        except OSError as error:
            raise RecipeGenerationError(f"无法读取生成流程说明：{error}") from error
        prompt = base_prompt.replace(
            "{{REQUEST_JSON}}",
            json.dumps(_request_mapping(request), ensure_ascii=False, indent=2),
        )
        with tempfile.TemporaryDirectory(prefix="appman-recipe-") as directory:
            output_path = Path(directory) / "recipe.json"
            command = [
                "codex",
                "--search",
                "--ask-for-approval",
                "never",
                "exec",
                "--ignore-user-config",
                "--ephemeral",
                "--sandbox",
                "read-only",
                "--output-schema",
                str(GENERATION_SCHEMA_PATH),
                "--output-last-message",
                str(output_path),
                "--cd",
                str(PROJECT_ROOT),
                "-",
            ]
            try:
                process = subprocess.run(
                    command,
                    input=prompt,
                    text=True,
                    capture_output=True,
                    timeout=self.timeout_seconds,
                    check=False,
                )
            except FileNotFoundError as error:
                raise RecipeGenerationError(
                    "未找到 codex 命令，请安装 Codex CLI 或配置 APPMAN_RECIPE_GENERATOR_COMMAND"
                ) from error
            except subprocess.TimeoutExpired as error:
                raise RecipeGenerationError("Recipe 生成超时") from error
            if process.returncode != 0:
                detail = (process.stderr or process.stdout).strip()[-1500:]
                raise RecipeGenerationError(f"Codex Recipe 生成失败：{detail}")
            try:
                output = output_path.read_text(encoding="utf-8")
            except OSError as error:
                raise RecipeGenerationError("Codex 未返回 Recipe JSON") from error
            return _decode_generated_recipe(output)


class RecipeService:
    def __init__(self, repository: RecipeRepository, generator: RecipeGenerator):
        self.repository = repository
        self.generator = generator
        self._generation_locks: dict[str, threading.Lock] = {}
        self._generation_locks_guard = threading.Lock()

    def search(self, request: RecipeRequest) -> RecipeRecord | None:
        return self.repository.find(request)

    def resolve(self, request: RecipeRequest) -> ResolveResult:
        if existing := self.repository.find(request):
            return ResolveResult(existing, generated=False)
        lock = self._lock_for(request.key)
        with lock:
            if existing := self.repository.find(request):
                return ResolveResult(existing, generated=False)
            recipe = self.generator.generate(request)
            validate_recipe(recipe, request=request)
            return ResolveResult(self.repository.save_generated(recipe), generated=True)

    def _lock_for(self, key: str) -> threading.Lock:
        with self._generation_locks_guard:
            return self._generation_locks.setdefault(key, threading.Lock())


def validate_recipe(recipe: Any, request: RecipeRequest | None = None) -> None:
    if not isinstance(recipe, dict):
        raise RecipeValidationError("Recipe 顶层必须是 JSON 对象")
    for key in ("id", "name", "match", "checks", "download"):
        if key not in recipe:
            raise RecipeValidationError(f"Recipe 缺少字段：{key}")
    if not isinstance(recipe["id"], str) or not recipe["id"].strip():
        raise RecipeValidationError("Recipe id 无效")
    if not isinstance(recipe["name"], str) or not recipe["name"].strip():
        raise RecipeValidationError("Recipe name 无效")
    match = recipe["match"]
    if not isinstance(match, dict):
        raise RecipeValidationError("Recipe match 必须是对象")
    if not any(match.get(key) for key in ("bundleIdentifier", "appName", "officialHost")):
        raise RecipeValidationError("Recipe 至少需要一种匹配条件")
    checks = recipe["checks"]
    if not isinstance(checks, list):
        raise RecipeValidationError("Recipe checks 必须是数组")
    for index, check in enumerate(checks):
        if not isinstance(check, dict) or not _is_http_url(check.get("url")):
            raise RecipeValidationError(f"checks[{index}].url 无效")
        extract = check.get("extract")
        if not isinstance(extract, dict) or extract.get("type") not in {"regex", "linkRegex"}:
            raise RecipeValidationError(f"checks[{index}].extract.type 无效")
        _validate_pattern(extract, f"checks[{index}].extract")
    update_page_url = recipe.get("updatePageURL")
    if update_page_url is not None and not _is_http_url(update_page_url):
        raise RecipeValidationError("updatePageURL 无效")
    download = recipe["download"]
    if download is not None:
        if not isinstance(download, dict):
            raise RecipeValidationError("download 必须是对象或 null")
        direct_url = download.get("url")
        source_url = download.get("sourceURL")
        source_template = download.get("sourceURLTemplate")
        if direct_url is not None and not _is_http_url(direct_url):
            raise RecipeValidationError("download.url 无效")
        if source_url is not None and not _is_http_url(source_url):
            raise RecipeValidationError("download.sourceURL 无效")
        if source_template is not None and not _is_http_url(
            source_template.replace("{version}", "1.0")
        ):
            raise RecipeValidationError("download.sourceURLTemplate 无效")
        has_extraction_rule = (source_url or source_template) and download.get("pattern")
        if direct_url is None and has_extraction_rule:
            _validate_pattern(
                {"pattern": download["pattern"], "versionGroup": download.get("urlGroup", 1)},
                "download",
            )
        elif direct_url is None and any(
            value is not None
            for value in (source_url, source_template, download.get("pattern"), download.get("urlGroup"))
        ):
            raise RecipeValidationError("download 提取规则不完整")
    if request:
        generated_bundle_id = match.get("bundleIdentifier")
        if request.bundle_id and not _case_equal(generated_bundle_id, request.bundle_id):
            raise RecipeValidationError("生成的 Recipe 未保留用户提供的 Bundle ID")
        if not _case_equal(match.get("appName"), request.app_name):
            raise RecipeValidationError("生成的 Recipe 与用户提供的 App 名称不匹配")
        request_host = _normalized_host(request.website)
        generated_host = _normalized_host(match.get("officialHost"))
        if request_host and (not generated_host or not _hosts_match(request_host, generated_host)):
            raise RecipeValidationError("生成的 Recipe 与用户提供的官网不匹配")


def _validate_pattern(extract: Mapping[str, Any], field: str) -> None:
    pattern = extract.get("pattern")
    group = extract.get("versionGroup")
    if not isinstance(pattern, str) or not pattern:
        raise RecipeValidationError(f"{field}.pattern 无效")
    if not isinstance(group, int) or group < 0:
        raise RecipeValidationError(f"{field} 的捕获组编号无效")
    try:
        compiled = re.compile(pattern)
    except re.error as error:
        raise RecipeValidationError(f"{field}.pattern 不是有效正则：{error}") from error
    if group > compiled.groups:
        raise RecipeValidationError(f"{field} 指定的捕获组不存在")


def _decode_generated_recipe(output: str) -> dict[str, Any]:
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise RecipeGenerationError("内部生成流程返回的不是有效 JSON") from error
    if not isinstance(value, dict):
        raise RecipeGenerationError("内部生成流程返回的不是 Recipe 对象")
    return value


def _request_mapping(request: RecipeRequest) -> dict[str, str | None]:
    return {
        "appName": request.app_name,
        "bundleId": request.bundle_id,
        "website": request.website,
    }


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    result = str(value).strip()
    return result or None


def _case_equal(first: Any, second: Any) -> bool:
    return isinstance(first, str) and isinstance(second, str) and first.casefold() == second.casefold()


def _normalized_host(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    parsed = urlparse(value if "://" in value else f"https://{value}")
    return parsed.hostname.lower().removeprefix("www.") if parsed.hostname else None


def _hosts_match(first: str, second: str) -> bool:
    return first == second or first.endswith(f".{second}") or second.endswith(f".{first}")


def _is_http_url(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.hostname)


def make_handler(service: RecipeService) -> type[BaseHTTPRequestHandler]:
    class RecipeRequestHandler(BaseHTTPRequestHandler):
        server_version = "AppManRecipeService/1.0"

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/":
                self._send_file(STATIC_ROOT / "index.html", "text/html; charset=utf-8")
                return
            if parsed.path == "/api/health":
                self._send_json({"ok": True})
                return
            if parsed.path == "/api/recipes/search":
                self._handle_search(parse_qs(parsed.query))
                return
            if parsed.path.startswith("/recipes/"):
                file_name = unquote(parsed.path[len("/recipes/") :])
                self._handle_recipe_file(file_name)
                return
            if parsed.path.startswith("/api/recipes/") and parsed.path.endswith("/download"):
                recipe_id = unquote(parsed.path[len("/api/recipes/") : -len("/download")]).strip("/")
                self._handle_download(recipe_id)
                return
            self._send_error(HTTPStatus.NOT_FOUND, "请求的资源不存在")

        def do_POST(self) -> None:
            if urlparse(self.path).path != "/api/recipes/resolve":
                self._send_error(HTTPStatus.NOT_FOUND, "请求的资源不存在")
                return
            try:
                request = RecipeRequest.from_mapping(self._read_json_body())
                result = service.resolve(request)
                self._send_json(self._result_payload(result), HTTPStatus.CREATED if result.generated else HTTPStatus.OK)
            except RecipeValidationError as error:
                self._send_error(HTTPStatus.BAD_REQUEST, str(error))
            except RecipeGenerationError as error:
                self._send_error(HTTPStatus.BAD_GATEWAY, str(error))
            except RecipeError as error:
                self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))
            except Exception:
                self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "服务处理请求时发生内部错误")

        def _handle_search(self, query: Mapping[str, list[str]]) -> None:
            try:
                request = RecipeRequest.from_mapping(
                    {
                        "appName": _first(query.get("appName")),
                        "bundleId": _first(query.get("bundleId")),
                        "website": _first(query.get("website")),
                    }
                )
                record = service.search(request)
                if record:
                    self._send_json(self._result_payload(ResolveResult(record, False)))
                else:
                    self._send_json({"found": False})
            except RecipeValidationError as error:
                self._send_error(HTTPStatus.BAD_REQUEST, str(error))
            except RecipeError as error:
                self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))

        def _handle_download(self, recipe_id: str) -> None:
            record = service.repository.get_by_id(recipe_id)
            if not record:
                self._send_error(HTTPStatus.NOT_FOUND, "Recipe 不存在")
                return
            self._send_recipe_file(record)

        def _handle_recipe_file(self, file_name: str) -> None:
            if not file_name or Path(file_name).name != file_name or not file_name.endswith(".json"):
                self._send_error(HTTPStatus.NOT_FOUND, "Recipe 文件不存在")
                return
            record = service.repository.get_by_file_name(file_name)
            if not record:
                self._send_error(HTTPStatus.NOT_FOUND, "Recipe 文件不存在")
                return
            self._send_recipe_file(record)

        def _send_recipe_file(self, record: RecipeRecord) -> None:
            try:
                path = service.repository.ensure_json_file(record)
                content = path.read_bytes()
            except (OSError, RecipeValidationError) as error:
                self._send_error(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    f"Recipe 文件读取或恢复失败：{error}",
                )
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def _result_payload(self, result: ResolveResult) -> dict[str, Any]:
            if result.record.path is None:
                raise RecipeValidationError("数据库中的 Recipe 路径为空")
            file_name = quote(result.record.path.name, safe="")
            return {
                "found": True,
                "generated": result.generated,
                "recipe": result.record.recipe,
                "summary": result.record.summary(),
                "downloadURL": f"/recipes/{file_name}",
            }

        def _read_json_body(self) -> Mapping[str, Any]:
            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length or "0")
            except ValueError as error:
                raise RecipeValidationError("Content-Length 无效") from error
            if length <= 0 or length > MAX_REQUEST_BYTES:
                raise RecipeValidationError("请求内容为空或过大")
            try:
                value = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as error:
                raise RecipeValidationError("请求内容不是有效 JSON") from error
            if not isinstance(value, dict):
                raise RecipeValidationError("请求内容必须是 JSON 对象")
            return value

        def _send_file(self, path: Path, content_type: str) -> None:
            try:
                content = path.read_bytes()
            except OSError:
                self._send_error(HTTPStatus.NOT_FOUND, "页面资源不存在")
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def _send_json(self, value: Mapping[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
            content = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def _send_error(self, status: HTTPStatus, message: str) -> None:
            self._send_json({"error": message}, status)

        def log_message(self, format_string: str, *args: Any) -> None:
            print(f"{self.address_string()} - {format_string % args}")

    return RecipeRequestHandler


def _first(values: list[str] | None) -> str | None:
    return values[0] if values else None


def build_service() -> RecipeService:
    built_in_value = os.environ.get("APPMAN_RECIPE_BUILTIN_DIR")
    generated_value = os.environ.get("APPMAN_RECIPE_DATA_DIR")
    database_value = os.environ.get("APPMAN_RECIPE_DATABASE_PATH")
    built_in_directories = [Path(built_in_value)] if built_in_value else [DEFAULT_BUILT_IN_DIRECTORY]
    generated_directory = Path(generated_value) if generated_value else DEFAULT_GENERATED_DIRECTORY
    database_path = (
        Path(database_value)
        if database_value
        else (
            generated_directory.parent / "recipe-web-service.sqlite3"
            if generated_value
            else DEFAULT_DATABASE_PATH
        )
    )
    generator_command = os.environ.get("APPMAN_RECIPE_GENERATOR_COMMAND")
    generator: RecipeGenerator = (
        CommandRecipeGenerator(generator_command) if generator_command else CodexRecipeGenerator()
    )
    return RecipeService(
        RecipeRepository(built_in_directories, generated_directory, database_path),
        generator,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="AppMan Recipe 查询、生成与下载服务")
    parser.add_argument("--host", default="127.0.0.1", help="监听地址，默认仅本机访问")
    parser.add_argument("--port", default=8787, type=int, help="监听端口")
    arguments = parser.parse_args()
    server = RecipeHTTPServer((arguments.host, arguments.port), make_handler(build_service()))
    print(f"AppMan Recipe 服务已启动：http://{arguments.host}:{arguments.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
