#!/usr/bin/env bash
# Container lifecycle: create, remove, health-check.

bp_create_container() {
  local network="${1:-}"
  local mount="${2:-}"

  local port
  port="$(bp_allocate_port)" || return 1

  local name="bp-$(bp_uuid | cut -c1-8)"
  local now
  now="$(bp_now)"

  local docker_args=(
    run -d
    --name "$name"
    --label "${BROWSER_POOL_LABEL_PREFIX}.managed=true"
    --label "${BROWSER_POOL_LABEL_PREFIX}.xpra-port=${port}"
    --label "${BROWSER_POOL_LABEL_PREFIX}.created-at=${now}"
    --shm-size="${BROWSER_POOL_SHM_SIZE}"
    -p "127.0.0.1:${port}:14500"
    -e "DISPLAY=:100"
    -e "XPRA_DISPLAY=:100"
    -e "XPRA_PORT=14500"
    -e "BROWSER_POOL_IDLE_TTL=${BROWSER_POOL_IDLE_TTL}"
  )

  if [[ -n "$network" ]]; then
    docker_args+=(--network "$network")
  fi

  if [[ -n "$mount" ]]; then
    docker_args+=(-v "$mount")
  fi

  docker_args+=("${BROWSER_POOL_IMAGE}")

  local container_id
  container_id="$(docker "${docker_args[@]}" 2>&1)" || {
    bp_log "ERROR: Failed to create container: $container_id"
    return 1
  }

  # Wait for Xpra to be healthy
  if ! bp_wait_healthy "$port"; then
    bp_log "ERROR: Container $name failed health check, removing"
    docker rm -f "$container_id" > /dev/null 2>&1
    return 1
  fi

  echo "$container_id"
}

bp_wait_healthy() {
  local port="$1"
  local elapsed=0

  while [[ "$elapsed" -lt "$BROWSER_POOL_HEALTH_TIMEOUT" ]]; do
    if curl -sf "http://127.0.0.1:${port}/" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed="$((elapsed + 1))"
  done

  return 1
}

bp_remove_container() {
  local container_id="$1"
  docker stop "$container_id" --time 10 > /dev/null 2>&1
  docker rm -f "$container_id" > /dev/null 2>&1
  # Clean up lease file
  rm -f "${BROWSER_POOL_STATE_DIR}/leases/${container_id}"* 2>/dev/null

  # Also try by short ID / name
  local name
  name="$(bp_container_name "$container_id" 2>/dev/null)" || true
  if [[ -n "$name" ]]; then
    rm -f "${BROWSER_POOL_STATE_DIR}/leases/${name}"* 2>/dev/null
  fi
}

bp_count_containers() {
  bp_list_containers | wc -l | tr -d ' '
}

bp_restart_xpra() {
  local container_id="$1"
  # Kill any running browser processes to reset state
  docker exec "$container_id" bash -c 'pkill -f "chromium|playwright" 2>/dev/null; true' > /dev/null 2>&1
}
