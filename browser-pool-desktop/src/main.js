const { invoke } = window.__TAURI__.core;

let autoRefreshInterval = null;
let autoGCInterval = null;
let openViewers = {}; // Track which lease_ids have open viewers
let lastLeasesJson = ""; // Cache to avoid unnecessary re-renders

// DOM refs
let statusOutput, commandOutput, outputPanel, acquirePanel, acquireResult, leasesListEl;

function show(el) { el.classList.remove("hidden"); }
function hide(el) { el.classList.add("hidden"); }

function showOutput(text) {
  commandOutput.textContent = text;
  show(outputPanel);
}

function setLoading(btn, loading) {
  btn.disabled = loading;
  if (loading) btn.dataset.origText = btn.textContent;
  btn.textContent = loading ? "Working..." : (btn.dataset.origText || btn.textContent);
}

async function refreshStatus() {
  try {
    const result = await invoke("pool_status");
    statusOutput.textContent = result || "(empty)";
  } catch (e) {
    statusOutput.textContent = "Error: " + e;
  }
  await refreshLeases();
}

function startAutoRefresh() {
  stopAutoRefresh();
  autoRefreshInterval = setInterval(refreshStatus, 5000);
}

function stopAutoRefresh() {
  if (autoRefreshInterval) {
    clearInterval(autoRefreshInterval);
    autoRefreshInterval = null;
  }
}

async function runGCQuietly() {
  try {
    await invoke("pool_gc", { maxIdle: null });
    refreshStatus();
  } catch (_) {}
}

function startAutoGC() {
  stopAutoGC();
  autoGCInterval = setInterval(runGCQuietly, 60000);
}

function stopAutoGC() {
  if (autoGCInterval) {
    clearInterval(autoGCInterval);
    autoGCInterval = null;
  }
}

async function refreshLeases() {
  try {
    const result = await invoke("pool_list_leases");
    const trimmed = result.trim();
    // Skip re-render if data hasn't changed (avoids iframe reload)
    if (trimmed === lastLeasesJson) return;
    lastLeasesJson = trimmed;
    const leases = JSON.parse(trimmed);
    renderLeases(leases);
  } catch (e) {
    if (lastLeasesJson !== "[]") {
      lastLeasesJson = "[]";
      renderLeases([]);
    }
  }
}

function renderLeases(leases) {
  leasesListEl.innerHTML = "";

  for (const lease of leases) {
    const wrapper = document.createElement("div");
    wrapper.className = "lease-wrapper";

    const div = document.createElement("div");
    div.className = "lease-card";

    const info = document.createElement("span");
    info.className = "lease-info";
    info.innerHTML =
      "<code>" + lease.lease_id + "</code>" +
      " &mdash; port " + (lease.xpra_port || "?") +
      ", worker " + (lease.worker_index ?? "?") +
      (lease.project ? " &mdash; " + lease.project : "");
    div.appendChild(info);

    if (lease.xpra_url) {
      const viewBtn = document.createElement("button");
      viewBtn.className = "small";
      viewBtn.textContent = openViewers[lease.lease_id] ? "Hide" : "View";
      viewBtn.addEventListener("click", () => {
        const viewer = wrapper.querySelector(".lease-viewer");
        if (viewer) {
          viewer.remove();
          delete openViewers[lease.lease_id];
          viewBtn.textContent = "View";
        } else {
          const container = document.createElement("div");
          container.className = "lease-viewer";
          const iframe = document.createElement("iframe");
          iframe.src = lease.xpra_url + "&keyboard=false";
          iframe.className = "xpra-iframe";
          container.appendChild(iframe);
          wrapper.appendChild(container);
          openViewers[lease.lease_id] = true;
          viewBtn.textContent = "Hide";
        }
      });
      div.appendChild(viewBtn);

      const link = document.createElement("a");
      link.href = "#";
      link.textContent = "Open Xpra";
      link.addEventListener("click", (e) => {
        e.preventDefault();
        window.__TAURI__.opener.openUrl(lease.xpra_url);
      });
      div.appendChild(link);
    }

    const releaseBtn = document.createElement("button");
    releaseBtn.className = "danger small";
    releaseBtn.textContent = "Release";
    releaseBtn.addEventListener("click", () => handleRelease(lease.lease_id));
    div.appendChild(releaseBtn);

    wrapper.appendChild(div);

    // Re-open viewer if it was open before refresh
    if (openViewers[lease.lease_id] && lease.xpra_url) {
      const container = document.createElement("div");
      container.className = "lease-viewer";
      const iframe = document.createElement("iframe");
      iframe.src = lease.xpra_url + "&keyboard=false";
      iframe.className = "xpra-iframe";
      container.appendChild(iframe);
      wrapper.appendChild(container);
    }

    leasesListEl.appendChild(wrapper);
  }

  // Always show manual release input
  const row = document.createElement("div");
  row.className = "release-input-row";
  row.innerHTML =
    '<input id="manual-lease-id" type="text" placeholder="Or enter a lease ID to release..." />' +
    '<button class="small" id="manual-release-btn">Release</button>';
  leasesListEl.appendChild(row);

  document.getElementById("manual-release-btn").addEventListener("click", () => {
    const id = document.getElementById("manual-lease-id").value.trim();
    if (id) handleRelease(id);
  });

  if (leases.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No active leases in the pool.";
    leasesListEl.insertBefore(empty, row);
  }

  // Clean up openViewers for leases that no longer exist
  const activeIds = new Set(leases.map((l) => l.lease_id));
  for (const id of Object.keys(openViewers)) {
    if (!activeIds.has(id)) delete openViewers[id];
  }
}

async function handleAcquire(e) {
  e.preventDefault();
  const project = document.getElementById("acquire-project").value;
  const network = document.getElementById("acquire-network").value || null;
  const mount = document.getElementById("acquire-mount").value || null;
  const timeoutVal = document.getElementById("acquire-timeout").value;
  const timeout = timeoutVal ? parseInt(timeoutVal, 10) : null;

  const btn = e.target.querySelector('button[type="submit"]');
  setLoading(btn, true);
  show(acquireResult);
  acquireResult.textContent = "Acquiring browser...";

  try {
    const result = await invoke("pool_acquire", { project, network, mount, timeout });
    acquireResult.textContent = result;
    lastLeasesJson = "";
    refreshStatus();
  } catch (e) {
    acquireResult.textContent = "Error: " + e;
  } finally {
    setLoading(btn, false);
  }
}

async function handleRelease(leaseId) {
  try {
    const result = await invoke("pool_release", { leaseId });
    showOutput(result || "Released successfully.");
    delete openViewers[leaseId];
    lastLeasesJson = "";
    refreshStatus();
  } catch (e) {
    showOutput("Release error: " + e);
  }
}

async function handleGC() {
  const btn = document.getElementById("btn-gc");
  setLoading(btn, true);
  try {
    const result = await invoke("pool_gc", { maxIdle: null });
    showOutput(result || "GC complete.");
    refreshStatus();
  } catch (e) {
    showOutput("GC error: " + e);
  } finally {
    setLoading(btn, false);
  }
}

async function handleBuild() {
  const btn = document.getElementById("btn-build");
  setLoading(btn, true);
  showOutput("Building Docker image... this may take a while.");
  try {
    const result = await invoke("pool_build");
    showOutput(result || "Build complete.");
  } catch (e) {
    showOutput("Build error: " + e);
  } finally {
    setLoading(btn, false);
  }
}

async function handleConfig() {
  try {
    const result = await invoke("pool_config");
    showOutput(result);
  } catch (e) {
    showOutput("Config error: " + e);
  }
}

async function handleDestroyAll() {
  if (!confirm("This will destroy ALL pool containers. Are you sure?")) return;
  const btn = document.getElementById("btn-destroy-all");
  setLoading(btn, true);
  try {
    const result = await invoke("pool_destroy_all");
    showOutput(result || "All containers destroyed.");
    openViewers = {};
    lastLeasesJson = "";
    refreshStatus();
  } catch (e) {
    showOutput("Destroy error: " + e);
  } finally {
    setLoading(btn, false);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  statusOutput = document.getElementById("status-output");
  commandOutput = document.getElementById("command-output");
  outputPanel = document.getElementById("output-panel");
  acquirePanel = document.getElementById("acquire-panel");
  acquireResult = document.getElementById("acquire-result");
  leasesListEl = document.getElementById("leases-list");

  document.getElementById("btn-refresh").addEventListener("click", refreshStatus);
  document.getElementById("btn-acquire").addEventListener("click", () => {
    acquirePanel.classList.toggle("hidden");
  });
  document.getElementById("btn-gc").addEventListener("click", handleGC);
  document.getElementById("btn-build").addEventListener("click", handleBuild);
  document.getElementById("btn-config").addEventListener("click", handleConfig);
  document.getElementById("btn-destroy-all").addEventListener("click", handleDestroyAll);
  document.getElementById("btn-close-output").addEventListener("click", () => hide(outputPanel));

  document.getElementById("acquire-form").addEventListener("submit", handleAcquire);
  document.getElementById("acquire-cancel").addEventListener("click", () => hide(acquirePanel));

  const autoRefreshCb = document.getElementById("auto-refresh");
  autoRefreshCb.addEventListener("change", () => {
    if (autoRefreshCb.checked) startAutoRefresh();
    else stopAutoRefresh();
  });

  const autoGCCb = document.getElementById("auto-gc");
  autoGCCb.addEventListener("change", () => {
    if (autoGCCb.checked) startAutoGC();
    else stopAutoGC();
  });

  refreshStatus();
  startAutoRefresh();
  startAutoGC();
});
