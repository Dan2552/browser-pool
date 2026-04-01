#!/usr/bin/env bash
# Garbage collection: remove idle/stale containers, clean orphan state.

bp_gc_expired() {
  local max_idle="${1:-$BROWSER_POOL_IDLE_TTL}"
  local max_idle_excess="${BROWSER_POOL_IDLE_TTL_EXCESS}"
  local now
  now="$(bp_now)"
  local lease_dir="${BROWSER_POOL_STATE_DIR}/leases"
  local removed=0

  # First pass: collect idle containers sorted by most recently used,
  # and handle stale leases / missing containers.
  local idle_files=()
  local idle_updated_ats=()

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

    if [[ "$status" == "idle" ]]; then
      idle_files+=("$file")
      idle_updated_ats+=("$updated_at")
    elif [[ "$status" == "leased" && "$age" -ge "$BROWSER_POOL_LEASE_TTL" ]]; then
      bp_log "GC: Removing stale leased container $container_id (lease expired after $(bp_format_duration "$age"))"
      bp_remove_container "$container_id"
      rm -f "$file"
      removed="$((removed + 1))"
    fi
  done < <(bp_list_lease_files)

  # Sort idle containers by updated_at descending (most recent first).
  # The first one gets max_idle; the rest get max_idle_excess.
  local idle_count="${#idle_files[@]}"
  if [[ "$idle_count" -gt 0 ]]; then
    # Build index array sorted by updated_at descending
    local sorted_indices
    sorted_indices="$(
      for i in $(seq 0 $((idle_count - 1))); do
        echo "${idle_updated_ats[$i]} $i"
      done | sort -rn | awk '{print $2}'
    )"

    local rank=0
    local idx
    for idx in $sorted_indices; do
      local f="${idle_files[$idx]}"
      local updated_at="${idle_updated_ats[$idx]}"
      local age="$((now - updated_at))"
      local ttl

      if [[ "$rank" -eq 0 ]]; then
        ttl="$max_idle"
      else
        ttl="$max_idle_excess"
      fi

      if [[ "$age" -ge "$ttl" ]]; then
        local cid
        cid="$(grep '"container_id"' "$f" | sed 's/.*: *"\([^"]*\)".*/\1/')"
        if [[ "$rank" -eq 0 ]]; then
          bp_log "GC: Removing idle container $cid (idle for $(bp_format_duration "$age"))"
        else
          bp_log "GC: Removing excess idle container $cid (idle for $(bp_format_duration "$age"), excess TTL $(bp_format_duration "$ttl"))"
        fi
        bp_remove_container "$cid"
        rm -f "$f"
        removed="$((removed + 1))"
      fi

      rank="$((rank + 1))"
    done
  fi

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
