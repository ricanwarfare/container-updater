#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit caller settings take precedence over the trusted shell config file.
CONFIG_KEYS=(BASE_DIR LOG_FILE DRY_RUN PRUNE_IMAGES LOCK_FILE VERBOSE AUTOSTART
    AUTOSTART_RETRY_DELAY PULL_RETRIES PULL_RETRY_DELAY LOG_MAX_SIZE_KB
    EXCLUDE_DIRS DOCKER_BIN NOTIFY_FAILURE_WEBHOOK WAIT_TIMEOUT)
declare -A CALLER_CONFIG=()
for key in "${CONFIG_KEYS[@]}"; do
    if [[ -v $key ]]; then CALLER_CONFIG[$key]="${!key}"; fi
done
if [ -f "$SCRIPT_DIR/.env" ]; then source "$SCRIPT_DIR/.env"; fi
for key in "${!CALLER_CONFIG[@]}"; do printf -v "$key" '%s' "${CALLER_CONFIG[$key]}"; done

BASE_DIR="${BASE_DIR:-$HOME/docker}"
# Resolve before entering stack directories so relative log/lock paths stay stable.
if [ ! -d "$BASE_DIR" ]; then
    echo "[FATAL] BASE_DIR '$BASE_DIR' does not exist" >&2
    exit 1
fi
BASE_DIR=$(cd "$BASE_DIR" && pwd)
LOG_FILE="${LOG_FILE:-$BASE_DIR/container-updater/updater.log}"
LOCK_FILE="${LOCK_FILE:-$BASE_DIR/container-updater/updater.lock}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
VERBOSE="${VERBOSE:-false}"
AUTOSTART="${AUTOSTART:-false}"
AUTOSTART_RETRY_DELAY="${AUTOSTART_RETRY_DELAY:-10}"
PULL_RETRIES="${PULL_RETRIES:-3}"
PULL_RETRY_DELAY="${PULL_RETRY_DELAY:-5}"
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
for key in DRY_RUN PRUNE_IMAGES VERBOSE AUTOSTART; do
    if [[ ${!key} != true && ${!key} != false ]]; then
        echo "[FATAL] $key must be true or false" >&2
        exit 1
    fi
done
for key in AUTOSTART_RETRY_DELAY PULL_RETRIES PULL_RETRY_DELAY LOG_MAX_SIZE_KB WAIT_TIMEOUT; do
    if [[ ! ${!key} =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        echo "[FATAL] $key must be a nonnegative integer (at most 9 digits)" >&2
        exit 1
    fi
done
if (( PULL_RETRIES == 0 || WAIT_TIMEOUT == 0 )); then
    echo "[FATAL] PULL_RETRIES and WAIT_TIMEOUT must be positive" >&2
    exit 1
fi
DOCKER_BIN=$(command -v "${DOCKER_BIN:-docker}") || {
    echo "[FATAL] Docker executable not found" >&2; exit 1;
}
if [[ $DOCKER_BIN != /* ]]; then DOCKER_BIN="$PWD/$DOCKER_BIN"; fi
command -v flock >/dev/null || { echo "[FATAL] flock is required" >&2; exit 1; }
if [ -n "${NOTIFY_FAILURE_WEBHOOK:-}" ]; then
    command -v curl >/dev/null || { echo "[FATAL] curl is required for webhooks" >&2; exit 1; }
fi
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
LOG_FILE="$(cd "$(dirname "$LOG_FILE")" && pwd)/$(basename "$LOG_FILE")"
LOCK_FILE="$(cd "$(dirname "$LOCK_FILE")" && pwd)/$(basename "$LOCK_FILE")"
if [ "$LOG_FILE" = "$LOCK_FILE" ] || [ "$LOG_FILE" -ef "$LOCK_FILE" ]; then
    echo "[FATAL] LOG_FILE and LOCK_FILE must be different files" >&2
    exit 1
fi
# Kernel lock is released on exit, including crashes. Never unlink its inode.
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[FATAL] Another updater instance is already running" >&2
    exit 1
fi
trap 'exit 130' INT
trap 'exit 143' TERM

if (( LOG_MAX_SIZE_KB > 0 )) && [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE")
    if (( LOG_SIZE > LOG_MAX_SIZE_KB * 1024 )); then
        ROTATED="${LOG_FILE}.$(date '+%Y%m%d%H%M%S').$$"
        mv -- "$LOG_FILE" "$ROTATED"
        gzip -- "$ROTATED" || true
        # Timestamp names sort chronologically. Arrays preserve spaces/newlines.
        shopt -s nullglob
        ROTATIONS=("$LOG_FILE".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.gz)
        for (( i=0; i<${#ROTATIONS[@]}-5; i++ )); do rm -f -- "${ROTATIONS[i]}"; done
    fi
fi
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    if [ "$VERBOSE" = true ]; then printf '%s\n' "$msg"; fi
}
json_string() {
    local value="$1" char i code
    printf '"'
    for (( i=0; i<${#value}; i++ )); do
        char=${value:i:1}
        case "$char" in
            '"') printf '\\"' ;;
            '\') printf '\\\\' ;;
            *) printf -v code '%d' "'$char"
               if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$char"; fi ;;
        esac
    done
    printf '"'
}
FAILURES=0
fail() {
    local service="$1" error="$2" payload
    FAILURES=$((FAILURES + 1))
    log_msg "[ERROR] $service: $error"
    if [ -n "${NOTIFY_FAILURE_WEBHOOK:-}" ] && [ "$DRY_RUN" = false ]; then
        payload="{\"service\":$(json_string "$service"),\"error\":$(json_string "$error"),\"host\":$(json_string "$(hostname)")}"
        if ! curl --silent --show-error --fail --connect-timeout 10 --max-time 30 \
            -H 'Content-Type: application/json' --data "$payload" \
            "$NOTIFY_FAILURE_WEBHOOK" >> "$LOG_FILE" 2>&1; then
            log_msg '[WARNING] Failure webhook delivery failed'
        fi
    fi
}
log_msg 'Global Update started'
if ! "$DOCKER_BIN" info >> "$LOG_FILE" 2>&1; then
    fail Docker 'Daemon is unavailable'
    exit 1
fi
if ! "$DOCKER_BIN" compose version >> "$LOG_FILE" 2>&1; then
    fail Docker 'Compose V2 is unavailable'
    exit 1
fi

EXCLUDED=()
IFS=':' read -ra EXCLUDED <<< "${EXCLUDE_DIRS:-}"
DOCKER_DIRS=()
shopt -s nullglob
for dir in "$BASE_DIR"/*/; do
    dir=${dir%/}
    skip=false
    for ex in "${EXCLUDED[@]}"; do
        if [ "${dir##*/}" = "$ex" ]; then skip=true; break; fi
    done
    if [ "$skip" = true ]; then continue; fi
    for cf in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [ -f "$dir/$cf" ]; then DOCKER_DIRS+=("$dir"); break; fi
    done
done

for DIR in "${DOCKER_DIRS[@]}"; do
    log_msg "Processing: $DIR"
    if ! pushd "$DIR" >/dev/null; then fail "$DIR" 'Cannot enter stack directory'; continue; fi
    # Let Compose resolve its canonical filename and automatic override files.
    if [ "$AUTOSTART" = true ]; then
        if EXITED=$("$DOCKER_BIN" compose ps --all --orphans=false --status exited --format '{{.Name}}' 2>>"$LOG_FILE"); then
            RETRY_LIST=()
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                if ! DETAILS=$("$DOCKER_BIN" inspect --format '{{.HostConfig.RestartPolicy.Name}}|{{index .Config.Labels "container-updater.autostart"}}' "$name" 2>>"$LOG_FILE"); then
                    fail "$name" 'Cannot inspect autostart eligibility'; continue
                fi
                # Restart policy alone cannot distinguish an intentional stop.
                if [[ $DETAILS != 'always|true' && $DETAILS != 'unless-stopped|true' ]]; then continue; fi
                if [ "$DRY_RUN" = true ]; then
                    log_msg "[DRY RUN] Would start: $name"
                elif ! "$DOCKER_BIN" start "$name" >> "$LOG_FILE" 2>&1; then
                    RETRY_LIST+=("$name")
                fi
            done <<< "$EXITED"
            if (( ${#RETRY_LIST[@]} > 0 )); then
                sleep "$AUTOSTART_RETRY_DELAY"
                for name in "${RETRY_LIST[@]}"; do
                    if ! "$DOCKER_BIN" start "$name" >> "$LOG_FILE" 2>&1; then fail "$name" 'Container failed to autostart'; fi
                done
            fi
        else
            fail "$DIR" 'Cannot list exited containers'
        fi
    fi

    RUNNING_SERVICES=()
    STATUS_OK=true
    # Query separately for compatibility across Compose versions; stderr is not a service.
    for status in running restarting; do
        if PS_OUTPUT=$("$DOCKER_BIN" compose ps --all --orphans=false --services --status "$status" 2>>"$LOG_FILE"); then
            while IFS= read -r service; do
                [ -z "$service" ] && continue
                found=false
                for existing in "${RUNNING_SERVICES[@]}"; do
                    if [ "$existing" = "$service" ]; then found=true; break; fi
                done
                if [ "$found" = false ]; then RUNNING_SERVICES+=("$service"); fi
            done <<< "$PS_OUTPUT"
        else
            fail "$DIR" "Failed to check $status service status"
            STATUS_OK=false
            break
        fi
    done
    if [ "$STATUS_OK" = false ]; then popd >/dev/null; continue; fi
    if (( ${#RUNNING_SERVICES[@]} == 0 )); then
        log_msg 'No active services; skipping update.'
        popd >/dev/null
        continue
    fi
    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY RUN] In $DIR: compose pull ${RUNNING_SERVICES[*]}"
        log_msg "[DRY RUN] In $DIR: compose up -d --no-deps --wait --wait-timeout $WAIT_TIMEOUT ${RUNNING_SERVICES[*]}"
        popd >/dev/null
        continue
    fi
    PULL_SUCCESS=false
    for (( attempt=1; attempt<=PULL_RETRIES; attempt++ )); do
        if "$DOCKER_BIN" compose pull "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
            PULL_SUCCESS=true
            break
        elif (( attempt < PULL_RETRIES )); then
            log_msg "Pull attempt $attempt/$PULL_RETRIES failed; retrying in ${PULL_RETRY_DELAY}s"
            sleep "$PULL_RETRY_DELAY"
        fi
    done
    if [ "$PULL_SUCCESS" = false ]; then
        fail "$DIR" "Failed to pull images after $PULL_RETRIES attempts"
    elif ! "$DOCKER_BIN" compose up -d --no-deps --wait --wait-timeout "$WAIT_TIMEOUT" "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
        fail "$DIR" 'Containers failed to start or become healthy'
    else
        log_msg "Successfully updated $DIR"
    fi
    popd >/dev/null
done
if (( ${#DOCKER_DIRS[@]} == 0 )); then log_msg "No Compose directories found in $BASE_DIR"; fi
if [ "$PRUNE_IMAGES" = true ] && (( ${#DOCKER_DIRS[@]} > 0 && FAILURES == 0 )); then
    if [ "$DRY_RUN" = true ]; then
        log_msg '[DRY RUN] Would run: docker image prune -f'
    elif ! "$DOCKER_BIN" image prune -f >> "$LOG_FILE" 2>&1; then
        fail Docker 'Image pruning failed'
    fi
fi
log_msg "Global Update finished: $FAILURES failure(s)"
if (( FAILURES > 0 )); then exit 1; fi
exit 0
