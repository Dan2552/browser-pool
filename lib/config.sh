#!/usr/bin/env bash
# Configuration defaults — all overridable via environment variables.

BROWSER_POOL_IMAGE="${BROWSER_POOL_IMAGE:-browser-pool:latest}"
BROWSER_POOL_MAX_CONTAINERS="${BROWSER_POOL_MAX_CONTAINERS:-5}"
BROWSER_POOL_PORT_RANGE_START="${BROWSER_POOL_PORT_RANGE_START:-20000}"
BROWSER_POOL_PORT_RANGE_END="${BROWSER_POOL_PORT_RANGE_END:-40000}"
BROWSER_POOL_IDLE_TTL="${BROWSER_POOL_IDLE_TTL:-300}"
BROWSER_POOL_IDLE_TTL_EXCESS="${BROWSER_POOL_IDLE_TTL_EXCESS:-120}"
BROWSER_POOL_LEASE_TTL="${BROWSER_POOL_LEASE_TTL:-3600}"
BROWSER_POOL_ACQUIRE_TIMEOUT="${BROWSER_POOL_ACQUIRE_TIMEOUT:-300}"
BROWSER_POOL_STATE_DIR="${BROWSER_POOL_STATE_DIR:-$HOME/.browser-pool}"
BROWSER_POOL_SHM_SIZE="${BROWSER_POOL_SHM_SIZE:-1gb}"
BROWSER_POOL_LABEL_PREFIX="${BROWSER_POOL_LABEL_PREFIX:-browser-pool}"
BROWSER_POOL_HEALTH_TIMEOUT="${BROWSER_POOL_HEALTH_TIMEOUT:-30}"

# Ensure state directories exist
mkdir -p "${BROWSER_POOL_STATE_DIR}/leases" "${BROWSER_POOL_STATE_DIR}/queue"

# Lock file for atomic operations
BROWSER_POOL_LOCK_FILE="${BROWSER_POOL_STATE_DIR}/pool.lock"

BROWSER_POOL_QUIET="${BROWSER_POOL_QUIET:-0}"

bp_log() {
  [[ "$BROWSER_POOL_QUIET" == "1" ]] && return 0
  printf '[browser-pool] %s\n' "$*" >&2
}

bp_log_error() {
  printf '[browser-pool] %s\n' "$*" >&2
}

PROFILE_BROWSER_POOL="${PROFILE_BROWSER_POOL:-0}"

# fd 3 is used for profile output so it survives 2>&1 redirections.
# If fd 3 isn't open yet, point it at stderr.
if ! { true >&3; } 2>/dev/null; then
  exec 3>&2
fi

_bp_profile_ms() {
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null
}

bp_profile() {
  [[ "$PROFILE_BROWSER_POOL" == "1" ]] || return 0
  local label="$1"
  local start_ms="$2"
  local end_ms
  end_ms="$(_bp_profile_ms)"
  local elapsed=$(( end_ms - start_ms ))
  printf '[browser-pool:profile] %-35s %4s ms\n' "$label" "$elapsed" >&3
}

bp_now() {
  date +%s
}

bp_uuid() {
  if command -v uuidgen > /dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    # fallback: random hex
    od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4$5"-"$6$7"-"$8$9}'
  fi
}

# Portable file locking (works on macOS and Linux)
bp_lock() {
  local lock_file="$1"
  local timeout="${2:-5}"
  local elapsed=0

  while [[ "$elapsed" -lt "$timeout" ]]; do
    if ( set -o noclobber; echo $$ > "${lock_file}.lck" ) 2>/dev/null; then
      return 0
    fi
    # Check if the process holding the lock is still alive
    local holder
    holder="$(cat "${lock_file}.lck" 2>/dev/null)" || true
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
      rm -f "${lock_file}.lck"
      continue
    fi
    sleep 1
    elapsed="$((elapsed + 1))"
  done
  return 1
}

bp_unlock() {
  local lock_file="$1"
  rm -f "${lock_file}.lck"
}

bp_list_containers() {
  docker ps -a --filter "label=${BROWSER_POOL_LABEL_PREFIX}.managed=true" --format '{{.ID}}' 2>/dev/null
}

bp_list_running_containers() {
  docker ps --filter "label=${BROWSER_POOL_LABEL_PREFIX}.managed=true" --format '{{.ID}}' 2>/dev/null
}

bp_container_label() {
  local container_id="$1"
  local label="$2"
  docker inspect --format "{{index .Config.Labels \"${label}\"}}" "$container_id" 2>/dev/null
}

bp_container_port() {
  local container_id="$1"
  bp_container_label "$container_id" "${BROWSER_POOL_LABEL_PREFIX}.xpra-port"
}

bp_container_playwright_port() {
  local container_id="$1"
  bp_container_label "$container_id" "${BROWSER_POOL_LABEL_PREFIX}.playwright-port"
}

bp_container_name() {
  local container_id="$1"
  docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||'
}

bp_format_duration() {
  local seconds="$1"
  if [[ "$seconds" -ge 3600 ]]; then
    printf '%dh %dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  elif [[ "$seconds" -ge 60 ]]; then
    printf '%dm %ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%ds' "$seconds"
  fi
}

bp_list_lease_files() {
  local lease_dir="${BROWSER_POOL_STATE_DIR}/leases"
  local f
  for f in "${lease_dir}"/*.json; do
    [[ -f "$f" ]] && echo "$f"
  done
}

bp_list_queue_files() {
  local queue_dir="${BROWSER_POOL_STATE_DIR}/queue"
  local f
  for f in "${queue_dir}"/*; do
    [[ -f "$f" ]] && echo "$f"
  done
}
