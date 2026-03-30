# browser-pool

A pool manager for Docker-based browser containers. Each container runs a headless browser under [Xpra](https://xpra.org/), accessible via a web UI on a local port, and a Playwright browser server accessible via WebSocket for programmatic automation. The pool keeps containers warm and reuses them across test runs to avoid cold-start overhead.

## How it works

- Containers run a Playwright-capable browser inside Xpra (a virtual display server with a built-in web client)
- Each container exposes its Xpra session on a unique localhost port (range: 20000–40000 by default), and a Playwright browser server on a second port from the same range
- A JSON lease file in `~/.browser-pool/leases/` tracks whether each container is `leased` or `idle`
- When a consumer acquires a browser, the pool reuses an idle container (resetting its Xpra session) or spawns a new one up to `BROWSER_POOL_MAX_CONTAINERS`. A Playwright browser server is started on each acquire and its WebSocket endpoint is returned
- If the pool is at capacity, the caller is queued and waits up to `BROWSER_POOL_ACQUIRE_TIMEOUT` seconds
- On release, containers are marked idle and kept alive for reuse; the Xpra session and Playwright server are stopped to give the next consumer a clean browser

## Prerequisites

- Docker
- Python 3 (for the dashboard)
- `uuidgen` (standard on macOS; available as `uuid-runtime` on Debian/Ubuntu)

## Setup

Build the Docker image once before first use:

```sh
bin/browser-pool build
```

## Usage

```
browser-pool <command> [options]

Commands:
  acquire       Acquire a browser from the pool (blocks if full)
  release       Release a browser back to the pool
  exec          Acquire, run a command, then release automatically
  status        Show pool status (active, queued, idle)
  gc            Garbage collect idle/stale containers
  destroy-all   Remove all pool containers
  build         Build the browser-pool Docker image
  config        Show effective configuration
  dashboard     Open a live dashboard with all browsers in iframes
```

### acquire

Returns a JSON object with connection details for the acquired browser:

```sh
bin/browser-pool acquire --project my-project --network my-docker-network
# {"lease_id":"...","xpra_port":20001,"container_id":"...","worker_index":0,"xpra_url":"http://127.0.0.1:20001/?reconnect=true","playwright_ws":"ws://127.0.0.1:20002/..."}
```

Options: `--project <name>`, `--network <name>`, `--mount <host:container>`, `--timeout <seconds>`

### release

```sh
bin/browser-pool release <lease_id>
```

### exec

Acquires a browser, runs a command with connection details in environment variables, then releases automatically:

```sh
bin/browser-pool exec --project my-project -- my-test-command
```

Environment variables set for the command:

| Variable | Description |
|---|---|
| `BROWSER_POOL_XPRA_PORT` | Xpra port on localhost |
| `BROWSER_POOL_CONTAINER_ID` | Docker container ID |
| `BROWSER_POOL_WORKER_INDEX` | Worker index (0-based) |
| `BROWSER_POOL_LEASE_ID` | Lease ID |
| `BROWSER_POOL_XPRA_URL` | Full Xpra URL |
| `BROWSER_POOL_PLAYWRIGHT_WS` | Playwright WebSocket endpoint for remote automation |

### Playwright automation

The `playwright_ws` endpoint returned by `acquire` (or `BROWSER_POOL_PLAYWRIGHT_WS` env var in `exec`) can be used to connect to the browser programmatically:

```python
# Python
from playwright.sync_api import sync_playwright
import os

with sync_playwright() as p:
    browser = p.chromium.connect(os.environ["BROWSER_POOL_PLAYWRIGHT_WS"])
    page = browser.new_page()
    page.goto("https://example.com")
```

```javascript
// Node.js
const { chromium } = require('playwright');

const browser = await chromium.connect(process.env.BROWSER_POOL_PLAYWRIGHT_WS);
const page = await browser.newPage();
await page.goto('https://example.com');
```

### dashboard

Opens a local HTTP server (default port 9222) with a live grid view of all pool browsers embedded as iframes:

```sh
bin/browser-pool dashboard        # http://127.0.0.1:9222/
bin/browser-pool dashboard 8080   # custom port
```

### status / gc / destroy-all

```sh
bin/browser-pool status        # show active leases, queue, idle containers
bin/browser-pool gc            # remove containers idle longer than BROWSER_POOL_IDLE_TTL
bin/browser-pool destroy-all   # stop and remove every pool container
```

## Configuration

All settings are environment variables with sensible defaults:

| Variable | Default | Description |
|---|---|---|
| `BROWSER_POOL_IMAGE` | `browser-pool:latest` | Docker image name |
| `BROWSER_POOL_MAX_CONTAINERS` | `5` | Maximum concurrent containers |
| `BROWSER_POOL_PORT_RANGE_START` | `20000` | Start of port range (Xpra and Playwright) |
| `BROWSER_POOL_PORT_RANGE_END` | `40000` | End of port range (Xpra and Playwright) |
| `BROWSER_POOL_IDLE_TTL` | `1800` | Seconds before an idle container is GC'd |
| `BROWSER_POOL_LEASE_TTL` | `3600` | Seconds before a stale lease is expired |
| `BROWSER_POOL_ACQUIRE_TIMEOUT` | `300` | Seconds to wait when pool is at capacity |
| `BROWSER_POOL_STATE_DIR` | `~/.browser-pool` | Directory for lease/queue state files |
| `BROWSER_POOL_SHM_SIZE` | `1gb` | Shared memory size for containers |
| `BROWSER_POOL_HEALTH_TIMEOUT` | `30` | Seconds to wait for a new container to become healthy |
| `BROWSER_POOL_QUIET` | `0` | Set to `1` to suppress info messages (errors still print) |
| `PROFILE_BROWSER_POOL` | `0` | Set to `1` to print per-step timing to stderr |

## Directory structure

```
browser-pool/
  bin/
    browser-pool            # Main CLI
    browser-pool-dashboard  # Dashboard HTTP server
  docker/
    Dockerfile              # Playwright + Xpra image
    start-xpra.sh           # Container entrypoint
    start-playwright-server.js  # Playwright browser server launcher
  lib/
    config.sh               # Configuration defaults and shared utilities
    container.sh            # Docker container lifecycle
    gc.sh                   # Garbage collection
    lease.sh                # Lease acquire/release logic
    port.sh                 # Port allocation
    queue.sh                # Wait queue for when pool is at capacity
```
