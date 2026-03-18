#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Import a portable Codex session bundle into the local Codex home."
    )
    parser.add_argument("bundle_dir", help="Path to an exported session bundle.")
    parser.add_argument(
        "--codex-home",
        default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")),
        help="Codex home directory. Defaults to $CODEX_HOME or ~/.codex.",
    )
    parser.add_argument(
        "--cwd",
        default=None,
        help="Override the imported thread cwd. Defaults to bundle cwd if present, otherwise the current directory.",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="Optional title override for the imported thread.",
    )
    return parser.parse_args()


def load_json(path: Path):
    if not path.exists():
        raise SystemExit(f"Missing required file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def epoch_to_session_index_iso(epoch_seconds: int) -> str:
    return (
        datetime.fromtimestamp(epoch_seconds, tz=timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def choose_cwd(original_cwd: str, override_cwd: str | None) -> str:
    if override_cwd:
        return str(Path(override_cwd).expanduser().resolve())

    original_path = Path(original_cwd).expanduser()
    if original_path.exists():
        return str(original_path.resolve())

    return str(Path.cwd().resolve())


def rewrite_rollout_cwd(source: Path, destination: Path, original_cwd: str, imported_cwd: str) -> None:
    original = str(Path(original_cwd).expanduser().resolve(strict=False))
    imported = str(Path(imported_cwd).expanduser().resolve(strict=False))
    if original == imported:
        shutil.copy2(source, destination)
        return

    rewritten_lines: list[str] = []
    for raw_line in source.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            rewritten_lines.append(raw_line)
            continue
        payload = json.loads(raw_line)
        rewrite_cwd_refs(payload, original, imported)
        rewritten_lines.append(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))

    destination.write_text("\n".join(rewritten_lines) + "\n", encoding="utf-8")


def rewrite_cwd_refs(value, original_cwd: str, imported_cwd: str) -> None:
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if isinstance(child, str):
                if key == "cwd" and child == original_cwd:
                    value[key] = imported_cwd
                elif key == "text" and f"<cwd>{original_cwd}</cwd>" in child:
                    value[key] = child.replace(f"<cwd>{original_cwd}</cwd>", f"<cwd>{imported_cwd}</cwd>")
            else:
                rewrite_cwd_refs(child, original_cwd, imported_cwd)
    elif isinstance(value, list):
        for item in value:
            rewrite_cwd_refs(item, original_cwd, imported_cwd)


def upsert_session_index(session_index_path: Path, entry: dict) -> None:
    existing = []
    if session_index_path.exists():
        for line in session_index_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            parsed = json.loads(line)
            if parsed.get("id") != entry["id"]:
                existing.append(parsed)

    existing.append(entry)
    existing.sort(key=lambda item: item.get("updated_at", ""))
    ensure_parent(session_index_path)
    with session_index_path.open("w", encoding="utf-8") as handle:
        for item in existing:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")


def main() -> int:
    args = parse_args()

    bundle_dir = Path(args.bundle_dir).expanduser().resolve()
    codex_home = Path(args.codex_home).expanduser().resolve()
    state_db = codex_home / "state_5.sqlite"
    session_index_path = codex_home / "session_index.jsonl"

    manifest = load_json(bundle_dir / "manifest.json")
    thread = load_json(bundle_dir / "thread.json")
    dynamic_tools = load_json(bundle_dir / "dynamic_tools.json")
    rollout_source = bundle_dir / "rollout.jsonl"

    if not state_db.exists():
        raise SystemExit(f"Missing target state database: {state_db}")
    if not rollout_source.exists():
        raise SystemExit(f"Missing rollout payload: {rollout_source}")

    rollout_relative_path = Path(manifest["rollout_relative_path"])
    rollout_target = codex_home / rollout_relative_path
    ensure_parent(rollout_target)
    imported_cwd = choose_cwd(thread["cwd"], args.cwd)
    rewrite_rollout_cwd(rollout_source, rollout_target, thread["cwd"], imported_cwd)

    thread["rollout_path"] = str(rollout_target)
    thread["cwd"] = imported_cwd
    if args.title:
        thread["title"] = args.title

    conn = sqlite3.connect(state_db)
    try:
        with conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO threads (
                    id, rollout_path, created_at, updated_at, source, model_provider,
                    cwd, title, sandbox_policy, approval_mode, tokens_used,
                    has_user_event, archived, archived_at, git_sha, git_branch,
                    git_origin_url, cli_version, first_user_message, agent_nickname,
                    agent_role, memory_mode
                ) VALUES (
                    :id, :rollout_path, :created_at, :updated_at, :source, :model_provider,
                    :cwd, :title, :sandbox_policy, :approval_mode, :tokens_used,
                    :has_user_event, :archived, :archived_at, :git_sha, :git_branch,
                    :git_origin_url, :cli_version, :first_user_message, :agent_nickname,
                    :agent_role, :memory_mode
                )
                """,
                thread,
            )
            conn.execute(
                "DELETE FROM thread_dynamic_tools WHERE thread_id = ?",
                (thread["id"],),
            )
            for item in dynamic_tools:
                conn.execute(
                    """
                    INSERT INTO thread_dynamic_tools (
                        thread_id, position, name, description, input_schema
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        thread["id"],
                        item["position"],
                        item["name"],
                        item["description"],
                        item["input_schema"],
                    ),
                )
    finally:
        conn.close()

    session_index_entry_path = bundle_dir / "session_index_entry.json"
    if session_index_entry_path.exists():
        session_index_entry = load_json(session_index_entry_path)
    else:
        session_index_entry = {
            "id": thread["id"],
            "thread_name": thread["title"],
            "updated_at": epoch_to_session_index_iso(int(thread["updated_at"])),
        }

    session_index_entry["thread_name"] = thread["title"]
    upsert_session_index(session_index_path, session_index_entry)

    print(f"imported_thread_id={thread['id']}")
    print(f"rollout_target={rollout_target}")
    print(f"cwd={thread['cwd']}")
    print(f"session_index_updated={session_index_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
