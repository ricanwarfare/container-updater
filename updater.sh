#!/bin/bash
set -eo pipefail

# ---------------- CONFIGURATION ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    # Strip carriage returns on-the-fly to prevent syntax errors if .env was edited on Windows
    # shellcheck disable=SC1090
    source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
fi

BASE_DIR="${BASE_DIR:-$HOME/docker}"
LOG_FILE="${LOG_FILE:-$BASE_DIR/container-updater/updater.log}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
LOCK_FILE="${LOCK_FILE:-$BASE_DIR/container-updater/updater.lock}"
VERBOSE="${VERBOSE:-false}"
AUTOSTART="${AUTOSTART:-true}"
AUTOSTART_RETRY_DELAY="${AUTOSTART_RETRY_DELAY:-10}"
PULL_RETRIES="${PULL_RETRIES:-3}"
PULL_RETRY_DELAY="${PULL_RETRY_DELAY:-5}"
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-0}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-0}"
RUN_HOOKS="${RUN_HOOKS:-true}"
NOTIFY_SUCCESS_WEBHOOK="${NOTIFY_SUCCESS_WEBHOOK:-}"

# CLI Arguments Parsing
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Auto Docker Updater - Automatically detects and updates Docker Compose stacks.

Options:
  -d, --dry-run               Simulate actions without pulling images or updating containers
  -v, --verbose               Print log output to stdout in addition to the log file
  -b, --base-dir DIR          Specify the base directory containing docker compose stacks
  -p, --prune                 Prune unused images after update (default: true)
  --no-prune                  Do not prune unused images after update
  --no-autostart              Do not autostart exited containers with restart policies
  --wait-timeout SECONDS      Set timeout in seconds for containers to be healthy (0 = default)
  --no-hooks                  Disable execution of pre-update.sh and post-update.sh hooks
  -h, --help                  Display this help message and exit

Environment variables can also be set via a .env file in the script directory.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -b|--base-dir)
            if [ -n "${2:-}" ]; then
                BASE_DIR="$2"
                shift 2
            else
                echo "[FATAL] --base-dir requires a directory argument" >&2
                exit 1
            fi
            ;;
        -p|--prune)
            PRUNE_IMAGES="true"
            shift
            ;;
        --no-prune)
            PRUNE_IMAGES="false"
            shift
            ;;
        --no-autostart)
            AUTOSTART="false"
            shift
            ;;
        --wait-timeout)
            if [ -n "${2:-}" ]; then
                COMPOSE_WAIT_TIMEOUT="$2"
                shift 2
            else
                echo "[FATAL] --wait-timeout requires a numeric seconds argument" >&2
                exit 1
            fi
            ;;
        --no-hooks)
            RUN_HOOKS="false"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "[FATAL] Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

EXCLUDED=()
if [ -n "${EXCLUDE_DIRS:-}" ]; then
    IFS=':' read -ra EXCLUDED <<< "$EXCLUDE_DIRS"
fi

if [ -z "${DOCKER_BIN:-}" ]; then
    if command -v docker >/dev/null 2>&1; then
        DOCKER_BIN=$(command -v docker)
    else
        echo "[FATAL] docker command not found in PATH. Please install Docker or set DOCKER_BIN." >&2
        exit 1
    fi
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "[FATAL] BASE_DIR '$BASE_DIR' does not exist" >&2
    exit 1
fi
# -----------------------------------------------

# Atomic lock using mkdir (fails if the lock dir already exists — no TOCTOU race).
LOCK_DIR="${LOCK_FILE}.d"
mkdir -p "$(dirname "$LOCK_FILE")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_PID=""
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
    fi

    if [ -n "$LOCK_PID" ] && [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "[FATAL] Another updater instance is already running (PID $LOCK_PID)." >&2
        exit 1
    fi

    # Stale lock detected (dead process or missing PID file) — clear lockdir and retry
    rm -f "$LOCK_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[FATAL] Could not acquire lock at $LOCK_DIR" >&2
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"

cleanup_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

# Scan Docker Compose directories
DOCKER_DIRS=()
shopt -s nullglob
for dir in "$BASE_DIR"/*/ ; do
    dir="${dir%/}"
    basename="$(basename "$dir")"

    skip=false
    for ex in "${EXCLUDED[@]}"; do
        if [ "$basename" = "$ex" ]; then
            skip=true
            break
        fi
    done
    if $skip; then
        continue
    fi

    if [ -f "$dir/.updaterignore" ]; then
        continue
    fi

    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ] || [ -f "$dir/compose.yml" ] || [ -f "$dir/compose.yaml" ]; then
        DOCKER_DIRS+=("$dir")
    fi
done
shopt -u nullglob

LOG_DIR=$(dirname "$LOG_FILE")
if ! mkdir -p "$LOG_DIR"; then
    echo "[FATAL] Failed to create log directory '$LOG_DIR'" >&2
    exit 1
fi

# Rotate log if it exceeds LOG_MAX_SIZE_KB (0 = disabled)
if [ "$LOG_MAX_SIZE_KB" -gt 0 ] 2>/dev/null && [ -f "$LOG_FILE" ]; then
    LOG_SIZE_KB=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)
    if [ -n "$LOG_SIZE_KB" ] && [ "$LOG_SIZE_KB" -gt "$LOG_MAX_SIZE_KB" ]; then
        ROTATED="${LOG_FILE}.$(date '+%Y%m%d%H%M%S')"
        mv "$LOG_FILE" "$ROTATED"
        gzip "$ROTATED" 2>/dev/null || true

        # Clean up old rotated logs (both .gz and uncompressed), keeping newest 5
        find "$LOG_DIR" -maxdepth 1 -name "$(basename "$LOG_FILE").*" | sort -r | tail -n +6 | while IFS= read -r old_log; do
            [ -n "$old_log" ] && rm -f "$old_log" 2>/dev/null || true
        done
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated (was ${LOG_SIZE_KB}KB, max ${LOG_MAX_SIZE_KB}KB)" >> "$LOG_FILE"
    fi
fi

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    if [ "$VERBOSE" = "true" ]; then
        echo "$msg"
    fi
}

send_failure_webhook() {
    local service="$1"
    local error="$2"
    if [ -n "${NOTIFY_FAILURE_WEBHOOK:-}" ]; then
        # Escape characters for valid JSON (quotes, backslashes, tabs, newlines, carriage returns)
        local esc_service esc_error esc_host current_host notification_text
        current_host="$(hostname 2>/dev/null || echo 'unknown-host')"
        esc_service=$(printf '%s' "$service" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\r/\\r/g' -e 's/\n/\\n/g' -e 's/\t/\\t/g')
        esc_error=$(printf '%s' "$error" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\r/\\r/g' -e 's/\n/\\n/g' -e 's/\t/\\t/g')
        esc_host=$(printf '%s' "$current_host" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        notification_text="[${current_host}] Docker Updater Failure: Service '${service}' - ${error}"

        # JSON payload with 'text' (Slack/Mattermost) and 'content' (Discord) and structured fields
        local json_payload
        json_payload=$(printf '{"text":"%s","content":"%s","service":"%s","error":"%s","host":"%s"}' \
            "$(printf '%s' "$notification_text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
            "$(printf '%s' "$notification_text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
            "$esc_service" "$esc_error" "$esc_host")

        curl -s -X POST "$NOTIFY_FAILURE_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            >> "$LOG_FILE" 2>&1 || true
    fi
}

send_success_webhook() {
    local updated="$1"
    local skipped="$2"
    local total="$3"
    local duration="$4"
    if [ -n "${NOTIFY_SUCCESS_WEBHOOK:-}" ]; then
        local current_host esc_host notification_text json_payload
        current_host="$(hostname 2>/dev/null || echo 'unknown-host')"
        esc_host=$(printf '%s' "$current_host" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        notification_text="[${current_host}] Docker Updater Finished: ${updated}/${total} updated, ${skipped} skipped (${duration}s)"

        json_payload=$(printf '{"text":"%s","content":"%s","status":"success","updated":%d,"skipped":%d,"total":%d,"duration":%d,"host":"%s"}' \
            "$(printf '%s' "$notification_text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
            "$(printf '%s' "$notification_text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
            "$updated" "$skipped" "$total" "$duration" "$esc_host")

        curl -s -X POST "$NOTIFY_SUCCESS_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            >> "$LOG_FILE" 2>&1 || true
    fi
}

START_TIME=$(date +%s)
TOTAL_STACKS=${#DOCKER_DIRS[@]}
UPDATED_COUNT=0
SKIPPED_COUNT=0
FAILED_STACKS=()

log_msg "====================================================="
log_msg "Global Update started (Dry Run: $DRY_RUN, Base Dir: $BASE_DIR)"

# ---------------- AUTOSTART EXITED CONTAINERS ----------------
# Start exited containers that have unless-stopped or always restart policy.
# This self-heals containers that got stuck because a dependency (e.g. VPN)
# was down when they tried to restart.
if [ "$AUTOSTART" = "true" ]; then
    log_msg "Autostart: Checking for exited containers with unless-stopped/always restart policy..."

    EXITED_CONTAINERS=$("$DOCKER_BIN" ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null || true)

    if [ -n "$EXITED_CONTAINERS" ]; then
        TO_START=()
        RETRY_LIST=()

        while IFS= read -r name; do
            [ -z "$name" ] && continue
            POLICY=$("$DOCKER_BIN" inspect "$name" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "")
            if [ "$POLICY" = "unless-stopped" ] || [ "$POLICY" = "always" ]; then
                TO_START+=("$name")
            fi
        done <<< "$EXITED_CONTAINERS"

        if [ ${#TO_START[@]} -gt 0 ]; then
            log_msg "  Found ${#TO_START[@]} exited container(s) with autostart policy: ${TO_START[*]}"

            if [ "$DRY_RUN" = "true" ]; then
                log_msg "  [DRY RUN] Would start: ${TO_START[*]}"
            else
                # First pass: try to start all
                for name in "${TO_START[@]}"; do
                    if "$DOCKER_BIN" start "$name" >/dev/null 2>&1; then
                        log_msg "  - Started: $name"
                    else
                        log_msg "  - Failed to start: $name (will retry after delay)"
                        RETRY_LIST+=("$name")
                    fi
                done

                # If any failed, wait for dependencies (e.g. gluetun) to come up, then retry
                if [ ${#RETRY_LIST[@]} -gt 0 ]; then
                    log_msg "  Waiting ${AUTOSTART_RETRY_DELAY}s for dependencies to come up before retry..."
                    sleep "$AUTOSTART_RETRY_DELAY"
                    for name in "${RETRY_LIST[@]}"; do
                        if "$DOCKER_BIN" start "$name" >/dev/null 2>&1; then
                            log_msg "  - Started on retry: $name"
                        else
                            log_msg "  [ERROR] Failed to start on retry: $name"
                            send_failure_webhook "$name" "Container failed to autostart"
                        fi
                    done
                fi
            fi
        else
            log_msg "  No exited containers with autostart policy found."
        fi
    else
        log_msg "  No exited containers found."
    fi
    log_msg "Autostart phase complete."
else
    log_msg "Autostart: Skipped (AUTOSTART is disabled)"
fi
# -------------------------------------------------------------

if [ "$TOTAL_STACKS" -eq 0 ]; then
    log_msg "[WARNING] No docker compose directories found in $BASE_DIR"
    log_msg "Global Update finished (Duration: 0s)"
    log_msg "====================================================="
    echo "[WARNING] No docker compose directories found in $BASE_DIR"
    exit 0
fi

for DIR in "${DOCKER_DIRS[@]}"; do
    STACK_NAME="$(basename "$DIR")"
    log_msg "Processing: $DIR"

    if [ ! -d "$DIR" ]; then
        log_msg "  [ERROR] Directory $DIR does not exist. Skipping."
        FAILED_STACKS+=("$STACK_NAME (Directory missing)")
        continue
    fi

    if ! pushd "$DIR" > /dev/null; then
        log_msg "  [ERROR] Failed to enter directory $DIR. Skipping."
        FAILED_STACKS+=("$STACK_NAME (pushd failed)")
        continue
    fi

    COMPOSE_FILE=""
    for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$cf" ]; then
            COMPOSE_FILE="$cf"
            break
        fi
    done

    if [ -z "$COMPOSE_FILE" ]; then
        log_msg "  [ERROR] No compose file found in $DIR. Skipping."
        FAILED_STACKS+=("$STACK_NAME (No compose file)")
        popd > /dev/null
        continue
    fi

    # Get services that are currently running, restarting, or paused
    RUNNING_SERVICES=()
    if ! PS_OUTPUT=$( "$DOCKER_BIN" compose -f "$COMPOSE_FILE" ps --services --status running --status restarting --status paused 2>&1 ); then
        log_msg "  [ERROR] Failed to check service status in $DIR. Output: $PS_OUTPUT"
        send_failure_webhook "$STACK_NAME" "Failed to check service status"
        FAILED_STACKS+=("$STACK_NAME (ps check failed)")
        popd > /dev/null
        continue
    fi

    if [ -z "$PS_OUTPUT" ]; then
        log_msg "  - No services are currently running. Skipping update to avoid restarting manually stopped containers."
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        popd > /dev/null
        continue
    fi

    while IFS= read -r service; do
        if [ -n "$service" ]; then
            RUNNING_SERVICES+=("$service")
        fi
    done <<< "$PS_OUTPUT"

    # Pre-update hook execution
    if [ "$RUN_HOOKS" = "true" ] && [ -f "./pre-update.sh" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log_msg "  [DRY RUN] Would execute pre-update hook: ./pre-update.sh"
        else
            log_msg "  - Executing pre-update hook: ./pre-update.sh"
            if ! bash ./pre-update.sh >> "$LOG_FILE" 2>&1; then
                log_msg "  [ERROR] Pre-update hook failed in $DIR. Skipping update."
                send_failure_webhook "$STACK_NAME" "Pre-update hook failed"
                FAILED_STACKS+=("$STACK_NAME (pre-hook failed)")
                popd > /dev/null
                continue
            fi
        fi
    fi

    # Build compose up arguments
    UP_ARGS=(-d --remove-orphans --wait)
    if [ "$COMPOSE_WAIT_TIMEOUT" -gt 0 ] 2>/dev/null; then
        UP_ARGS+=(--wait-timeout "$COMPOSE_WAIT_TIMEOUT")
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $COMPOSE_FILE pull ${RUNNING_SERVICES[*]}"
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $COMPOSE_FILE up ${UP_ARGS[*]} ${RUNNING_SERVICES[*]}"
        if [ "$RUN_HOOKS" = "true" ] && [ -f "./post-update.sh" ]; then
            log_msg "  [DRY RUN] Would execute post-update hook: ./post-update.sh"
        fi
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        log_msg "  - Pulling images for running services (${RUNNING_SERVICES[*]})..."
        PULL_SUCCESS=false
        for (( attempt=1; attempt<=PULL_RETRIES; attempt++ )); do
            if "$DOCKER_BIN" compose -f "$COMPOSE_FILE" pull "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
                PULL_SUCCESS=true
                break
            else
                if [ "$attempt" -lt "$PULL_RETRIES" ]; then
                    log_msg "  [WARNING] Pull failed on attempt $attempt/$PULL_RETRIES. Retrying in ${PULL_RETRY_DELAY}s..."
                    sleep "$PULL_RETRY_DELAY"
                fi
            fi
        done

        if [ "$PULL_SUCCESS" = "false" ]; then
            log_msg "  [ERROR] Failed to pull images in $DIR after $PULL_RETRIES attempts. Skipping update."
            send_failure_webhook "$STACK_NAME" "Failed to pull images"
            FAILED_STACKS+=("$STACK_NAME (pull failed)")
            popd > /dev/null
            continue
        fi

        log_msg "  - Updating and starting running containers (${RUNNING_SERVICES[*]})..."
        if ! "$DOCKER_BIN" compose -f "$COMPOSE_FILE" up "${UP_ARGS[@]}" "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
            log_msg "  [ERROR] Containers in $DIR completely failed to start or be healthy!"
            send_failure_webhook "$STACK_NAME" "Containers failed to start"
            FAILED_STACKS+=("$STACK_NAME (up failed)")
        else
            log_msg "  - Successfully updated $DIR."
            UPDATED_COUNT=$((UPDATED_COUNT + 1))

            # Post-update hook execution
            if [ "$RUN_HOOKS" = "true" ] && [ -f "./post-update.sh" ]; then
                log_msg "  - Executing post-update hook: ./post-update.sh"
                if ! bash ./post-update.sh >> "$LOG_FILE" 2>&1; then
                    log_msg "  [WARNING] Post-update hook failed in $DIR."
                fi
            fi
        fi
    fi

    popd > /dev/null
done

if [ "$PRUNE_IMAGES" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
        log_msg "Global Prune: [DRY RUN] Would run: $DOCKER_BIN image prune -f"
    else
        log_msg "Global Prune: Removing unused images..."
        "$DOCKER_BIN" image prune -f >> "$LOG_FILE" 2>&1 || {
            log_msg "Global Prune: [WARNING] Image pruning failed"
        }
    fi
else
    log_msg "Global Prune: Skipped (PRUNE_IMAGES is disabled)"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_msg "================ SUMMARY ================"
log_msg "Total Stacks Found: $TOTAL_STACKS"
log_msg "Stacks Updated:     $UPDATED_COUNT"
log_msg "Stacks Skipped:     $SKIPPED_COUNT"
log_msg "Stacks Failed:      ${#FAILED_STACKS[@]}"
if [ ${#FAILED_STACKS[@]} -gt 0 ]; then
    log_msg "Failed Stacks List: ${FAILED_STACKS[*]}"
fi
log_msg "Total Duration:     ${DURATION}s"
log_msg "Global Update finished"
log_msg "========================================="

if [ ${#FAILED_STACKS[@]} -gt 0 ]; then
    exit 1
fi

send_success_webhook "$UPDATED_COUNT" "$SKIPPED_COUNT" "$TOTAL_STACKS" "$DURATION"
exit 0