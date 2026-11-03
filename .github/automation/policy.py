"""Validate model output as data; never execute it in a privileged job."""
import json
import re
import sys
from pathlib import Path

MAX_BYTES = 262144


def validate(task, result):
    if set(task) != {"issue", "goal", "allowed_paths", "acceptance"}:
        raise ValueError("Invalid task schema")
    allowed = task["allowed_paths"]
    if not isinstance(allowed, list) or not 1 <= len(allowed) <= 12:
        raise ValueError("Invalid scope")
    for path in allowed:
        if not isinstance(path, str) or not re.fullmatch(r"(?:Sources|Tests|docs|agent-workflow/reports)/[A-Za-z0-9_./-]+\.(?:swift|md)", path):
            raise ValueError("Protected or unsupported path")
        if any(p in (".", "..") or p.startswith(".") for p in path.split("/")):
            raise ValueError("Unsafe path")
        if path in {"docs/DECISIONS.md", "docs/CURRENT_TASK.md", "docs/ROADMAP.md"}:
            raise ValueError("Authority document requires human change")
    if set(result) != {"changes", "report"} or not isinstance(result["report"], str) or len(result["report"]) > 12000:
        raise ValueError("Invalid result schema")
    changes = result["changes"]
    if not isinstance(changes, list) or not 1 <= len(changes) <= 12:
        raise ValueError("Empty or oversized changes")
    seen = set()
    for change in changes:
        if set(change) != {"path", "content"} or change["path"] not in allowed or change["path"] in seen:
            raise ValueError("Change outside approved scope or duplicate")
        seen.add(change["path"])
        content = change["content"]
        if not isinstance(content, str) or len(content.encode()) > 65536 or "\x00" in content:
            raise ValueError("Invalid content")
        if re.search(r"(?:sk-ant-|gh[pousr]_[A-Za-z0-9]{20}|github_pat_|-----BEGIN .*PRIVATE KEY)", content):
            raise ValueError("Credential-shaped output refused")
    return changes


def main():
    task_path, result_path = map(Path, sys.argv[1:3])
    if result_path.stat().st_size > MAX_BYTES:
        raise ValueError("Oversized artifact")
    task, result = json.loads(task_path.read_text()), json.loads(result_path.read_text())
    changes = validate(task, result)
    if "--apply" in sys.argv:
        for change in changes:
            path = Path(change["path"])
            if any(p.is_symlink() for p in [path, *path.parents]):
                raise ValueError("Symlink refused")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(change["content"])
    print("PASS: bounded paths, schema, size and credential-pattern checks (not a security approval)")


if __name__ == "__main__":
    main()
