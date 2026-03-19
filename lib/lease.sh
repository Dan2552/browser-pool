#!/usr/bin/env bash
# Lease management: acquire, release, heartbeat, worker indexing.

bp_lease_file() {
  local container_id="$1"
  echo "${BROWSER_POOL_STATE_DIR}/leases/${container_id}.json"
}

bp_read_lease() {
  local container_id="$1"
  local file
  file="$(bp_lease_file "$container_id")"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

bp_read_lease_field() {
  local container_id="$1"
  local field="$2"
  local lease
  lease="$(bp_read_lease "$container_id")"
  if [[ -n "$lease" ]]; then
    echo "$lease" | grep "\"${field}\"" | sed 's/.*: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/'
  fi
}

bp_write_lease() {
  local container_id="$1"
  local status="$2"
  local lease_id="$3"
  local project="$4"
  local worker_index="$5"
  local now
  now="$(bp_now)"

  local file
  file="$(bp_lease_file "$container_id")"

  local tmp="${file}.tmp.$$"
  printf '{\n  "container_id": "%s",\n  "status": "%s",\n  "lease_id": "%s",\n  "leased_at": %s,\n  "leased_by": "%s",\n  "worker_index": %s,\n  "updated_at": %s\n}\n' \
    "$container_id" "$status" "$lease_id" "$now" "$project" "$worker_index" "$now" > "$tmp"
  mv "$tmp" "$file"
}

bp_active_worker_indices() {
  local file
  while IFS= read -r file; do
    local status
    status="$(grep '"status"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
    if [[ "$status" == "leased" ]]; then
      grep '"worker_index"' "$file" | sed 's/.*: *\([0-9]*\).*/\1/'
    fi
  done < <(bp_list_lease_files)
}

bp_next_worker_index() {
  local used
  used="$(bp_active_worker_indices | sort -n)"
  local index=0
  while echo "$used" | grep -qx "$index" 2>/dev/null; do
    index="$((index + 1))"
  done
  echo "$index"
}

bp_find_idle_container() {
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    local status
    status="$(grep '"status"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
    if [[ "$status" == "idle" ]]; then
      local cid
      cid="$(grep '"container_id"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
      # Verify container still exists and is running
      local state
      state="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)" || state=""
      if [[ "$state" == "running" ]]; then
        echo "$cid"
        return 0
      elif [[ -n "$state" ]]; then
        # Container exists but is stopped — try to restart it
        if docker start "$cid" > /dev/null 2>&1; then
          # Wait briefly for it to be usable
          sleep 1
          local new_state
          new_state="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)" || new_state=""
          if [[ "$new_state" == "running" ]]; then
            echo "$cid"
            return 0
          fi
        fi
        # Restart failed — remove stale container and lease
        docker rm -f "$cid" > /dev/null 2>&1 || true
        rm -f "$file"
      else
        # Container doesn't exist at all — stale lease file
        rm -f "$file"
      fi
    fi
  done < <(bp_list_lease_files)
  return 1
}

bp_do_acquire() {
  local project="${1:-unknown}"
  local network="${2:-}"
  local mount="${3:-}"

  # Run opportunistic GC
  bp_gc_expired 2>/dev/null || true

  local container_id=""
  local reused=false

  # Try to find an idle container
  container_id="$(bp_find_idle_container 2>/dev/null)" && reused=true || true

  if [[ -z "$container_id" ]]; then
    # Check if we're at capacity
    local count
    count="$(bp_count_containers)"
    if [[ "$count" -ge "$BROWSER_POOL_MAX_CONTAINERS" ]]; then
      return 1  # At capacity, caller should queue
    fi

    # Create a new container
    container_id="$(bp_create_container "$network" "$mount")" || return 2
    reused=false
  fi

  if [[ "$reused" == "true" ]]; then
    # Verify the mount matches — volumes can't be changed on a running container
    if [[ -n "$mount" ]]; then
      local want_src="${mount%%:*}"
      local want_dst="${mount#*:}"
      local has_mount
      has_mount="$(docker inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$container_id" 2>/dev/null)"
      if ! echo "$has_mount" | grep -q "${want_src}:${want_dst}"; then
        # Mount doesn't match — can't reuse this container, create a new one
        reused=false
        container_id=""
        local count
        count="$(bp_count_containers)"
        if [[ "$count" -ge "$BROWSER_POOL_MAX_CONTAINERS" ]]; then
          return 1  # At capacity
        fi
        container_id="$(bp_create_container "$network" "$mount")" || return 2
      fi
    fi

    if [[ "$reused" == "true" ]]; then
      # Reset browser state in reused container
      bp_restart_xpra "$container_id" 2>/dev/null || true

      # If network specified, connect the container to it
      if [[ -n "$network" ]]; then
        docker network connect "$network" "$container_id" 2>/dev/null || true
      fi
    fi
  fi

  local lease_id
  lease_id="$(bp_uuid)"
  local worker_index
  worker_index="$(bp_next_worker_index)"
  local port
  port="$(bp_container_port "$container_id")"

  bp_write_lease "$container_id" "leased" "$lease_id" "$project" "$worker_index"

  # Output JSON
  printf '{"lease_id":"%s","xpra_port":%s,"container_id":"%s","worker_index":%s,"xpra_url":"http://127.0.0.1:%s/?reconnect=true"}\n' \
    "$lease_id" "$port" "$container_id" "$worker_index" "$port"
}

bp_acquire() {
  local project="${1:-unknown}"
  local network="${2:-}"
  local mount="${3:-}"
  local timeout="${4:-$BROWSER_POOL_ACQUIRE_TIMEOUT}"

  # Try under lock
  if ! bp_lock "$BROWSER_POOL_LOCK_FILE" 5; then
    bp_log "ERROR: Could not acquire pool lock"
    return 1
  fi

  local result rc
  result="$(bp_do_acquire "$project" "$network" "$mount" 2>&1)"
  rc=$?

  bp_unlock "$BROWSER_POOL_LOCK_FILE"

  if [[ $rc -eq 0 ]]; then
    echo "$result"
    return 0
  fi

  if [[ $rc -eq 1 ]]; then
    # At capacity — enter queue
    bp_queue_and_wait "$project" "$network" "$mount" "$timeout"
    return $?
  fi

  # rc == 2 or other: creation failed
  bp_log "ERROR: Failed to acquire browser"
  echo "$result" >&2
  return 1
}

bp_release() {
  local lease_id="$1"

  if ! bp_lock "$BROWSER_POOL_LOCK_FILE" 5; then
    bp_log "ERROR: Could not acquire pool lock"
    return 1
  fi

  bp_do_release "$lease_id"
  local rc=$?

  bp_unlock "$BROWSER_POOL_LOCK_FILE"
  return $rc
}

bp_do_release() {
  local lease_id="$1"
  local file

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if grep -q "\"${lease_id}\"" "$file" 2>/dev/null; then
      local container_id
      container_id="$(grep '"container_id"' "$file" | sed 's/.*: *"\([^"]*\)".*/\1/')"
      local now
      now="$(bp_now)"

      # Mark as idle
      local tmp="${file}.tmp.$$"
      printf '{\n  "container_id": "%s",\n  "status": "idle",\n  "lease_id": "",\n  "leased_at": 0,\n  "leased_by": "",\n  "worker_index": -1,\n  "updated_at": %s\n}\n' \
        "$container_id" "$now" > "$tmp"
      mv "$tmp" "$file"

      # Reset browser state
      bp_restart_xpra "$container_id" 2>/dev/null || true

      bp_log "Released lease ${lease_id} (container ${container_id})"
      return 0
    fi
  done < <(bp_list_lease_files)

  bp_log "WARNING: Lease ${lease_id} not found"
  return 1
}

bp_heartbeat() {
  local lease_id="$1"
  local file

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if grep -q "\"${lease_id}\"" "$file" 2>/dev/null; then
      local now
      now="$(bp_now)"
      sed -i.bak "s/\"updated_at\": *[0-9]*/\"updated_at\": ${now}/" "$file"
      rm -f "${file}.bak"
      return 0
    fi
  done < <(bp_list_lease_files)
  return 1
}
