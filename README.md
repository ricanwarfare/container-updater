# Auto Docker Updater

A robust, crash-resistant bash script that automatically detects and updates all your Docker Compose stacks.

## Features

- **Auto-Detection**: Scans a specified base directory for any folders containing a `docker-compose.yml` or `compose.yml` file, eliminating the need to manually list out every single container stack.
- **Folder Exclusion**: Allows you to skip specific directories from the scan using a simple colon-separated list.
- **Crash Prevention**: Uses the `--wait` flag during `docker compose up`. The script pauses until containers are fully running and healthy, catching any immediate crash-loops introduced by bad updates.
- **Safe Directory Navigation**: Uses `pushd`/`popd` for safe directory navigation. If a folder's permissions change or it is deleted during the run, the script gracefully logs it and skips.
- **Self-Healing Autostart**: Detects and restarts stopped containers with `always` or `unless-stopped` restart policies (ideal for resolving dependency startup races, e.g. VPN containers).
- **Stale Lock Recovery & Overlap Protection**: Directory-based atomic locking prevents concurrent runs and automatically recovers if a previous run was killed or crashed.
- **Comprehensive Logging & Rotation**: Outputs timestamped logs with automated size-based log rotation and compression (`.gz`).
- **Universal Failure Notifications**: Send webhook notifications compatible with Slack, Discord, Mattermost, Teams, and generic webhook endpoints when pull or up operations fail.
- **Execution Summary & Exit Codes**: Displays total execution time, updated/skipped/failed counts, and returns non-zero exit status if failures occur for automated monitoring.
- **Success & Heartbeat Webhooks**: Send optional notification upon successful runs (ideal for Uptime Kuma, Healthchecks.io, or Discord/Slack logs).
- **Per-Stack Ignore (`.updaterignore`)**: Place an `.updaterignore` file inside any container directory to skip updating that stack.
- **Pre-Update & Post-Update Hooks**: Automatically execute `pre-update.sh` (e.g. for database backups) and `post-update.sh` (e.g. for notifications or cache warmups) per stack.
- **Configurable Healthcheck Timeout**: Prevent hanging updates by setting `--wait-timeout` for services with slow startup times.
- **Auto Cleanup**: Optionally prunes dangling and unused Docker images at the end of the update cycle to save disk space.
- **CLI Flags**: Supports command-line options (`--dry-run`, `--verbose`, `--base-dir`, `--wait-timeout`, `--no-hooks`, etc.) alongside environment variable and `.env` configuration.

## Requirements

- `docker` and `docker compose` (V2 plugin) installed.
- Bash shell (Linux, macOS, WSL).

## Setup & Configuration

1. Clone or download `updater.sh` and place it wherever you prefer (e.g., in a `scripts` folder).
2. Make the script executable:
   ```bash
   chmod +x updater.sh
   ```

### Configuring for Different Systems / Users

The script comes with safe defaults (e.g., `BASE_DIR="$HOME/docker"`), but it is fully adaptable for different servers without needing to edit the code. You have three options:

**Option A: Using a `.env` file (Recommended)**
Create a file named `.env` in the exact same folder as `updater.sh` to override defaults securely:
```env
BASE_DIR=/opt/my-containers
LOG_FILE=/var/log/container-updater.log
EXCLUDE_DIRS=container-updater:backups:testing
PRUNE_IMAGES=true
VERBOSE=true
AUTOSTART=true
PULL_RETRIES=5
PULL_RETRY_DELAY=30
LOG_MAX_SIZE_KB=5120
COMPOSE_WAIT_TIMEOUT=60
RUN_HOOKS=true
```

**Option B: Using Command Line Flags**
```bash
./updater.sh --dry-run --verbose --base-dir /opt/my-containers --wait-timeout 60
```

**Option C: Using Environment Variables**
You can pass the variables inline when executing the script, which is perfect for CI/CD or custom cron jobs:
```bash
BASE_DIR=/home/$USER/docker EXCLUDE_DIRS=backups ./updater.sh
```

*(Note: The script automatically detects the `docker` binary location using your system's PATH. You do not need to configure `DOCKER_BIN` unless your setup is highly non-standard.)*

### CLI Options

| Flag | Description |
| --- | --- |
| `-d, --dry-run` | Simulate actions without pulling images or updating containers |
| `-v, --verbose` | Print log output to stdout in addition to the log file |
| `-b, --base-dir <dir>` | Specify the base directory containing docker compose stacks |
| `-p, --prune` | Prune unused images after update (default: true) |
| `--no-prune` | Disable image pruning after update |
| `--no-autostart` | Disable autostarting exited containers with restart policies |
| `--wait-timeout <sec>` | Set maximum seconds to wait for containers to be healthy |
| `--no-hooks` | Disable execution of `pre-update.sh` and `post-update.sh` hooks |
| `-h, --help` | Display help message and exit |

### Additional Configuration Options

**Dry-Run Mode**
Test your configuration without making any actual changes. Dry-run logs show the exact commands that would be executed:
```bash
./updater.sh --dry-run
```

**Verbose Mode**
Print all log messages to the console in addition to the log file (useful for interactive debugging):
```bash
./updater.sh --verbose
```

**Image Pruning**
Control whether unused Docker images are pruned after the update cycle (enabled by default):
```env
PRUNE_IMAGES=false
```

**Autostart Exited Containers**
Self-heals containers with `always` or `unless-stopped` restart policies before running updates:
```env
AUTOSTART=true
AUTOSTART_RETRY_DELAY=10
```

**Log Rotation**
Automatically rotates and compresses the log file when it exceeds a maximum size (in KB), keeping the last 5 logs:
```env
LOG_MAX_SIZE_KB=5120
```

**Failure & Success Notifications**
Get notified when container updates fail or succeed via a webhook. Compatible with Slack, Discord, Mattermost, Microsoft Teams, and custom HTTP endpoints:
```env
NOTIFY_FAILURE_WEBHOOK=https://discord.com/api/webhooks/XXX/YYY
NOTIFY_SUCCESS_WEBHOOK=https://discord.com/api/webhooks/XXX/YYY
# or Slack:
# NOTIFY_FAILURE_WEBHOOK=https://hooks.slack.com/services/XXX/YYY/ZZZ
```

**Pre-Update & Post-Update Hooks**
You can place executable shell scripts inside any stack folder:
- `pre-update.sh`: Runs before images are pulled and updated. If this script exits with a non-zero code, update for this stack is safely aborted.
- `post-update.sh`: Runs after containers have been updated and verified healthy.

**Image Pull Retries**
Automatically retries `docker compose pull` operations if a transient network or registry rate-limit error (HTTP 429 `toomanyrequests`) occurs:
```env
PULL_RETRIES=5
PULL_RETRY_DELAY=30
```

**Lock File**
Prevents overlapping runs by creating an atomic lock directory and PID file. If a previous instance was killed or crashed, stale locks are automatically cleared on the next run:
```env
LOCK_FILE=/path/to/updater.lock
```

### Excluding Folders & Stacks

You can exclude stacks in two ways:
1. **Global Exclusion**: Set `EXCLUDE_DIRS` with a colon-separated list of folder names:
   ```env
   EXCLUDE_DIRS=container-updater:backups:testing
   ```
2. **Per-Stack Ignore**: Create an empty `.updaterignore` file inside any stack directory.

## Usage

Simply run the script manually:

```bash
./updater.sh
```

### Automating with Cron

You can set this script up to run automatically on a schedule using a cron job. For example, to run it every Sunday at 3:00 AM:

1. Open your crontab editor:
   ```bash
   crontab -e
   ```
2. Add the following line:
   ```bash
   0 3 * * 0 /absolute/path/to/updater.sh
   ```

## Checking Logs

The script generates detailed logs in the path specified by the `LOG_FILE` configuration. You can monitor them live using:

```bash
tail -f /home/$USER/docker/container-updater/updater.log
```


