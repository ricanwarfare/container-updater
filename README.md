# Auto Docker Updater

A robust, crash-resistant bash script that automatically detects and updates all your Docker Compose stacks. 

## Features

- **Auto-Detection**: Scans a specified base directory for any folders containing a `docker-compose.yml` or `compose.yml` file, eliminating the need to manually list out every single container stack.
- **Crash Prevention**: Uses the `--wait` flag during `docker compose up`. The script pauses until containers are fully running and healthy, catching any immediate crash-loops introduced by bad updates.
- **Safe Directory Navigation**: Implements strict directory navigation checks. If a folder's permissions change or it is deleted during the run, the script gracefully logs it and skips, preventing commands from running in the wrong path.
- **Comprehensive Logging**: Outputs detailed, timestamp-accurate logs to an auto-generated log file, making it easy to track the timeline of when a stack was updated or if a failure occurred.
- **Auto Cleanup**: Automatically prunes dangling and unused Docker images at the end of the update cycle to save disk space.

## Requirements

- `docker` and `docker compose` (V2 plugin) installed.
- Bash shell.

## Setup & Configuration

1. Rename `updater.sh.txt` to `updater.sh` and place it wherever you prefer (e.g., in a `scripts` folder).
2. Make the script executable:
   ```bash
   chmod +x updater.sh
   ```

### Configuring for Different Systems / Users

The script comes with safe defaults (e.g., `BASE_DIR="/home/docker/docker"`), but it is fully adaptable for different servers without needing to edit the code. You have two options:

**Option A: Using a `.env` file (Recommended)**
Create a file named `.env` in the exact same folder as `updater.sh` to override defaults securely:
```env
BASE_DIR=/opt/my-containers
LOG_FILE=/var/log/docker-updater.log
```

**Option B: Using Environment Variables**
You can pass the variables inline when executing the script, which is perfect for CI/CD or custom cron jobs:
```bash
BASE_DIR=/home/agustin/docker ./updater.sh
```

*(Note: The script automatically detects the `docker` binary location using your system's PATH. You do not need to configure `DOCKER_BIN` unless your setup is highly non-standard.)*

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
tail -f /home/docker/docker/docker-updater/docker_update.log
```
