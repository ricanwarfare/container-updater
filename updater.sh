#!/bin/bash
set -eo pipefail

# ---------------- CONFIGURATION ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

BASE_DIR="${BASE_DIR:-$HOME/docker}"
LOG_FILE="${LOG_FILE:-$BASE_DIR/docker-updater/docker_update.log}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
LOCK_FILE="${LOCK_FILE:-$BASE_DIR/docker-updater/updater.lock}"
VERBOSE="${VERBOSE:-false}"

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

if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "[FATAL] Another updater instance is already running (PID $LOCK_PID). Remove $LOCK_FILE if stale."
        exit 1
    fi
    rm -f "$LOCK_FILE"
fi
mkdir -p "$(dirname "$LOCK_FILE")"
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

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
        curl -s -X POST "$NOTIFY_FAILURE_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"service\":\"$service\",\"error\":\"$error\",\"host\":\"$(hostname)\"}" \
            >> "$LOG_FILE" 2>&1 || true
    fi
}

log_msg "====================================================="
log_msg "Global Update started"

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

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $DIR/$COMPOSE_FILE pull"
    else
        log_msg "  - Pulling images..."
        if ! "$DOCKER_BIN" compose -f "$COMPOSE_FILE" pull >> "$LOG_FILE" 2>&1; then
            log_msg "  [ERROR] Failed to pull images in $DIR. Skipping update."
            send_failure_webhook "$DIR" "Failed to pull images"
            popd > /dev/null
            continue
        fi
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_msg "  [DRY RUN] Would run: $DOCKER_BIN compose -f $DIR/$COMPOSE_FILE up -d --remove-orphans --wait"
    else
        log_msg "  - Updating and starting containers..."
        if ! "$DOCKER_BIN" compose -f "$COMPOSE_FILE" up -d --remove-orphans --wait >> "$LOG_FILE" 2>&1; then
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
