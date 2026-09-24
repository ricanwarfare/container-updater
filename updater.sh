#!/bin/bash
set -euo pipefail

VERSION="1.0.0"

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SCRIPT_PATH="$(cd -P "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
# Explicit caller settings take precedence over the trusted shell config file.
CONFIG_KEYS=(BASE_DIR LOG_FILE DRY_RUN PRUNE_IMAGES LOCK_FILE VERBOSE AUTOSTART
    AUTOSTART_RETRY_DELAY PULL_RETRIES PULL_RETRY_DELAY LOG_MAX_SIZE_KB
    EXCLUDE_DIRS DOCKER_BIN NOTIFY_FAILURE_WEBHOOK WAIT_TIMEOUT
    COMPOSE_WAIT_TIMEOUT RUN_HOOKS NOTIFY_SUCCESS_WEBHOOK
    STACK_TIMEOUT LOCK_STALE_SECONDS
    SELF_UPDATE GITHUB_REPO)
declare -A CALLER_CONFIG=()
for key in "${CONFIG_KEYS[@]}"; do
    if [[ -v $key ]]; then CALLER_CONFIG[$key]="${!key}"; fi
done
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1090
    source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
fi
for key in "${!CALLER_CONFIG[@]}"; do printf -v "$key" '%s' "${CALLER_CONFIG[$key]}"; done

version_gt() {
    local v1="${1#v}" v2="${2#v}"
    if [[ "$v1" == "$v2" ]]; then return 1; fi
    local arr1=() arr2=() i
    IFS=. read -r -a arr1 <<< "$v1"
    IFS=. read -r -a arr2 <<< "$v2"
    for ((i=0; i<${#arr1[@]} || i<${#arr2[@]}; i++)); do
        local n1=${arr1[i]:-0}
        local n2=${arr2[i]:-0}
        n1=${n1%%[^0-9]*}
        n2=${n2%%[^0-9]*}
        n1=${n1:-0}
        n2=${n2:-0}
        if (( 10#$n1 > 10#$n2 )); then return 0; fi
        if (( 10#$n1 < 10#$n2 )); then return 1; fi
    done
    return 1
}

fetch_release_info() {
    local repo="$1"
    REMOTE_TAG=""
    ASSET_URL=""
    RAW_URL=""

    local curl_cmd=(curl -sSL --connect-timeout 10 --max-time 30)
    local headers=(-H "Accept: application/vnd.github.v3+json" -H "User-Agent: container-updater")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: token $GITHUB_TOKEN")
    fi

    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local release_json
    release_json=$("${curl_cmd[@]}" "${headers[@]}" "$api_url" 2>/dev/null || true)

    if [[ $release_json =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        REMOTE_TAG="${BASH_REMATCH[1]}"
        if [[ $release_json =~ \"browser_download_url\"[[:space:]]*:[[:space:]]*\"([^\"]*/releases/download/[^\"]*/updater\.sh)\" ]] || \
           [[ $release_json =~ \"browser_download_url\"[[:space:]]*:[[:space:]]*\"([^\"]*/updater\.sh)\" ]]; then
            ASSET_URL="${BASH_REMATCH[1]}"
        fi
    fi

    if [ -z "$REMOTE_TAG" ]; then
        local redirect_url
        redirect_url=$(curl -sIL -o /dev/null -w "%{url_effective}" "https://github.com/${repo}/releases/latest" 2>/dev/null || true)
        if [[ $redirect_url == */releases/tag/* ]]; then
            REMOTE_TAG="${redirect_url##*/}"
        fi
    fi

    if [ -z "$REMOTE_TAG" ]; then
        return 1
    fi

    if [ -z "$ASSET_URL" ]; then
        ASSET_URL="https://github.com/${repo}/releases/download/${REMOTE_TAG}/updater.sh"
    fi
    RAW_URL="https://raw.githubusercontent.com/${repo}/${REMOTE_TAG}/updater.sh"
    return 0
}

download_and_verify_update() {
    local repo="$1" tag="$2" asset_url="$3" raw_url="$4" target="$5"
    local target_dir
    target_dir="$(dirname "$target")"
    if [ ! -w "$target_dir" ] || { [ -e "$target" ] && [ ! -w "$target" ]; }; then
        echo "Target location '$target' is not writable" >&2
        return 1
    fi

    local tmp_file="${target}.tmp.$$"
    rm -f "$tmp_file"

    local downloaded=false
    if [ -n "$asset_url" ]; then
        if curl -sSL --fail --connect-timeout 10 --max-time 60 "$asset_url" -o "$tmp_file" 2>/dev/null; then
            downloaded=true
        fi
    fi
    if [ "$downloaded" = false ] && [ -n "$raw_url" ]; then
        if curl -sSL --fail --connect-timeout 10 --max-time 60 "$raw_url" -o "$tmp_file" 2>/dev/null; then
            downloaded=true
        fi
    fi

    if [ "$downloaded" = false ] || [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        echo "Failed to download update from $asset_url or $raw_url" >&2
        return 1
    fi

    local first_line
    first_line=$(head -n 1 "$tmp_file" 2>/dev/null || true)
    if [[ ! $first_line =~ ^#!.*bash ]]; then
        rm -f "$tmp_file"
        echo "Downloaded file is invalid: missing bash shebang" >&2
        return 1
    fi

    if ! bash -n "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        echo "Downloaded file contains syntax errors" >&2
        return 1
    fi

    chmod --reference="$target" "$tmp_file" 2>/dev/null || chmod 755 "$tmp_file"
    chmod +x "$tmp_file"
    if ! mv -f "$tmp_file" "$target"; then
        rm -f "$tmp_file"
        echo "Failed to replace $target" >&2
        return 1
    fi
    return 0
}

perform_self_update_standalone() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "[FATAL] curl is required for self-update" >&2
        return 1
    fi
    local lock="${LOCK_FILE:-}"
    if [ -z "$lock" ]; then
        if [ -n "${BASE_DIR:-}" ] && [ -d "$BASE_DIR" ]; then
            lock="$BASE_DIR/container-updater/updater.lock"
        else
            lock="$SCRIPT_DIR/.updater.lock"
        fi
    fi
    mkdir -p "$(dirname "$lock")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1 && [ -w "$(dirname "$lock")" ]; then
        exec 9>>"$lock"
        if ! flock -n 9; then
            echo "[FATAL] Another updater instance is already running" >&2
            return 1
        fi
    fi

    local repo="${GITHUB_REPO:-ricanwarfare/container-updater}"
    echo "Checking for releases on GitHub: $repo..."
    local REMOTE_TAG="" ASSET_URL="" RAW_URL=""
    if ! fetch_release_info "$repo"; then
        echo "[ERROR] Could not find any release on GitHub for $repo" >&2
        return 1
    fi
    echo "Latest release: $REMOTE_TAG (current: $VERSION)"
    if ! version_gt "$REMOTE_TAG" "$VERSION"; then
        echo "Already up to date (version $VERSION)."
        return 0
    fi
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "[DRY RUN] Newer version $REMOTE_TAG is available. Would update $SCRIPT_PATH"
        return 0
    fi
    echo "Downloading and applying update to $SCRIPT_PATH..."
    local err_msg
    if err_msg=$(download_and_verify_update "$repo" "$REMOTE_TAG" "$ASSET_URL" "$RAW_URL" "$SCRIPT_PATH" 2>&1); then
        echo "Successfully updated container-updater to $REMOTE_TAG (was $VERSION)."
        return 0
    else
        echo "[ERROR] Update failed: $err_msg" >&2
        return 1
    fi
}

perform_self_update_scheduled() {
    if ! command -v curl >/dev/null 2>&1; then
        log_msg "[WARNING] curl is required for self-update; skipping self-update check"
        return 1
    fi
    local repo="${GITHUB_REPO:-ricanwarfare/container-updater}"
    log_msg "Checking for updates from GitHub: $repo"
    local REMOTE_TAG="" ASSET_URL="" RAW_URL=""
    if ! fetch_release_info "$repo"; then
        log_msg "[WARNING] Self-update check failed: could not fetch release info for $repo"
        return 1
    fi
    if ! version_gt "$REMOTE_TAG" "$VERSION"; then
        log_msg "Self-update: already up to date (version $VERSION)"
        return 1
    fi
    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY RUN] Self-update: newer version $REMOTE_TAG is available (current: $VERSION). Would update $SCRIPT_PATH"
        return 1
    fi
    log_msg "Downloading and applying update to $SCRIPT_PATH ($REMOTE_TAG)..."
    local err_msg
    if err_msg=$(download_and_verify_update "$repo" "$REMOTE_TAG" "$ASSET_URL" "$RAW_URL" "$SCRIPT_PATH" 2>&1); then
        log_msg "Self-update: successfully updated to $REMOTE_TAG (was $VERSION)"
        return 0
    else
        log_msg "[WARNING] Self-update failed: $err_msg; continuing with current version ($VERSION)"
        return 1
    fi
}

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
      --stack-timeout SEC   Hard cap on one stack's Docker calls (0 disables, default 1800)
      --no-hooks            Disable pre/post-update shell hooks
  -u, --self-update          Update this script to latest GitHub release and exit
      --auto-update         Enable self-update check before stack updates
      --no-auto-update      Disable self-update check before stack updates
      --version             Show script version and exit
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
        --version) echo "container-updater $VERSION"; exit 0 ;;
        -u|--self-update) DO_SELF_UPDATE=true; shift ;;
        --auto-update) SELF_UPDATE=true; shift ;;
        --no-auto-update) SELF_UPDATE=false; shift ;;
        -h|--help) show_help; exit 0 ;;
        -e|--exclude)
            if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
                echo "[FATAL] $1 requires an argument" >&2; exit 1
            fi
            EXCLUDE_DIRS=$2
            shift 2 ;;
        -b|--base-dir|--wait-timeout|--stack-timeout)
            if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
                echo "[FATAL] $1 requires an argument" >&2; exit 1
            fi
            case "$1" in
                -b|--base-dir) BASE_DIR=$2 ;;
                --wait-timeout) WAIT_TIMEOUT=$2 ;;
                --stack-timeout) STACK_TIMEOUT=$2 ;;
            esac
            shift 2 ;;
        *) echo "[FATAL] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [ "$WAIT_TIMEOUT" = 0 ]; then WAIT_TIMEOUT=300; fi
RUN_HOOKS="${RUN_HOOKS:-true}"

if [ "${DO_SELF_UPDATE:-false}" = true ]; then
    perform_self_update_standalone
    exit $?
fi

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
STACK_TIMEOUT="${STACK_TIMEOUT:-1800}"
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-0}"
SELF_UPDATE="${SELF_UPDATE:-false}"
GITHUB_REPO="${GITHUB_REPO:-ricanwarfare/container-updater}"
for key in DRY_RUN PRUNE_IMAGES VERBOSE AUTOSTART RUN_HOOKS SELF_UPDATE; do
    if [[ ${!key} != true && ${!key} != false ]]; then
        echo "[FATAL] $key must be true or false" >&2
        exit 1
    fi
done
for key in AUTOSTART_RETRY_DELAY PULL_RETRIES PULL_RETRY_DELAY LOG_MAX_SIZE_KB WAIT_TIMEOUT \
    STACK_TIMEOUT LOCK_STALE_SECONDS; do
    if [[ ! ${!key} =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        echo "[FATAL] $key must be a nonnegative integer (at most 9 digits)" >&2
        exit 1
    fi
done
if (( PULL_RETRIES == 0 || WAIT_TIMEOUT == 0 )); then
    echo "[FATAL] PULL_RETRIES and WAIT_TIMEOUT must be positive" >&2
    exit 1
fi
# Expand PATH with common candidate directories if missing (critical for Synology DSM Task Scheduler)
for extra_path in /usr/local/bin /usr/syno/bin /var/packages/ContainerManager/target/usr/bin /var/packages/Docker/target/usr/bin /snap/bin; do
    if [ -d "$extra_path" ] && [[ ":$PATH:" != *":$extra_path:"* ]]; then
        PATH="$PATH:$extra_path"
    fi
done

if [ -n "${DOCKER_BIN:-}" ]; then
    if [ -x "$DOCKER_BIN" ]; then
        :
    elif resolved=$(command -v "$DOCKER_BIN" 2>/dev/null); then
        DOCKER_BIN="$resolved"
    else
        echo "[FATAL] Docker executable not found" >&2
        exit 1
    fi
else
    if resolved=$(command -v docker 2>/dev/null); then
        DOCKER_BIN="$resolved"
    else
        DOCKER_CANDIDATES=(
            /usr/local/bin/docker
            /var/packages/ContainerManager/target/usr/bin/docker
            /var/packages/Docker/target/usr/bin/docker
            /usr/syno/bin/docker
            /snap/bin/docker
            /usr/bin/docker
            /bin/docker
        )
        for candidate in "${DOCKER_CANDIDATES[@]}"; do
            if [ -x "$candidate" ]; then
                DOCKER_BIN="$candidate"
                break
            fi
        done
    fi
fi
if [ -z "${DOCKER_BIN:-}" ] || [ ! -x "$DOCKER_BIN" ]; then
    echo "[FATAL] Docker executable not found" >&2
    exit 1
fi
if [[ $DOCKER_BIN != /* ]]; then DOCKER_BIN="$PWD/$DOCKER_BIN"; fi
DOCKER_DIR="$(dirname "$DOCKER_BIN")"
if [[ ":$PATH:" != *":$DOCKER_DIR:"* ]]; then
    PATH="$PATH:$DOCKER_DIR"
fi
command -v flock >/dev/null || { echo "[FATAL] flock is required" >&2; exit 1; }
if (( STACK_TIMEOUT > 0 )); then
    command -v timeout >/dev/null || { echo "[FATAL] timeout is required when STACK_TIMEOUT is set" >&2; exit 1; }
fi
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
    if (( LOCK_STALE_SECONDS > 0 )); then
        # A wedged run holds this lock indefinitely and every scheduled tick then
        # no-ops, so a stack can stay down for days. Report the age loudly enough
        # that the skipped-run log line is diagnosable instead of silent.
        LOCK_MTIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
        if (( LOCK_MTIME > 0 )); then
            LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
            if (( LOCK_AGE >= LOCK_STALE_SECONDS )); then
                STALE_MSG="[ERROR] Lock held for ${LOCK_AGE}s (>= LOCK_STALE_SECONDS=${LOCK_STALE_SECONDS}); the previous run is likely wedged on a Docker call and is blocking all updates. Check 'ps -eo pid,etime,args | grep updater.sh' and ${LOG_FILE}."
                printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STALE_MSG" >> "$LOG_FILE"
                echo "$STALE_MSG" >&2
            fi
        fi
    fi
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
# Bound a Docker/recreate call so one wedged socket call cannot strand this run
# (and its lock) for days. Exit 124 from timeout means the cap was hit.
LAST_BOUNDED_RC=0
bounded() {
    if (( STACK_TIMEOUT > 0 )); then
        timeout --kill-after=30 --signal=TERM "$STACK_TIMEOUT" "$@"
        LAST_BOUNDED_RC=$?
        return "$LAST_BOUNDED_RC"
    else
        "$@"
        LAST_BOUNDED_RC=$?
        return "$LAST_BOUNDED_RC"
    fi
}
timeout_hint() {
    # Only claim a timeout when the preceding bounded call ACTUALLY timed out.
    # timeout(1) returns 124 when it kills the child, 137 when --kill-after fires.
    # Without this guard every ordinary failure (bad tag, 429, network) was
    # mislabelled "the Docker call likely hung", which is actively misleading in
    # the failure webhook alert.
    if (( STACK_TIMEOUT > 0 )) && (( LAST_BOUNDED_RC == 124 || LAST_BOUNDED_RC == 137 )); then
        printf ' (hit STACK_TIMEOUT=%ss; the Docker call likely hung)' "$STACK_TIMEOUT"
    fi
}
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
if [ "${_UPDATER_ALREADY_UPDATED:-0}" = "1" ]; then
    log_msg "Resumed execution after self-update to $VERSION"
elif [ "$SELF_UPDATE" = true ]; then
    if perform_self_update_scheduled; then
        log_msg "Restarting updater with new version..."
        exec 9>&-
        _UPDATER_ALREADY_UPDATED=1 exec "${BASH:-bash}" "$SCRIPT_PATH" "$@"
    fi
fi
if [ "$DRY_RUN" = true ]; then
    log_msg '[DRY RUN] Inspection started; no updates or notifications will be applied'
else
    log_msg 'Global Update started'
fi
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
        if EXITED=$(bounded "$DOCKER_BIN" compose ps --all --status exited --format '{{.Name}}' 2>>"$LOG_FILE"); then
            RETRY_LIST=()
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                if ! DETAILS=$(bounded "$DOCKER_BIN" inspect --format '{{.HostConfig.RestartPolicy.Name}}|{{index .Config.Labels "container-updater.autostart"}}' "$name" 2>>"$LOG_FILE"); then
                    fail "$name" 'Cannot inspect autostart eligibility'; continue
                fi
                # Restart policy alone cannot distinguish an intentional stop.
                if [[ $DETAILS != 'always|true' && $DETAILS != 'unless-stopped|true' ]]; then continue; fi
                if [ "$DRY_RUN" = true ]; then
                    log_msg "[DRY RUN] Would start: $name"
                elif ! bounded "$DOCKER_BIN" start "$name" >> "$LOG_FILE" 2>&1; then
                    RETRY_LIST+=("$name")
                fi
            done <<< "$EXITED"
            if (( ${#RETRY_LIST[@]} > 0 )); then
                sleep "$AUTOSTART_RETRY_DELAY"
                for name in "${RETRY_LIST[@]}"; do
                    if ! bounded "$DOCKER_BIN" start "$name" >> "$LOG_FILE" 2>&1; then fail "$name" 'Container failed to autostart'; fi
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
        if PS_OUTPUT=$(bounded "$DOCKER_BIN" compose ps --all --services --status "$status" 2>"$PS_ERR_FILE"); then
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
        if bounded "$DOCKER_BIN" compose pull --ignore-buildable "${RUNNING_SERVICES[@]}" >> "$LOG_FILE" 2>&1; then
            PULL_SUCCESS=true
            break
        elif (( attempt < PULL_RETRIES )); then
            log_msg "Pull attempt $attempt/$PULL_RETRIES failed; retrying in ${PULL_RETRY_DELAY}s"
            sleep "$PULL_RETRY_DELAY"
        fi
    done
    if [ "$PULL_SUCCESS" = false ]; then
        fail "$DIR" "Failed to pull images after $PULL_RETRIES attempts$(timeout_hint)"
    else
        log_msg "Recreating containers with health wait: ${RUNNING_SERVICES[*]}"
        UP_ERR_FILE=$(mktemp)
        if ! bounded "$DOCKER_BIN" compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" "${RUNNING_SERVICES[@]}" >"$UP_ERR_FILE" 2>&1; then
            UP_ERR=$(tr '\r\n' ' ' < "$UP_ERR_FILE" 2>/dev/null || true)
            cat "$UP_ERR_FILE" >> "$LOG_FILE"
            rm -f "$UP_ERR_FILE"
            fail "$DIR" "Containers failed to start or become healthy${UP_ERR:+: $UP_ERR}$(timeout_hint)"
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
if [ "$DRY_RUN" = true ]; then
    log_msg "[DRY RUN] Inspection summary: ${#DOCKER_DIRS[@]} stacks, $PLANNED_COUNT planned, $SKIPPED_COUNT skipped, $FAILURES failure(s), ${DURATION}s"
    log_msg "[DRY RUN] Inspection finished: no updates, image pruning, hooks, or webhooks were applied; $FAILURES failure(s)"
else
    log_msg "Summary: ${#DOCKER_DIRS[@]} stacks, $UPDATED_COUNT updated, $SKIPPED_COUNT skipped, $PLANNED_COUNT planned, $FAILURES failure(s), ${DURATION}s"
    log_msg "Global Update finished: $FAILURES failure(s)"
fi
if (( FAILURES > 0 )); then exit 1; fi
if [ -n "${NOTIFY_SUCCESS_WEBHOOK:-}" ] && [ "$DRY_RUN" = false ]; then
    MESSAGE=$(json_string "Docker Updater Finished: $UPDATED_COUNT/${#DOCKER_DIRS[@]} updated, $SKIPPED_COUNT skipped (${DURATION}s)")
    PAYLOAD="{\"text\":$MESSAGE,\"content\":$MESSAGE,\"status\":\"success\",\"updated\":$UPDATED_COUNT,\"skipped\":$SKIPPED_COUNT,\"total\":${#DOCKER_DIRS[@]},\"duration\":$DURATION,\"host\":$(json_string "$(hostname)")}"
    send_webhook "$NOTIFY_SUCCESS_WEBHOOK" "$PAYLOAD"
fi
exit 0
