const $ = (id) => document.getElementById(id);

const ipInput = $("ip");
const passwordInput = $("password");
const pathInput = $("path");
const message = $("message");
const lightState = $("lightState");
const live = $("live");

let ptzTimer = null;
let ptzDirection = null;
let ptzInFlight = false;

function loadPrefs() {
  try {
    ipInput.value =
      localStorage.getItem("localhome.web.ip") ||
      localStorage.getItem("himost.web.ip") ||
      "192.168.1.100";
    pathInput.value =
      localStorage.getItem("localhome.web.path") ||
      localStorage.getItem("himost.web.path") ||
      "/live/ch00_0";
  } catch (_) {
    ipInput.value = ipInput.value || "192.168.1.100";
    pathInput.value = pathInput.value || "/live/ch00_0";
  }
}

function savePrefs() {
  try {
    localStorage.setItem("localhome.web.ip", ipInput.value.trim());
    localStorage.setItem("localhome.web.path", pathInput.value.trim());
  } catch (_) {
    // Preferences are optional; ignore private-mode failures.
  }
}

function showMessage(text, error = false) {
  message.textContent = text;
  message.classList.toggle("error", error);
}

function cameraBody(extra = {}) {
  return {
    ip: ipInput.value.trim(),
    password: passwordInput.value,
    ...extra,
  };
}

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  let data = {};
  try {
    data = await response.json();
  } catch (_) {
    // Keep the status code as the fallback error.
  }
  if (!response.ok) {
    throw new Error(data.error || `Request failed (${response.status})`);
  }
  return data;
}

function lightLabel(state) {
  if (!state || !state.mode) return "unknown";
  return state.status ? `${state.mode.toUpperCase()} (${state.status})` : state.mode.toUpperCase();
}

async function readLight() {
  const buttons = document.querySelectorAll(".light");
  buttons.forEach((button) => (button.disabled = true));
  try {
    const state = await api("/api/light/status", cameraBody());
    lightState.textContent = lightLabel(state);
    showMessage("Light state read.");
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    buttons.forEach((button) => (button.disabled = false));
  }
}

async function setLight(mode) {
  const buttons = document.querySelectorAll(".light");
  buttons.forEach((button) => (button.disabled = true));
  lightState.textContent = mode.toUpperCase();
  try {
    const state = await api("/api/light/set", cameraBody({ mode }));
    lightState.textContent = lightLabel(state);
    showMessage(`Light set to ${mode.toUpperCase()}.`);
  } catch (error) {
    lightState.textContent = "unknown";
    showMessage(error.message, true);
  } finally {
    buttons.forEach((button) => (button.disabled = false));
  }
}

function stopPtz() {
  if (ptzTimer) {
    clearInterval(ptzTimer);
    ptzTimer = null;
  }
  if (!ptzDirection) return;
  ptzDirection = null;
  api("/api/ptz/stop", { ip: ipInput.value.trim() }).catch((error) =>
    showMessage(error.message, true),
  );
}

function startPtz(direction) {
  if (ptzDirection === direction) return;
  stopPtz();
  const ip = ipInput.value.trim();
  if (!ip) {
    showMessage("Enter the camera IP first.", true);
    return;
  }
  ptzDirection = direction;
  showMessage(`PTZ ${direction}…`);
  const send = () => {
    if (ptzInFlight || ptzDirection !== direction) return;
    ptzInFlight = true;
    api("/api/ptz/start", { ip, direction })
      .catch((error) => {
        showMessage(error.message, true);
        stopPtz();
      })
      .finally(() => {
        ptzInFlight = false;
      });
  };
  send();
  ptzTimer = setInterval(send, 350);
}

async function snapshot() {
  const ip = ipInput.value.trim();
  const path = pathInput.value.trim() || "/live/ch00_0";
  if (!ip) {
    showMessage("Enter the camera IP first.", true);
    return;
  }
  savePrefs();
  try {
    const response = await fetch(
      `/api/snapshot?ip=${encodeURIComponent(ip)}&path=${encodeURIComponent(path)}&t=${Date.now()}`,
    );
    if (!response.ok) {
      let data = {};
      try {
        data = await response.json();
      } catch (_) {
        // Use the status code below.
      }
      throw new Error(data.error || `Snapshot failed (${response.status})`);
    }
    const blob = await response.blob();
    if (live.dataset.objectUrl) URL.revokeObjectURL(live.dataset.objectUrl);
    const objectUrl = URL.createObjectURL(blob);
    live.dataset.objectUrl = objectUrl;
    live.src = objectUrl;
    showMessage("Snapshot loaded.");
  } catch (error) {
    showMessage(error.message, true);
  }
}

function startStream() {
  const ip = ipInput.value.trim();
  const path = pathInput.value.trim() || "/live/ch00_0";
  if (!ip) {
    showMessage("Enter the camera IP first.", true);
    return;
  }
  savePrefs();
  live.src = `/api/stream?ip=${encodeURIComponent(ip)}&path=${encodeURIComponent(path)}&t=${Date.now()}`;
  showMessage("Live view starting…");
}

function stopStream() {
  if (live.dataset.objectUrl) {
    URL.revokeObjectURL(live.dataset.objectUrl);
    delete live.dataset.objectUrl;
  }
  live.removeAttribute("src");
  live.src =
    "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==";
  showMessage("Live view stopped.");
}

function wirePtz() {
  for (const button of document.querySelectorAll("[data-ptz]")) {
    const direction = button.dataset.ptz;
    if (direction === "stop") {
      button.addEventListener("click", stopPtz);
      continue;
    }
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      button.setPointerCapture?.(event.pointerId);
      startPtz(direction);
    });
    button.addEventListener("pointerup", (event) => {
      event.preventDefault();
      stopPtz();
    });
    button.addEventListener("pointercancel", stopPtz);
    button.addEventListener("pointerleave", () => {
      if (ptzDirection === direction) stopPtz();
    });
  }
  window.addEventListener("pointerup", () => stopPtz());
  window.addEventListener("blur", () => stopPtz());
}

const dvrList = $("dvrList");
const dvrPlayer = $("dvrPlayer");

function formatSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function refreshDvr() {
  try {
    const response = await fetch("/api/dvr/list");
    const data = await response.json();
    dvrList.innerHTML = "";
    const items = data.recordings || [];
    if (!items.length) {
      const empty = document.createElement("li");
      empty.textContent = "No local recordings yet.";
      dvrList.appendChild(empty);
    }
    for (const item of items) {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = `${item.name} (${formatSize(item.size)})`;
      button.addEventListener("click", () => {
        dvrPlayer.src = `/api/dvr/file?name=${encodeURIComponent(item.name)}`;
        dvrPlayer.play().catch(() => {});
      });
      row.appendChild(button);
      dvrList.appendChild(row);
    }
    if (data.running) showMessage("DVR recording is running.");
  } catch (error) {
    showMessage(error.message, true);
  }
}

async function startDvr() {
  try {
    await api("/api/dvr/start", {
      ip: ipInput.value.trim(),
      path: pathInput.value.trim() || "/live/ch00_0",
    });
    showMessage("DVR recording started.");
    refreshDvr();
  } catch (error) {
    showMessage(error.message, true);
  }
}

async function stopDvr() {
  try {
    await api("/api/dvr/stop", {});
    showMessage("DVR recording stopped.");
    refreshDvr();
  } catch (error) {
    showMessage(error.message, true);
  }
}

document.querySelectorAll(".light").forEach((button) => {
  button.addEventListener("click", () => setLight(button.dataset.light));
});
$("dvrStartBtn").addEventListener("click", startDvr);
$("dvrStopBtn").addEventListener("click", stopDvr);
$("dvrRefreshBtn").addEventListener("click", refreshDvr);
refreshDvr();
$("statusBtn").addEventListener("click", readLight);
$("snapshotBtn").addEventListener("click", snapshot);
$("streamBtn").addEventListener("click", startStream);
$("stopStreamBtn").addEventListener("click", stopStream);
wirePtz();
loadPrefs();
