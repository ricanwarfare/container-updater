# Project review — 2026-09-05

Reviewed all tracked files: the updater, README, configuration, and Git attributes. The project had no automated tests. Local configuration values were preserved.

## Confirmed bugs fixed

| Impact | Finding | Fix |
| --- | --- | --- |
| High | `.env` overwrote caller variables, including an explicit `DRY_RUN=true`. | Preserve caller values through config loading. |
| High | Global autostart ignored `BASE_DIR` and exclusions, and restarted intentionally stopped containers by default. | Disable by default; restrict to included projects and explicitly labelled containers. |
| High | `compose up` could start stopped dependencies; orphan removal deleted containers outside the selected services. | Use `--no-deps`; remove orphan deletion and exclude orphans from discovery. |
| High | Explicit `-f` ignored automatic override files and selected legacy filenames ahead of canonical ones. | Use Compose's normal discovery in each stack directory. |
| High | Failed pulls, status checks, and unhealthy updates still ended with success, misleading cron/monitoring. Docker listing errors could look like an empty daemon. | Check daemon/plugin availability and aggregate operational failures into a nonzero exit. |
| Medium | Stale-lock recovery retried `mkdir` without removing the stale directory, permanently blocking future runs. | Use a kernel-managed `flock` lock with no PID reuse or stale-directory recovery race. |
| Medium | Successful status-command warnings on stderr became service names. | Keep stderr in the log, parse stdout only, and deduplicate service names. |
| Medium | Paused-only services were selected for recreation. | Select running/restarting states explicitly in separate queries. |
| Medium | Relative Docker/log paths broke after entering a stack directory. | Resolve executable, log, lock, and base paths first. |
| Medium | Invalid booleans could disable dry-run protection silently; zero retries skipped every pull. | Validate configuration before Docker calls. |
| Medium | Health waits and webhook requests could stall unattended execution. | Add a configurable health wait timeout and bounded HTTP requests. |
| Medium | Webhook escaping missed control characters and hostname; HTTP errors were not recognized. | Encode all JSON string values and log HTTP/transport delivery errors. |
| Medium | Log-retention `ls`/`xargs` split paths on whitespace. | Use a constrained glob and quoted arrays; measure actual file bytes. |
| Medium | Pruning ran after failed updates, potentially discarding dangling recovery images. | Skip pruning when any operation has failed. |

## Verification

`bash -n updater.sh` passes. All 29 isolated Python unittest tests pass. The suite verifies service selection, stderr separation, caller precedence, mutation-free dry runs, retries, failure aggregation, daemon/status failures, pruning failure, exclusions, labelled recovery, invalid configuration, stale and concurrent locks, relative paths, log retention, and JSON payloads containing quotes, backslashes, tabs, and newlines.

The tests simulate CLI responses and verify issued commands. No live Docker updates were performed. ShellCheck is not installed in this workspace. Real Compose merging, health checks, and replica reconciliation remain integration-test coverage gaps. Docker's official [Compose ps](https://docs.docker.com/reference/cli/docker/compose/ps/) and [Compose up](https://docs.docker.com/reference/cli/docker/compose/up/) references were checked for the flags and behavior used here.

## Recommended features, in priority order

1. **Disposable Compose integration tests and CI.** Exercise override files, stopped dependencies, health failures, and scaled services against a real daemon, alongside ShellCheck and this regression suite. This would catch CLI/version differences mocks cannot detect.
2. **Image change previews and update policies.** Show current and candidate digests, allow per-stack approval or maintenance windows, and support an allowlist for unattended updates.
3. **Rollback support with explicit limits.** Record pre-update image digests and retain them until post-update health checks pass. Make recovery opt-in per stack; image rollback cannot undo database migrations or restore data by itself.
4. **Structured run reports and native notifications.** Emit machine-readable per-stack results and totals, with provider-specific payload validation and delivery monitoring. Basic text/content payloads and successful-run summaries are now retained from the remote version.
5. **Replica-aware preservation.** Detect partially stopped or paused scaled services and skip/report them, or preserve their intended state explicitly. Compose currently acts on whole services.
6. **Per-stack configuration.** Support project names, multiple Compose files, profiles, dependencies between stacks, and stack-specific timeouts without relying on globally inherited Compose variables.

The legacy `.env` remains tracked to preserve the user's existing installation. A future configuration migration should untrack it after backing it up; `.env.example` now supplies portable defaults and `.gitignore` prevents newly untracked configuration and runtime files from being added accidentally.

## Remote changes integrated before push

The remote branch gained CLI flags, `.updaterignore`, hooks, summary metrics, success webhooks, CRLF config handling, and Git line-ending rules during the review. These features were retained alongside the fixes. Additional regression coverage checks argument handling, hooks and their failures, ignore files, CRLF configuration, the legacy timeout alias, and successful-run payloads. A zero timeout now selects a bounded 300-second wait instead of an unlimited wait. Remote configuration changes were accepted as part of the merge.

## Post-review production fixes & hardening

1. **Broad Compose V2 compatibility (Synology DSM & Debian LTS)**: Removed `--orphans=false` from `compose ps`, which caused failures on Compose versions prior to v2.24.0. The script now runs cleanly on Synology Container Manager (v2.9/v2.20) as well as modern Compose releases.
2. **Dependency & sidecar preservation**: Removed `--no-deps` from `compose up` so that Docker Compose properly orders service startup and health checks. This fixes startup crashes in stacks containing VPN sidecars (e.g., Gluetun) and network-mode sharing services.
3. **Transparent error diagnostics**: Failed Compose commands now capture and display their actual stderr/stdout diagnostics directly on standard output and in webhook alerts rather than burying details in log files.
4. **Local build support**: Added `--ignore-buildable` to `compose pull` so Compose only pulls registry images and safely skips services built locally from Dockerfiles.
5. **Interactive defaults**: Enabled standard output by default (`VERBOSE=true`), added real-time step progress feedback, and introduced `-q, --quiet, --no-verbose` options for silent background runs.
6. **CLI `-e, --exclude DIRS` flag**: Added ad-hoc exclusion support directly via CLI flags.
7. **Symlink traversal**: Canonical directory resolution allows `updater.sh` to be invoked through global symlinks while reliably discovering `.env`.
8. **Hook script enhancements**: Stack hooks now execute directly if marked executable (`chmod +x`), with `STACK_NAME`, `STACK_DIR`, and `ACTIVE_SERVICES` exported for backup scripts.
9. **Git configuration cleanup**: Untracked `.env` from Git history so local server configurations and credentials are never accidentally committed or merged.
10. **Automated CI pipeline**: Added GitHub Actions workflow (`.github/workflows/ci.yml`) validating Bash syntax, ShellCheck linting, and 34 isolated Python regression tests.
