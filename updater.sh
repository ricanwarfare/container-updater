#!/bin/bash
set -eo pipefail

# ---------------- CONFIGURATION ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
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

EXCLUDED=()
if [ -n "${EXCLUDE_DIRS:-}" ]; then
    IFS=':' read -ra EXCLUDED <<< "$EXCLUDE_DIRS"
fi

if [ -z "${DOCKER_BIN:-}" ]; then
    if command -v docker >/dev/null 2>&1; then
        DOCKER_BIN=$(command -v docker)
    else
        echo "[FATAL] docker command not found in PATH. Please install Docker or set DOCKER_BIN."
        exit 1
    fi
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "[FATAL] BASE_DIR '$BASE_DIR' does not exist"
    exit 1
fi
# -----------------------------------------------

# Atomic lock using mkdir (fails if the lock dir already exists — no TOCTOU race).
LOCK_DIR="${LOCK_FILE}.d"
mkdir -p "$(dirname "$LOCK_FILE")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "[FATAL] Another updater instance is already running (PID $LOCK_PID). Remove $LOCK_DIR if stale."
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    # Stale lock — retry once after clearing
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[FATAL] Could not acquire lock at $LOCK_DIR"
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT

DOCKER_DIRS=()
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

    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ] || [ -f "$dir/compose.yml" ] || [ -f "$dir/compose.yaml" ]; then
        DOCKER_DIRS+=("$dir")
    fi
done

LOG_DIR=$(dirname "$LOG_FILE")
if ! mkdir -p "$LOG_DIR"; then
    echo "[FATAL] Failed to create log directory '$LOG_DIR'"
    exit 1
fi

# Rotate log if it exceeds LOG_MAX_SIZE_KB (0 = disabled)
if [ "$LOG_MAX_SIZE_KB" -gt 0 ] && [ -f "$LOG_FILE" ]; then
    LOG_SIZE_KB=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)
    if [ -n "$LOG_SIZE_KB" ] && [ "$LOG_SIZE_KB" -gt "$LOG_MAX_SIZE_KB" ]; then
        ROTATED="${LOG_FILE}.$(date '+%Y%m%d%H%M%S')"
        mv "$LOG_FILE" "$ROTATED"
        gzip "$ROTATED" 2>/dev/null || true
        # Keep only last 5 rotated logs
        ls -t "${LOG_FILE}".*.gz 2>/dev/null | tail -n +6 | xargs -r rm -f 2>/dev/null || true
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
        # Escape for JSON string context (backslash, quote, control chars) to
        # prevent JSON injection via service/error values.
        local esc_service esc_error
        esc_service=$(printf '%s' "$service" | sed 's/\\/\\\\/g; s/"/\\"/g')
        esc_error=$(printf '%s' "$error" | sed 's/\\/\\\\/g; s/"/\\"/g')
        curl -s -X POST "$NOTIFY_FAILURE_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"service\":\"$esc_service\",\"error\":\"$esc_error\",\"host\":\"$(hostname)\"}" \
            >> "$LOG_FILE" 2>&1 || true
    fi
}

log_msg "====================================================="
log_msg "Global Update started"

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

if [ ${#DOCKER_DIRS[@]} -eq 0 ]; then
    log_msg "[WARNING] No docker compose directories found in $BASE_DIR"
    log_msg "Global Update finished"
    log_msg "====================================================="
    echo "[WARNING] No docker compose directories found in $BASE_DIR"
    exit 0
fi

for DIR in "${DOCKER_DIRS[@]}"; do
    log_msg "Processing: $DIR"

    if [ ! -d "$DIR" ]; then
        log_msg "  [ERROR] Directory $DIR does not exist. Skipping."
        continue
    fi

    if ! pushd "$DIR" > /dev/null; then
        log_msg "  [ERROR] Failed to enter directory $DIR. Skipping."
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
        popd > /dev/null
        continue
    fi

    # Get services that are currently running, restarting, or paused
    RUNNING_SERVICES=()
    if ! PS_OUTPUT=$( "$DOCKER_BIN" compose -f "$COMPOSE_FILE" ps --services --status running --status restarting --status paused 2>&1 ); then
        log_msg "  [ERROR] Failed to check service status in $DIR. Output: $PS_OUTPUT"
        send_failure_webhook "$DIR" "Failed to check service status"
        popd > /dev/null
        continue
    fi

    if [ -z "$PS_OUTPUT" ]; then
        log_msg "  - No services are currently running. Skipping update to avoid restarting manually stopped containers."
        popd > /dev/null
        continue
    fi

    while IFS= read -r service; do
        if [ -n "$service" ]; then
            RUNNING_SERVICES+=("$service")
        fi
    done <<< "$PS_OUTPUT"

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $DIR/$COMPOSE_FILE pull ${RUNNING_SERVICES[*]}"
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
            send_failure_webhook "$DIR" "Failed to pull images"
            popd > /dev/null
            continue
        fi
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $DIR/$COMPOSE_FILE up -d --remove-orphans --wait ${RUNNING_SERVICES[*]}"
    else
        log_msg "  - Updating and starting running containers (${RUNNING_SERVICES[*]})..."
        if ! "$DOCKER_BIN" compose -f "$COMPOSE_FILE" up -d --remove-orphans --wait "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
            log_msg "  [ERROR] Containers in $DIR completely failed to start or be healthy!"
            send_failure_webhook "$DIR" "Containers failed to start"
        else
            log_msg "  - Successfully updated $DIR."
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

log_msg "Global Update finished"
log_msg "====================================================="
exit 0