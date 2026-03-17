#!/usr/bin/env python3

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a single Codex session into a portable bundle."
    )
    parser.add_argument(
        "thread_id",
        nargs="?",
        help="Codex thread/session id. Defaults to the most recently updated thread.",
    )
    parser.add_argument(
        "--codex-home",
        default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")),
        help="Codex home directory. Defaults to $CODEX_HOME or ~/.codex.",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory that will contain the exported bundle.",
    )
    return parser.parse_args()


def fetch_latest_thread_id(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT id FROM threads ORDER BY updated_at DESC LIMIT 1"
    ).fetchone()
    if row is None:
        raise SystemExit("No threads found in Codex state database.")
    return str(row[0])


def row_to_dict(cursor: sqlite3.Cursor, row: sqlite3.Row) -> dict:
    return {description[0]: row[idx] for idx, description in enumerate(cursor.description)}


def sanitize_title(title: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", title.strip())
    cleaned = cleaned.strip("-._")
    return cleaned[:48] or "untitled"


def iso_utc_from_epoch(epoch_seconds: int) -> str:
    return (
        datetime.fromtimestamp(epoch_seconds, tz=timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def main() -> int:
    args = parse_args()

    codex_home = Path(args.codex_home).expanduser().resolve()
    state_db = codex_home / "state_5.sqlite"
    session_index = codex_home / "session_index.jsonl"

    if not state_db.exists():
        raise SystemExit(f"Missing state database: {state_db}")

    conn = sqlite3.connect(state_db)
    conn.row_factory = sqlite3.Row

    thread_id = args.thread_id or fetch_latest_thread_id(conn)

    thread_cursor = conn.execute(
        "SELECT * FROM threads WHERE id = ?",
        (thread_id,),
    )
    thread_row = thread_cursor.fetchone()
    if thread_row is None:
        raise SystemExit(f"Thread not found: {thread_id}")
    thread = row_to_dict(thread_cursor, thread_row)

    rollout_path = Path(thread["rollout_path"])
    if not rollout_path.exists():
        raise SystemExit(f"Rollout file not found: {rollout_path}")

    dynamic_tools_cursor = conn.execute(
        """
        SELECT position, name, description, input_schema
        FROM thread_dynamic_tools
        WHERE thread_id = ?
        ORDER BY position ASC
        """,
        (thread_id,),
    )
    dynamic_tools = [row_to_dict(dynamic_tools_cursor, row) for row in dynamic_tools_cursor]

    session_index_entry = None
    if session_index.exists():
        for line in session_index.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            entry = json.loads(line)
            if entry.get("id") == thread_id:
                session_index_entry = entry
                break

    updated_at = int(thread["updated_at"])
    title_slug = sanitize_title(str(thread["title"]))
    bundle_dir = (
        Path(args.output_dir).expanduser().resolve()
        / f"{updated_at}-{thread_id}-{title_slug}"
    )
    try:
        bundle_dir.mkdir(parents=True, exist_ok=True)
    except PermissionError as exc:
        raise SystemExit(
            "Cannot create export bundle directory. "
            f"Try --output-dir with a writable path. target={bundle_dir}"
        ) from exc

    relative_rollout_path = None
    try:
        relative_rollout_path = rollout_path.relative_to(codex_home)
    except ValueError:
        relative_rollout_path = Path("sessions") / rollout_path.name

    manifest = {
        "bundle_version": 1,
        "exported_at": datetime.now(tz=timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "thread_id": thread_id,
        "title": thread["title"],
        "source_codex_home": str(codex_home),
        "source_rollout_path": str(rollout_path),
        "rollout_relative_path": str(relative_rollout_path),
        "source_cwd": thread["cwd"],
        "suggested_import_cwd_git_origin_url": thread["git_origin_url"],
        "suggested_import_cwd_git_branch": thread["git_branch"],
    }

    shutil.copy2(rollout_path, bundle_dir / "rollout.jsonl")
    (bundle_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (bundle_dir / "thread.json").write_text(
        json.dumps(thread, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (bundle_dir / "dynamic_tools.json").write_text(
        json.dumps(dynamic_tools, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    if session_index_entry is not None:
        (bundle_dir / "session_index_entry.json").write_text(
            json.dumps(session_index_entry, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    files = [
        bundle_dir / "rollout.jsonl",
        bundle_dir / "manifest.json",
        bundle_dir / "thread.json",
        bundle_dir / "dynamic_tools.json",
    ]
    if session_index_entry is not None:
        files.append(bundle_dir / "session_index_entry.json")

    bundle_size = sum(path.stat().st_size for path in files if path.exists())

    print(f"bundle_dir={bundle_dir}")
    print(f"thread_id={thread_id}")
    print(f"bundle_bytes={bundle_size}")
    print(f"rollout_bytes={(bundle_dir / 'rollout.jsonl').stat().st_size}")
    print(f"thread_json_bytes={(bundle_dir / 'thread.json').stat().st_size}")
    print(f"dynamic_tools_json_bytes={(bundle_dir / 'dynamic_tools.json').stat().st_size}")
    if session_index_entry is not None:
        print(
            "session_index_entry_bytes="
            f"{(bundle_dir / 'session_index_entry.json').stat().st_size}"
        )
    print(f"updated_at_iso={iso_utc_from_epoch(updated_at)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
