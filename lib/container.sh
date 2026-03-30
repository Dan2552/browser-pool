#!/usr/bin/env bash
# Container lifecycle: create, remove, health-check.

bp_create_container() {
  local network="${1:-}"
  local mount="${2:-}"

  local port
  port="$(bp_allocate_port)" || return 1
  local pw_port
  pw_port="$(bp_allocate_port "$port")" || return 1

  local name="bp-$(bp_uuid | cut -c1-8)"
  local now
  now="$(bp_now)"

  local docker_args=(
    run -d
    --name "$name"
    --label "${BROWSER_POOL_LABEL_PREFIX}.managed=true"
    --label "${BROWSER_POOL_LABEL_PREFIX}.xpra-port=${port}"
    --label "${BROWSER_POOL_LABEL_PREFIX}.playwright-port=${pw_port}"
    --label "${BROWSER_POOL_LABEL_PREFIX}.created-at=${now}"
    --shm-size="${BROWSER_POOL_SHM_SIZE}"
    -p "127.0.0.1:${port}:14500"
    -p "127.0.0.1:${pw_port}:3000"
    -e "DISPLAY=:100"
    -e "XPRA_DISPLAY=:100"
    -e "XPRA_PORT=14500"
    -e "PLAYWRIGHT_SERVER_PORT=3000"
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
    bp_log_error "ERROR: Failed to create container: $container_id"
    return 1
  }

  # Wait for Xpra to be healthy
  if ! bp_wait_healthy "$port"; then
    bp_log_error "ERROR: Container $name failed health check, removing"
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
  docker exec "$container_id" bash -c 'pkill -f "chromium|playwright|start-playwright-server" 2>/dev/null; true' > /dev/null 2>&1
}

bp_start_playwright_server() {
  local container_id="$1"
  local host_port="$2"
  local timeout=15

  # Kill any existing playwright server
  docker exec "$container_id" bash -c 'pkill -f "start-playwright-server" 2>/dev/null; true' > /dev/null 2>&1
  sleep 1

  # Start the playwright server in the background, capturing output
  local log_file="/tmp/playwright-server.log"
  docker exec -d "$container_id" bash -c \
    "cd /opt/playwright-server && DISPLAY=:100 node start-playwright-server.js > ${log_file} 2>&1"

  # Wait for the ws path to appear in the log
  local elapsed=0
  local ws_path=""
  while [[ "$elapsed" -lt "$timeout" ]]; do
    ws_path="$(docker exec "$container_id" bash -c "grep 'PLAYWRIGHT_WS_PATH=' ${log_file} 2>/dev/null | head -1 | sed 's/PLAYWRIGHT_WS_PATH=//'" 2>/dev/null)" || true
    if [[ -n "$ws_path" ]]; then
      echo "ws://127.0.0.1:${host_port}${ws_path}"
      return 0
    fi
    sleep 1
    elapsed="$((elapsed + 1))"
  done

  bp_log_error "WARNING: Playwright server did not start within ${timeout}s"
  return 1
}
