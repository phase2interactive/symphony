# Task List

## Bug: GitHub issues not visible in dashboard (2026-03-11)

Root cause: Two separate issues prevent GitHub issues from appearing in the dashboard.

### Task 1: `just run` doesn't load `.env` via direnv

**Status:** TODO

The `justfile` runs `bin/symphony` but the shell context doesn't have direnv activated, so `SYMPHONY_GITHUB_TOKEN` from `.env` is never loaded. `Config.Schema.finalize_settings()` resolves `"$SYMPHONY_GITHUB_TOKEN"` → `System.get_env("SYMPHONY_GITHUB_TOKEN")` → `nil`.

**Fix options:**
- a) Source `.env` explicitly in the justfile `run` recipe (e.g., `set dotenv-load`)
- b) Have the escript/CLI load `.env` from the workflow file's directory at startup
- c) Both — justfile for dev convenience, CLI for robustness

### Task 2: Dashboard silently hides config/polling errors

**Status:** TODO

When `Config.validate!()` returns `{:error, :missing_github_token}`, the orchestrator logs the error but the dashboard UI shows "No active sessions" / "No issues are currently backing off" with no indication anything is wrong.

**Fix:**
- Surface the latest polling error in the orchestrator state (`State` struct)
- Propagate it to `StatusDashboard` so it can render an error banner/card
- Handle all config validation errors (missing token, missing repo, bad tracker kind, etc.)
- The error should clear once the next poll succeeds

### Task 3: Orchestrator error message says "Linear" for all tracker errors

**Status:** TODO

`orchestrator.ex:217` has a catch-all `{:error, reason} -> Logger.error("Failed to fetch from Linear: ...")` — this should be tracker-agnostic (e.g., "Failed to fetch issues").

### Task 4: Missing `{:error, :missing_github_token}` handler in orchestrator

**Status:** TODO

`orchestrator.ex:182-218` handles `:missing_linear_api_token` and `:missing_linear_project_slug` with specific log messages, but `:missing_github_token` and `:missing_github_repo` fall through to the generic catch-all that says "Failed to fetch from Linear".

---

## Completed

### Fix: port_exit errors from unterminated CLI output (2026-03-11)

**Status:** DONE (commit 65b87d6)

Erlang ports in `:line` mode deliver `{:noeol, data}` after `{:exit_status, _}`. Both Claude and Codex backends now drain remaining mailbox data before handling exit_status.
