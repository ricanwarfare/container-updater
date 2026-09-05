#!/bin/bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# Explicit caller settings take precedence over the trusted shell config file.
CONFIG_KEYS=(BASE_DIR LOG_FILE DRY_RUN PRUNE_IMAGES LOCK_FILE VERBOSE AUTOSTART
    AUTOSTART_RETRY_DELAY PULL_RETRIES PULL_RETRY_DELAY LOG_MAX_SIZE_KB
    EXCLUDE_DIRS DOCKER_BIN NOTIFY_FAILURE_WEBHOOK WAIT_TIMEOUT
    COMPOSE_WAIT_TIMEOUT RUN_HOOKS NOTIFY_SUCCESS_WEBHOOK)
declare -A CALLER_CONFIG=()
for key in "${CONFIG_KEYS[@]}"; do
    if [[ -v $key ]]; then CALLER_CONFIG[$key]="${!key}"; fi
done
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1090
    source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
fi
for key in "${!CALLER_CONFIG[@]}"; do printf -v "$key" '%s' "${CALLER_CONFIG[$key]}"; done

show_help() {
    cat <<'HELP'
Usage: updater.sh [OPTIONS]
  -d, --dry-run              Inspect and log without mutations
  -v, --verbose              Print logs to stdout (default: enabled)
  -q, --quiet, --no-verbose  Suppress logs to stdout (log file only)
  -b, --base-dir DIR         Parent directory of Compose stacks
  -e, --exclude DIRS         Colon-separated directory names to skip
  -p, --prune                Enable dangling image pruning
      --no-prune            Disable image pruning
      --no-autostart        Disable labelled container recovery
      --wait-timeout SEC    Health wait timeout (0 uses 300 seconds)
      --no-hooks            Disable pre/post-update shell hooks
  -h, --help                 Show this help
HELP
}
# Retain the remote configuration name as an alias. Zero selects the bounded default.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-${COMPOSE_WAIT_TIMEOUT:-300}}"
while (( $# > 0 )); do
    case "$1" in
        -d|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -q|--quiet|--no-verbose) VERBOSE=false; shift ;;
        -p|--prune) PRUNE_IMAGES=true; shift ;;
        --no-prune) PRUNE_IMAGES=false; shift ;;
        --no-autostart) AUTOSTART=false; shift ;;
        --no-hooks) RUN_HOOKS=false; shift ;;
        -h|--help) show_help; exit 0 ;;
        -e|--exclude)
            if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
                echo "[FATAL] $1 requires an argument" >&2; exit 1
            fi
            EXCLUDE_DIRS=$2
            shift 2 ;;
        -b|--base-dir|--wait-timeout)
            if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
                echo "[FATAL] $1 requires an argument" >&2; exit 1
            fi
            if [ "$1" = --wait-timeout ]; then WAIT_TIMEOUT=$2; else BASE_DIR=$2; fi
            shift 2 ;;
        *) echo "[FATAL] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [ "$WAIT_TIMEOUT" = 0 ]; then WAIT_TIMEOUT=300; fi
RUN_HOOKS="${RUN_HOOKS:-true}"

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
VERBOSE="${VERBOSE:-true}"
AUTOSTART="${AUTOSTART:-false}"
AUTOSTART_RETRY_DELAY="${AUTOSTART_RETRY_DELAY:-10}"
PULL_RETRIES="${PULL_RETRIES:-3}"
PULL_RETRY_DELAY="${PULL_RETRY_DELAY:-5}"
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
for key in DRY_RUN PRUNE_IMAGES VERBOSE AUTOSTART RUN_HOOKS; do
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
if [ -n "${NOTIFY_FAILURE_WEBHOOK:-}${NOTIFY_SUCCESS_WEBHOOK:-}" ]; then
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
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
            "\\") printf '%s' "\\\\" ;;
            *) printf -v code '%d' "'$char"
               if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$char"; fi ;;
        esac
    done
    printf '"'
}
send_webhook() {
    local endpoint="$1" payload="$2"
    if [ "$DRY_RUN" = false ] && [ -n "$endpoint" ]; then
        if ! curl --silent --show-error --fail --connect-timeout 10 --max-time 30 \
            -H 'Content-Type: application/json' --data "$payload" \
            "$endpoint" >> "$LOG_FILE" 2>&1; then
            log_msg '[WARNING] Webhook delivery failed'
        fi
    fi
}
run_hook() {
    local hook="$1"
    if [ "$RUN_HOOKS" = true ] && [ -f "$hook" ]; then
        if [ "$DRY_RUN" = true ]; then
            log_msg "[DRY RUN] Would execute hook: $hook"
        else
            export STACK_NAME="${DIR##*/}"
            export STACK_DIR="$DIR"
            export ACTIVE_SERVICES="${RUNNING_SERVICES[*]:-}"
            local hook_failed=false
            if [ -x "$hook" ]; then
                "$hook" >> "$LOG_FILE" 2>&1 || hook_failed=true
            else
                bash "$hook" >> "$LOG_FILE" 2>&1 || hook_failed=true
            fi
            if [ "$hook_failed" = true ]; then
                fail "$DIR" "$hook failed"
                return 1
            fi
        fi
    fi
}
START_TIME=$SECONDS
UPDATED_COUNT=0
SKIPPED_COUNT=0
PLANNED_COUNT=0
FAILURES=0
fail() {
    local service="$1" error="$2" payload message
    FAILURES=$((FAILURES + 1))
    log_msg "[ERROR] $service: $error"
    if [ -n "${NOTIFY_FAILURE_WEBHOOK:-}" ] && [ "$DRY_RUN" = false ]; then
        message=$(json_string "Docker Updater Failure: $service - $error")
        payload="{\"text\":$message,\"content\":$message,\"service\":$(json_string "$service"),\"error\":$(json_string "$error"),\"host\":$(json_string "$(hostname)")}"
        send_webhook "$NOTIFY_FAILURE_WEBHOOK" "$payload"
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
    if [ -f "$dir/.updaterignore" ]; then continue; fi
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
        if EXITED=$("$DOCKER_BIN" compose ps --all --status exited --format '{{.Name}}' 2>>"$LOG_FILE"); then
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
        PS_ERR_FILE=$(mktemp)
        if PS_OUTPUT=$("$DOCKER_BIN" compose ps --all --services --status "$status" 2>"$PS_ERR_FILE"); then
            cat "$PS_ERR_FILE" >> "$LOG_FILE"
            rm -f "$PS_ERR_FILE"
            while IFS= read -r service; do
                [ -z "$service" ] && continue
                found=false
                for existing in "${RUNNING_SERVICES[@]}"; do
                    if [ "$existing" = "$service" ]; then found=true; break; fi
                done
                if [ "$found" = false ]; then RUNNING_SERVICES+=("$service"); fi
            done <<< "$PS_OUTPUT"
        else
            PS_ERR=$(tr '\r\n' ' ' < "$PS_ERR_FILE" 2>/dev/null || true)
            rm -f "$PS_ERR_FILE"
            [ -n "$PS_ERR" ] && printf '%s\n' "$PS_ERR" >> "$LOG_FILE"
            fail "$DIR" "Failed to check $status service status${PS_ERR:+: $PS_ERR}"
            STATUS_OK=false
            break
        fi
    done
    if [ "$STATUS_OK" = false ]; then popd >/dev/null; continue; fi
    if (( ${#RUNNING_SERVICES[@]} == 0 )); then
        log_msg 'No active services; skipping update.'
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        popd >/dev/null
        continue
    fi
    if ! run_hook ./pre-update.sh; then popd >/dev/null; continue; fi
    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY RUN] In $DIR: compose pull --ignore-buildable ${RUNNING_SERVICES[*]}"
        log_msg "[DRY RUN] In $DIR: compose up -d --wait --wait-timeout $WAIT_TIMEOUT ${RUNNING_SERVICES[*]}"
        run_hook ./post-update.sh
        PLANNED_COUNT=$((PLANNED_COUNT + 1))
        popd >/dev/null
        continue
    fi
    log_msg "Pulling images for: ${RUNNING_SERVICES[*]}"
    PULL_SUCCESS=false
    for (( attempt=1; attempt<=PULL_RETRIES; attempt++ )); do
        if "$DOCKER_BIN" compose pull --ignore-buildable "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
            PULL_SUCCESS=true
            break
        elif (( attempt < PULL_RETRIES )); then
            log_msg "Pull attempt $attempt/$PULL_RETRIES failed; retrying in ${PULL_RETRY_DELAY}s"
            sleep "$PULL_RETRY_DELAY"
        fi
    done
    if [ "$PULL_SUCCESS" = false ]; then
        fail "$DIR" "Failed to pull images after $PULL_RETRIES attempts"
    else
        log_msg "Recreating containers with health wait: ${RUNNING_SERVICES[*]}"
        UP_ERR_FILE=$(mktemp)
        if ! "$DOCKER_BIN" compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" "${RUNNING_SERVICES[@]}" >"$UP_ERR_FILE" 2>&1; then
            UP_ERR=$(tr '\r\n' ' ' < "$UP_ERR_FILE" 2>/dev/null || true)
            cat "$UP_ERR_FILE" >> "$LOG_FILE"
            rm -f "$UP_ERR_FILE"
            fail "$DIR" "Containers failed to start or become healthy${UP_ERR:+: $UP_ERR}"
        else
            cat "$UP_ERR_FILE" >> "$LOG_FILE"
            rm -f "$UP_ERR_FILE"
            if run_hook ./post-update.sh; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
                log_msg "Successfully updated $DIR"
            fi
        fi
    fi
    popd >/dev/null
done
if (( ${#DOCKER_DIRS[@]} == 0 )); then log_msg "No Compose directories found in $BASE_DIR"; fi
if [ "$PRUNE_IMAGES" = true ] && (( ${#DOCKER_DIRS[@]} > 0 && FAILURES == 0 )); then
    if [ "$DRY_RUN" = true ]; then
        log_msg '[DRY RUN] Would run: docker image prune -f'
    else
        log_msg 'Pruning dangling images...'
        if ! "$DOCKER_BIN" image prune -f >> "$LOG_FILE" 2>&1; then
            fail Docker 'Image pruning failed'
        fi
    fi
fi
DURATION=$((SECONDS - START_TIME))
log_msg "Summary: ${#DOCKER_DIRS[@]} stacks, $UPDATED_COUNT updated, $SKIPPED_COUNT skipped, $PLANNED_COUNT planned, $FAILURES failure(s), ${DURATION}s"
log_msg "Global Update finished: $FAILURES failure(s)"
if (( FAILURES > 0 )); then exit 1; fi
if [ -n "${NOTIFY_SUCCESS_WEBHOOK:-}" ] && [ "$DRY_RUN" = false ]; then
    MESSAGE=$(json_string "Docker Updater Finished: $UPDATED_COUNT/${#DOCKER_DIRS[@]} updated, $SKIPPED_COUNT skipped (${DURATION}s)")
    PAYLOAD="{\"text\":$MESSAGE,\"content\":$MESSAGE,\"status\":\"success\",\"updated\":$UPDATED_COUNT,\"skipped\":$SKIPPED_COUNT,\"total\":${#DOCKER_DIRS[@]},\"duration\":$DURATION,\"host\":$(json_string "$(hostname)")}"
    send_webhook "$NOTIFY_SUCCESS_WEBHOOK" "$PAYLOAD"
fi
exit 0
