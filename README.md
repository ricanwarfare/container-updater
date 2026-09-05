# Auto Docker Updater

A Bash utility that discovers Docker Compose stacks in the immediate subdirectories of `BASE_DIR`, pulls images for active services, and recreates them with a bounded health wait.

## Requirements

- Linux with Bash 4.3+, `flock` (util-linux), and standard utilities (`gzip` for compressed log rotation).
- Docker with access to its daemon, and the Compose V2 plugin supporting `up --wait --wait-timeout` and `ps --orphans`.
- `curl` if failure webhooks are enabled.
- Python 3 only to run the regression tests.

## Setup

Place `updater.sh` in your preferred directory and make it executable:

```bash
chmod +x updater.sh
cp .env.example .env
```

Edit `.env` for your installation. The script sources this file as **trusted Bash code**, so quote paths containing spaces and restrict write access. Existing installations should preserve their own `.env` instead of copying over it. This repository's legacy `.env` is still tracked; `.gitignore` does not untrack it. Avoid putting credentials in that tracked file.

Explicit environment variables override `.env`; `.env` overrides defaults:

```bash
BASE_DIR=/opt/containers DRY_RUN=true VERBOSE=true ./updater.sh
```

Relative paths resolve from the directory where the updater is invoked. Use absolute paths in cron jobs. Logs and locks are resolved before entering stack directories.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `BASE_DIR` | `$HOME/docker` | Parent of stack directories |
| `EXCLUDE_DIRS` | empty | Colon-separated folder names to skip, including autostart |
| `DOCKER_BIN` | Docker in `PATH` | Docker executable path |
| `LOG_FILE` | `$BASE_DIR/container-updater/updater.log` | Append-only run log |
| `LOCK_FILE` | `$BASE_DIR/container-updater/updater.lock` | Persistent file used for a kernel lock |
| `DRY_RUN` | `false` | Inspect and log proposed actions without Docker mutations or webhooks |
| `VERBOSE` | `false` | Also print log messages to the console |
| `PRUNE_IMAGES` | `true` | Prune host-wide dangling images after a failure-free run with discovered stacks |
| `AUTOSTART` | `false` | Recover explicitly labelled exited containers in included stacks |
| `AUTOSTART_RETRY_DELAY` | `10` | Seconds before one retry of failed starts |
| `PULL_RETRIES` | `3` | Maximum pull attempts, at least 1 |
| `PULL_RETRY_DELAY` | `5` | Seconds between failed pull attempts |
| `WAIT_TIMEOUT` | `300` | Maximum seconds for Compose's running/healthy wait, at least 1 |
| `LOG_MAX_SIZE_KB` | `0` | Rotate above this size at startup; 0 disables rotation; retain five compressed archives |
| `NOTIFY_FAILURE_WEBHOOK` | empty | Optional endpoint accepting the generic JSON payload below |

Booleans accept exactly `true` or `false`. Numeric settings accept nonnegative integers of up to nine digits, with no leading zeros. Dry runs still create logs and acquire locks, and may rotate an existing log.

## Update behavior

The scanner recognizes `compose.yaml`, `compose.yml`, `docker-compose.yaml`, and `docker-compose.yml`. Commands run inside each stack directory, leaving filename precedence, automatic override files, and stack `.env` settings to Compose. Inherited Compose settings such as `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` still apply; avoid setting these globally unless that is intended for every stack.

Only running or restarting services are selected. Paused-only and stopped-only services are skipped. `up --no-deps` avoids starting stopped dependencies, and orphan containers are neither selected nor removed. Compose applies the current configuration as well as new images. Updates happen at **service granularity**: if a scaled service has a mix of active and stopped/paused replicas, Compose may reconcile all its replicas. Exclude such stacks if individual replica states must be preserved.

A failed pull skips recreation for that stack. Status, autostart, pull, startup, and pruning failures are logged and result in exit code 1; other stacks continue where possible. Pruning is skipped after failures. Docker/Compose preflight failures stop the run. Success, including no eligible stacks, returns 0. Interrupts use exit codes 130/143.

The health wait detects startup failures; it does not roll back updates or guarantee continued health. Services without health checks need only reach the running state. The timeout bounds the health wait, not image downloads or the entire command. `image prune -f` removes dangling images across the daemon, including images unrelated to included stacks; it does not remove all unused tagged images. Set `PRUNE_IMAGES=false` to disable this.

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

The endpoint receives `{"service":"...","error":"...","host":"..."}`. JSON strings are escaped, requests have a 10-second connect timeout and 30-second total timeout, and delivery failures are logged. Dry runs do not send notifications. This is a generic webhook format; Slack and Discord require their own payload adapter and are not supported directly.

### Lock migration

`flock` releases the lock automatically after the updater and its child commands exit, including crashes. The lock file remains on disk; its presence does not mean a run is active. Never delete it during a run. All invocations must use the same lock path to serialize access.

When upgrading from the previous PID/directory lock implementation, let old runs finish before launching the new version. Old `.lock.d` directories are ignored by the new version; mixed old/new script versions do not share a locking protocol.

## Scheduling and logs

For Sundays at 3 AM:

```cron
0 3 * * 0 /absolute/path/to/updater.sh
```

Inspect `LOG_FILE` for details, or use `VERBOSE=true` interactively. Exit status can be monitored by a scheduler.

## Development

```bash
bash -n updater.sh
python3 -m unittest discover -s tests -v
```

Tests use an isolated fake Docker executable and temporary stacks; they never operate real containers. See [REVIEW.md](REVIEW.md) for the review results, verification limits, and recommended features.
