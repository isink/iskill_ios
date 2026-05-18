"""Tools exposed to the Skiller review-agent (LangGraph)."""
from __future__ import annotations

import atexit
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

from langchain_core.tools import tool
from supabase import Client, create_client

_supabase: Client | None = None
_clone_dirs: list[str] = []


def _db() -> Client:
    global _supabase
    if _supabase is None:
        _supabase = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        )
    return _supabase


@atexit.register
def _cleanup_clones() -> None:
    for d in _clone_dirs:
        shutil.rmtree(d, ignore_errors=True)


def _stringify(item: Any) -> str:
    if item is None:
        return "unknown"
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return str(
            item.get("message")
            or item.get("error")
            or item.get("detail")
            or json.dumps(item, ensure_ascii=False)
        )
    return str(item)


def _parse_github(url: str) -> tuple[str, str] | None:
    try:
        u = urlparse(url)
        if u.netloc not in {"github.com", "www.github.com"}:
            return None
        parts = [p for p in u.path.split("/") if p]
        if len(parts) < 2:
            return None
        return parts[0], parts[1].removesuffix(".git")
    except Exception:
        return None


@tool
def fetch_pending() -> str:
    """List up to 20 oldest submissions awaiting agent decision
    (status='pending' AND agent_decision IS NULL).
    Returns a JSON array of {id, github_url, note, created_at}."""
    res = (
        _db()
        .table("submissions")
        .select("id, github_url, note, created_at")
        .eq("status", "pending")
        .is_("agent_decision", "null")
        .order("created_at")
        .limit(20)
        .execute()
    )
    return json.dumps(res.data or [], ensure_ascii=False)


@tool
def clone_and_locate_skills(github_url: str) -> str:
    """Shallow-clone a public GitHub repo and locate every SKILL.md at the
    repo root or one directory deep.
    Returns JSON: {tmp_dir, owner, repo, packages: [{dir, relative_path}]} or {error}."""
    parsed = _parse_github(github_url)
    if parsed is None:
        return json.dumps({"error": f"not a valid github url: {github_url}"})
    owner, repo = parsed

    tmp_dir = tempfile.mkdtemp(prefix="skiller-review-")
    _clone_dirs.append(tmp_dir)
    try:
        subprocess.run(
            [
                "git", "clone",
                "--depth=1", "--single-branch", "--quiet",
                f"https://github.com/{owner}/{repo}.git",
                tmp_dir,
            ],
            check=True,
            capture_output=True,
            timeout=180,
        )
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or b"").decode("utf-8", "ignore").strip()
        return json.dumps({"error": f"git clone failed: {msg[:300]}"})
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "git clone timed out"})

    packages: list[dict[str, Any]] = []

    def _try(dir_path: str, rel: str) -> None:
        if not os.path.isfile(os.path.join(dir_path, "SKILL.md")):
            return
        packages.append({"dir": dir_path, "relative_path": rel})

    _try(tmp_dir, "")
    try:
        for name in sorted(os.listdir(tmp_dir)):
            if name.startswith(".") or name == "node_modules":
                continue
            child = os.path.join(tmp_dir, name)
            if os.path.isdir(child):
                _try(child, name)
    except FileNotFoundError:
        pass

    return json.dumps(
        {"tmp_dir": tmp_dir, "owner": owner, "repo": repo, "packages": packages},
        ensure_ascii=False,
    )


@tool
def run_validator(package_dir: str) -> str:
    """Run skill-validator against a single SKILL.md package directory.
    Returns JSON: {passed, errors:[str], raw}."""
    binary = os.environ.get("SKILL_VALIDATOR_BIN", "skill-validator")
    try:
        proc = subprocess.run(
            [binary, "check", package_dir, "-o", "json"],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except FileNotFoundError:
        return json.dumps(
            {"passed": False, "errors": [f"validator binary not found: {binary}"], "raw": None}
        )
    except subprocess.TimeoutExpired:
        return json.dumps({"passed": False, "errors": ["validator timed out"], "raw": None})

    stdout = (proc.stdout or "").strip()
    try:
        raw: Any = json.loads(stdout) if stdout else None
    except json.JSONDecodeError:
        raw = {"raw_stdout": stdout}

    errors: list[str] = []
    if isinstance(raw, dict):
        for key in ("errors", "issues", "problems", "violations"):
            v = raw.get(key)
            if isinstance(v, list):
                for item in v:
                    errors.append(_stringify(item))
        checks = raw.get("checks")
        if isinstance(checks, dict):
            for name, val in checks.items():
                if isinstance(val, dict):
                    passed_flag = val.get("passed") if "passed" in val else val.get("ok")
                    if passed_flag is False:
                        msg = val.get("error") or val.get("message") or val.get("errors")
                        errors.append(f"{name}: {_stringify(msg)}")
                    sub = val.get("errors")
                    if isinstance(sub, list):
                        for e in sub:
                            errors.append(f"{name}: {_stringify(e)}")
        top_passed = raw.get("passed", raw.get("ok", raw.get("success")))
        if top_passed is False and not errors:
            errors.append("validator reported failure")

    if not errors and proc.returncode != 0:
        errors.append(f"validator exited with status {proc.returncode}")

    return json.dumps(
        {"passed": not errors, "errors": errors, "raw": raw},
        ensure_ascii=False,
    )


@tool
def query_similar_skills(author: str, repo: str) -> str:
    """Look up existing rows in the `skills` table whose slug starts with
    `${author}-`. Use this to flag potential duplicates of an earlier
    submission from the same owner.
    Returns JSON list of {slug, name, github_url}."""
    author_norm = (author or "").lower().strip()
    if not author_norm:
        return json.dumps([])
    res = (
        _db()
        .table("skills")
        .select("slug, name, github_url")
        .like("slug", f"{author_norm}-%")
        .limit(10)
        .execute()
    )
    return json.dumps(res.data or [], ensure_ascii=False)


@tool
def submit_decision(submission_id: str, decision: str, reason: str) -> str:
    """Write the agent's recommendation to the submissions row.

    `decision` MUST be 'approve' or 'reject'. The submission `status` is
    NOT changed — a human applies decisions via `npm run review:apply`.
    Returns {ok: true, ...} or {error}."""
    if decision not in ("approve", "reject"):
        return json.dumps({"error": f"invalid decision: {decision} (must be approve|reject)"})

    payload = {
        "agent_decision": decision,
        "agent_reason": (reason or "")[:2000],
        "agent_reviewed_at": datetime.now(timezone.utc).isoformat(),
    }
    res = (
        _db()
        .table("submissions")
        .update(payload)
        .eq("id", submission_id)
        .execute()
    )
    if not (res.data or []):
        return json.dumps({"error": f"submission not found: {submission_id}"})
    return json.dumps({"ok": True, "submission_id": submission_id, "decision": decision})
