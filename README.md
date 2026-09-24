# Auto Docker Updater

A Bash utility that discovers Docker Compose stacks in the immediate subdirectories of `BASE_DIR`, pulls images for active services, and recreates them with a bounded health wait.

## Requirements

- Linux with Bash 4.3+, `flock` (util-linux), and standard utilities (`gzip` for compressed log rotation).
- Docker with access to its daemon, and the Compose V2 plugin supporting `up --wait --wait-timeout`.
- `curl` if failure webhooks are enabled.
- Python 3 only to run the regression tests.

## Setup

Place `updater.sh` in your preferred directory and make it executable:

```bash
chmod +x updater.sh
cp .env.example .env
```

For the common `$HOME/docker/<stack>` layout, the copied `.env` works as-is. Change `BASE_DIR` only when your Compose stacks live elsewhere. The script sources this file as **trusted Bash code**, so quote paths containing spaces and restrict write access. The `.env` file is untracked by Git (`.gitignore` protects it); `.env.example` provides portable defaults. Avoid committing credentials or server-specific paths.

CLI options override explicit environment variables, which override `.env`; `.env` overrides defaults:

```bash
BASE_DIR=/opt/containers DRY_RUN=true VERBOSE=true ./updater.sh
```

Relative paths resolve from the directory where the updater is invoked. Use absolute paths in cron jobs. Logs and locks are resolved before entering stack directories.

## CLI options and stack hooks

Use `--help` for all options: `--dry-run` (`-d`), `--verbose` (`-v`), `--quiet` / `--no-verbose` (`-q`), `--base-dir DIR` (`-b`), `--exclude DIRS` (`-e`), `--prune` (`-p`), `--no-prune`, `--no-autostart`, `--wait-timeout SEC`, `--stack-timeout SEC`, `--no-hooks`, `--self-update` (`-u`), `--auto-update`, `--no-auto-update`, and `--version`.

A `.updaterignore` file inside a stack directory excludes it from updates and autostart. With `RUN_HOOKS=true` (default), trusted `pre-update.sh` and `post-update.sh` files run inside each active stack (executed directly if marked executable, or via Bash otherwise). Context variables `STACK_NAME`, `STACK_DIR`, and `ACTIVE_SERVICES` are exported for hook scripts. A failed pre-hook skips its update; a failed post-hook marks the run failed. Dry runs only log hooks and end with an explicit `[DRY RUN] Inspection finished` status, never `Global Update finished`. Disable them with `--no-hooks` or `RUN_HOOKS=false`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `BASE_DIR` | `$HOME/docker` | Parent of stack directories |
| `EXCLUDE_DIRS` | empty | Colon-separated folder names to skip, including autostart |
| `DOCKER_BIN` | autodetected | Docker executable path (autodetects `docker` in `PATH` or Synology/system candidate paths) |
| `SELF_UPDATE` | `false` | Check for and apply updates from GitHub releases before stack updates |
| `GITHUB_REPO` | `ricanwarfare/container-updater` | GitHub repository to check for releases |
| `LOG_FILE` | `$BASE_DIR/container-updater/updater.log` | Append-only run log |
| `LOCK_FILE` | `$BASE_DIR/container-updater/updater.lock` | Persistent file used for a kernel lock |
| `DRY_RUN` | `false` | Inspect and log proposed actions without Docker mutations or webhooks |
| `VERBOSE` | `true` | Print log messages to standard output in addition to the log file |
| `PRUNE_IMAGES` | `true` | Prune host-wide dangling images after a failure-free run with discovered stacks |
| `AUTOSTART` | `false` | Recover explicitly labelled exited containers in included stacks |
| `AUTOSTART_RETRY_DELAY` | `10` | Seconds before one retry of failed starts |
| `PULL_RETRIES` | `3` | Maximum pull attempts, at least 1 |
| `PULL_RETRY_DELAY` | `5` | Seconds between failed pull attempts |
| `WAIT_TIMEOUT` | `300` | Maximum seconds for Compose's running/healthy wait, at least 1 |
| `STACK_TIMEOUT` | `1800` | Hard cap in seconds on each stack's Docker calls (pull / up / inspect / start); `0` disables |
| `LOCK_STALE_SECONDS` | `0` | Log the lock's age when a competing run has held it this long; `0` disables |
| `LOG_MAX_SIZE_KB` | `0` | Rotate above this size at startup; 0 disables rotation; retain five compressed archives |
| `NOTIFY_FAILURE_WEBHOOK` | empty | Optional failure notification endpoint |
| `NOTIFY_SUCCESS_WEBHOOK` | empty | Optional successful-run summary endpoint |
| `RUN_HOOKS` | `true` | Run trusted pre/post-update scripts |
| `COMPOSE_WAIT_TIMEOUT` | unset | Legacy alias used when `WAIT_TIMEOUT` is unset |

Booleans accept exactly `true` or `false`. `--wait-timeout 0` or a zero timeout setting selects the bounded 300-second default. Numeric settings accept nonnegative integers of up to nine digits, with no leading zeros. Dry runs still create logs and acquire locks, and may rotate an existing log.

## Update behavior

The scanner recognizes `compose.yaml`, `compose.yml`, `docker-compose.yaml`, and `docker-compose.yml`. Commands run inside each stack directory, leaving filename precedence, automatic override files, and stack `.env` settings to Compose. Inherited Compose settings such as `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` still apply; avoid setting these globally unless that is intended for every stack.

Only running or restarting services are selected. Paused-only and stopped-only services are skipped. Image pulls use `--ignore-buildable` to safely skip locally-built services. Dependency ordering and network links (such as VPN sidecars) are preserved during recreation, and orphan containers are neither selected nor removed. Compose applies the current configuration as well as new images. Updates happen at **service granularity**: if a scaled service has a mix of active and stopped/paused replicas, Compose may reconcile all its replicas. Exclude such stacks if individual replica states must be preserved.

A failed pull skips recreation for that stack. Status, autostart, pull, startup, and pruning failures are logged and result in exit code 1; other stacks continue where possible. Pruning is skipped after failures. Docker/Compose preflight failures stop the run. Success, including no eligible stacks, returns 0. Interrupts use exit codes 130/143.

The health wait detects startup failures; it does not roll back updates or guarantee continued health. Services without health checks need only reach the running state. `WAIT_TIMEOUT` bounds the health wait only, not image downloads or the whole command. `STACK_TIMEOUT` additionally bounds each individual Docker call, so a Docker socket call that wedges cannot stall the run — and therefore the run lock — indefinitely; when it fires, the failure is logged with the cap that triggered it. Set `STACK_TIMEOUT` below your scheduler's interval so one stack cannot consume the whole window. Note that `STACK_TIMEOUT` requires `timeout` on `PATH`, and a stack-level cap cannot tear down a nested Compose child that ignores `SIGTERM`, which is why no whole-run timeout option is offered: a run-wide cap that cannot reliably kill its own children would only give false assurance. `image prune -f` removes dangling images across the daemon, including images unrelated to included stacks; it does not remove all unused tagged images. Set `PRUNE_IMAGES=false` to disable this.

### Optional autostart

Enable `AUTOSTART=true` and add this **container label** to services you want recovered:

```yaml
services:
  app:
    image: example/app:latest
    restart: unless-stopped
    labels:
      container-updater.autostart: "true"
```

The container must have the label applied by Compose and use `always` or `unless-stopped`. This opts it into being started even after a manual stop: restart policy alone cannot identify why it stopped. Only exited containers in discovered, non-excluded projects are considered. Autostart is disabled by default, a change from the previous version's global recovery behavior.

### Failure notifications

Failure payloads include `service`, `error`, and `host`, plus `text` and `content` message fields. Successful-run payloads include `status`, `updated`, `skipped`, `total`, `duration`, `host`, `text`, and `content`. Logs also summarize updated, skipped, planned, and failed operations and elapsed seconds. JSON strings are escaped, requests have a 10-second connect timeout and 30-second total timeout, and delivery failures are logged. Dry runs do not send notifications. The message fields retain the remote version’s Slack/Discord-oriented payload format; endpoint compatibility has not been verified against live services. Other providers may require an adapter.

### Synology DSM compatibility & Docker autodetection

On systems like Synology DSM, Task Scheduler executes scheduled user-defined scripts in a restricted environment with a minimal `PATH` (`/bin:/sbin:/usr/bin:/usr/sbin`). As a result, standard paths like `/usr/local/bin` and package directories are missing from the environment.

`updater.sh` automatically handles this:
1. It inspects and expands `PATH` with `/usr/local/bin`, `/usr/syno/bin`, `/var/packages/ContainerManager/target/usr/bin`, and `/var/packages/Docker/target/usr/bin` if present.
2. If `DOCKER_BIN` is not explicitly configured, it searches `PATH` and probes known candidate locations:
   - `/usr/local/bin/docker` (standard Synology symlink)
   - `/var/packages/ContainerManager/target/usr/bin/docker` (DSM 7 Container Manager)
   - `/var/packages/Docker/target/usr/bin/docker` (DSM 6 / legacy Docker package)
   - `/usr/syno/bin/docker`
   - `/snap/bin/docker`
   - `/usr/bin/docker` and `/bin/docker`
3. When resolved, the directory containing Docker is also added to `PATH` so Docker Compose plugins and companion tools are discoverable.

### Self-updating from GitHub releases

`updater.sh` can automatically check for and download new releases from GitHub:

- **Manual update**: Run `./updater.sh --self-update` (or `-u`) to check GitHub releases, download updates, verify integrity, and atomically update the script in place.
- **Scheduled updates**: Set `SELF_UPDATE=true` in `.env` or pass `--auto-update`. Before updating stacks, the script checks for a newer version tag on GitHub. If found, it updates `updater.sh` and restarts execution cleanly via `exec` under the existing process lock.
- **Verification & safety**:
  - The updater attempts to download the release asset `updater.sh` first, falling back to the raw repository script for the release tag.
  - Downloaded updates are strictly validated before replacement: verifying non-empty content, bash shebang, and bash syntax check (`bash -n`).
  - Dry runs (`-d`, `--dry-run`) report when a newer release is available without mutating the script.

### Lock migration

`flock` releases the lock automatically after the updater and its child commands exit, including crashes. The lock file remains on disk; its presence does not mean a run is active. Never delete it during a run. All invocations must use the same lock path to serialize access.

When upgrading from the previous PID/directory lock implementation, let old runs finish before launching the new version. Old `.lock.d` directories are ignored by the new version; mixed old/new script versions do not share a locking protocol.

## Scheduling and logs

For Sundays at 3 AM:

```cron
0 3 * * 0 /absolute/path/to/updater.sh
```

Inspect `LOG_FILE` for details, or use `VERBOSE=true` interactively. Exit status can be monitored by a scheduler.

## Development & CI

Run syntax verification and the full regression test suite locally:

```bash
bash -n updater.sh
python3 -m unittest discover -s tests -v
```

Automated testing is configured via GitHub Actions in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which automatically validates Bash syntax, runs ShellCheck linting, and executes all 52 regression tests on every push and pull request.

