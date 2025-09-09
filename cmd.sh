#!/usr/bin/env python3
"""
Auto-fetch, run, commit, and push loop for the repository.

Behavior:
- Ensures we're on `main` and pulls latest changes from `origin/main`.
- Executes `./cmd.sh` and captures stdout/stderr to files named
  `stdout` and `stdin` in repo root (stderr captured in `stdin` file
  per request).
- Commits those files if they changed and pushes to origin.
- Repeats forever with a configurable sleep interval.

Environment variables:
- LOOP_INTERVAL_SECONDS: Sleep seconds between iterations (default: 60)

Notes:
- Requires working git auth for pushing to origin.
- Assumes `cmd.sh` exists and is executable; if not, it will attempt
  to run via `bash ./cmd.sh`.
- If upstream is not set, it will push to `origin main` and set upstream.
"""

from __future__ import annotations

import datetime
import os
import subprocess
import sys
import time
from pathlib import Path


REPO_URL_DEFAULT = "https://github.com/tjade273/claude-code-testing"
BRANCH = "main"
STDOUT_FILE = "stdout"
STDIN_FILE = "stdin"  # stderr is written to this file name by request


def run_command(
    args: list[str] | tuple[str, ...],
    cwd: Path,
    check: bool = False,
    capture_output: bool = True,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        args,
        cwd=str(cwd),
        check=check,
        text=True,
        capture_output=capture_output,
    )


def ensure_repo_origin(cwd: Path) -> None:
    # If origin is missing, set it to the default URL
    result = run_command(["git", "remote"], cwd)
    remotes = (result.stdout or "").strip().splitlines()
    if "origin" not in remotes:
        run_command(["git", "remote", "add", "origin", REPO_URL_DEFAULT], cwd)


def ensure_on_branch(cwd: Path, branch: str) -> None:
    result = run_command(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd)
    current = (result.stdout or "").strip()
    if current != branch:
        run_command(["git", "checkout", branch], cwd, check=True)


def pull_latest(cwd: Path, branch: str) -> None:
    # Prefer rebase to keep history linear; autostash to handle local
    # worktree changes temporarily
    fetch = run_command(["git", "fetch", "origin", branch], cwd)
    if fetch.returncode != 0:
        print(f"[warn] git fetch failed: {fetch.stderr}")
    pull = run_command(
        ["git", "pull", "--rebase", "--autostash", "origin", branch],
        cwd,
    )
    if pull.returncode != 0:
        print(f"[warn] git pull --rebase failed: {pull.stderr}")


def run_cmd_sh(cwd: Path) -> tuple[str, str, int]:
    # Try direct exec if executable; fallback to bash
    cmd_path = cwd / "cmd.sh"
    if cmd_path.exists() and os.access(str(cmd_path), os.X_OK):
        proc = run_command([str(cmd_path)], cwd)
    else:
        proc = run_command(["bash", "./cmd.sh"], cwd)
    return (proc.stdout or ""), (proc.stderr or ""), proc.returncode


def write_outputs(cwd: Path, out_text: str, err_text: str) -> None:
    (cwd / STDOUT_FILE).write_text(out_text)
    (cwd / STDIN_FILE).write_text(err_text)


def stage_outputs(cwd: Path) -> None:
    run_command(["git", "add", STDOUT_FILE, STDIN_FILE], cwd)


def has_staged_changes(cwd: Path) -> bool:
    # Returns True if there is anything staged for commit
    diff = run_command(["git", "diff", "--cached", "--name-only"], cwd)
    return bool((diff.stdout or "").strip())


def commit_and_push(cwd: Path, branch: str) -> None:
    timestamp = datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z"
    msg = f"Update outputs at {timestamp}"
    commit = run_command(["git", "commit", "-m", msg], cwd)
    if commit.returncode != 0:
        # Nothing to commit
        return

    # Try pushing to upstream if set, else push to origin branch and set
    # upstream
    upstream = run_command(
        [
            "git",
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{u}",
        ],
        cwd,
    )
    if upstream.returncode == 0:
        push = run_command(["git", "push"], cwd)
        if push.returncode != 0:
            print(f"[warn] git push failed: {push.stderr}")
    else:
        push = run_command(["git", "push", "-u", "origin", branch], cwd)
        if push.returncode != 0:
            print(f"[warn] git push -u origin {branch} failed: {push.stderr}")


def loop_once(cwd: Path) -> None:
    ensure_repo_origin(cwd)
    ensure_on_branch(cwd, BRANCH)
    pull_latest(cwd, BRANCH)

    out_text, err_text, return_code = run_cmd_sh(cwd)
    write_outputs(cwd, out_text, err_text)
    stage_outputs(cwd)

    if has_staged_changes(cwd):
        commit_and_push(cwd, BRANCH)
    else:
        print("[info] No changes detected; nothing to commit.")

    # Provide a simple status line for logs
    print(f"[info] cmd.sh exit code: {return_code}")


def main() -> int:
    repo_root = Path(__file__).resolve().parent

    interval_str = os.environ.get("LOOP_INTERVAL_SECONDS", "1").strip()
    try:
        interval = max(1, int(interval_str))
    except ValueError:
        print(
            "[warn] Invalid LOOP_INTERVAL_SECONDS='"
            f"{interval_str}'"
            ", defaulting to 60"
        )
        interval = 60

    run_once = "--once" in sys.argv

    # Simple file lock to avoid concurrent runs
    lock_file = repo_root / ".auto_fetch_run.lock"
    try:
        if lock_file.exists():
            print("[warn] Lock file exists. Another instance may be running.")
        lock_file.write_text(str(os.getpid()))

        if run_once:
            loop_once(repo_root)
            return 0

        print(
            f"[info] Starting loop: interval={interval}s, "
            f"branch={BRANCH}"
        )
        while True:
            try:
                loop_once(repo_root)
            except Exception as exc:  # noqa: BLE001 keep loop alive on errors
                print(f"[error] Exception in loop: {exc}")
            time.sleep(interval)
    finally:
        try:
            if lock_file.exists():
                lock_file.unlink()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
