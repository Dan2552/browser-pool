#!/usr/bin/env bash
# Garbage collection: remove idle/stale containers, clean orphan state.

bp_gc_expired() {
  local max_idle="${1:-$BROWSER_POOL_IDLE_TTL}"
  local now
  now="$(bp_now)"
  local lease_dir="${BROWSER_POOL_STATE_DIR}/leases"
  local removed=0

  # Check each lease file
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    local status container_id updated_at
    status="$(grep '"status"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
    container_id="$(grep '"container_id"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
    updated_at="$(grep '"updated_at"' "$file" | sed 's/.*: *\([0-9]*\).*/\1/')"

    if [[ -z "$container_id" ]]; then
      rm -f "$file"
      continue
    fi

    # Check if the container still exists
    if ! docker inspect "$container_id" > /dev/null 2>&1; then
      rm -f "$file"
      continue
    fi

    local age="$((now - updated_at))"

    if [[ "$status" == "idle" && "$age" -ge "$max_idle" ]]; then
      bp_log "GC: Removing idle container $container_id (idle for $(bp_format_duration "$age"))"
      bp_remove_container "$container_id"
      rm -f "$file"
      removed="$((removed + 1))"
    elif [[ "$status" == "leased" && "$age" -ge "$BROWSER_POOL_LEASE_TTL" ]]; then
      bp_log "GC: Removing stale leased container $container_id (lease expired after $(bp_format_duration "$age"))"
      bp_remove_container "$container_id"
      rm -f "$file"
      removed="$((removed + 1))"
    fi
  done < <(bp_list_lease_files)

  # Find orphan containers (in Docker but no lease file)
  local id
  for id in $(bp_list_containers); do
    local short_id="${id:0:12}"
    local has_lease=false
    local lf
    while IFS= read -r lf; do
      [[ -n "$lf" ]] || continue
      if grep -q "$short_id\|$id" "$lf" 2>/dev/null; then
        has_lease=true
        break
      fi
    done < <(bp_list_lease_files)
    if [[ "$has_lease" == "false" ]]; then
      bp_log "GC: Removing orphan container $short_id (no lease file)"
      bp_remove_container "$id"
      removed="$((removed + 1))"
    fi
  done

  # Clean up orphan queue entries from dead processes
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    local pid
    pid="$(grep '"pid"' "$entry" | sed 's/.*: *\([0-9]*\).*/\1/')"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$entry"
    fi
  done < <(bp_list_queue_files)

  if [[ "$removed" -gt 0 ]]; then
    bp_log "GC: Removed $removed container(s)"
  fi
}

bp_destroy_all() {
  local id
  for id in $(bp_list_containers); do
    bp_log "Destroying container $(bp_container_name "$id" 2>/dev/null || echo "$id")"
    bp_remove_container "$id"
  done

  # Clean all state files
  rm -f "${BROWSER_POOL_STATE_DIR}/leases/"*.json 2>/dev/null
  rm -f "${BROWSER_POOL_STATE_DIR}/queue/"* 2>/dev/null

  bp_log "All pool containers destroyed"
}
