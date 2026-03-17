#!/usr/bin/env bash
# Blocking queue for when the pool is at capacity.

bp_queue_entry_file() {
  local queue_id="$1"
  echo "${BROWSER_POOL_STATE_DIR}/queue/${queue_id}"
}

bp_write_queue_entry() {
  local queue_id="$1"
  local project="$2"
  local now
  now="$(bp_now)"
  local file
  file="$(bp_queue_entry_file "$queue_id")"
  printf '{\n  "queue_id": "%s",\n  "project": "%s",\n  "pid": %s,\n  "requested_at": %s\n}\n' \
    "$queue_id" "$project" "$$" "$now" > "$file"
}

bp_remove_queue_entry() {
  local queue_id="$1"
  rm -f "$(bp_queue_entry_file "$queue_id")"
}

bp_is_first_in_queue() {
  local queue_id="$1"
  local queue_dir="${BROWSER_POOL_STATE_DIR}/queue"

  # Clean up entries from dead processes first
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    local pid
    pid="$(grep '"pid"' "$entry" | sed 's/.*: *\([0-9]*\).*/\1/')"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$entry"
    fi
  done < <(bp_list_queue_files)

  # Check if our entry is the oldest (FIFO by filename, which is timestamp-based)
  local first
  first="$(ls -1 "${queue_dir}/" 2>/dev/null | head -1)"
  [[ "$first" == "$queue_id" ]]
}

bp_queue_and_wait() {
  local project="$1"
  local network="$2"
  local mount="$3"
  local timeout="$4"

  local now
  now="$(bp_now)"
  local queue_id
  queue_id="$(printf '%010d' "$now")-$(bp_uuid | cut -c1-8)"

  bp_write_queue_entry "$queue_id" "$project"
  bp_log "Pool at capacity (${BROWSER_POOL_MAX_CONTAINERS}). Queued as ${queue_id}, waiting..."

  # Clean up queue entry on exit
  local _bp_queue_cleanup_id="$queue_id"
  trap 'bp_remove_queue_entry "$_bp_queue_cleanup_id"' EXIT

  local start_time="$now"
  local elapsed=0

  while [[ "$elapsed" -lt "$timeout" ]]; do
    sleep 1
    elapsed="$(( $(bp_now) - start_time ))"

    # Only attempt if we're first in queue (FIFO)
    if ! bp_is_first_in_queue "$queue_id"; then
      continue
    fi

    # Try to acquire under lock
    if ! bp_lock "$BROWSER_POOL_LOCK_FILE" 2; then
      continue
    fi

    local result rc
    result="$(bp_do_acquire "$project" "$network" "$mount" 2>&1)"
    rc=$?

    bp_unlock "$BROWSER_POOL_LOCK_FILE"

    if [[ $rc -eq 0 ]]; then
      bp_remove_queue_entry "$queue_id"
      trap - EXIT
      echo "$result"
      return 0
    fi
  done

  bp_remove_queue_entry "$queue_id"
  trap - EXIT
  bp_log "ERROR: Timed out waiting for browser after ${timeout}s"
  return 1
}

bp_list_queue() {
  local now
  now="$(bp_now)"
  local entry

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    local project pid requested_at
    project="$(grep '"project"' "$entry" | sed 's/.*: *"\([^"]*\)".*/\1/')"
    pid="$(grep '"pid"' "$entry" | sed 's/.*: *\([0-9]*\).*/\1/')"
    requested_at="$(grep '"requested_at"' "$entry" | sed 's/.*: *\([0-9]*\).*/\1/')"

    # Skip entries from dead processes
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$entry"
      continue
    fi

    local waiting="$((now - requested_at))"
    printf '  %-20s %s\n' "$project" "$(bp_format_duration "$waiting")"
  done < <(bp_list_queue_files)
}
