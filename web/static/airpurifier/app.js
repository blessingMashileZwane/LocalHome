const $ = (id) => document.getElementById(id);

const ip = $("ip");
const token = $("token");
const connectBtn = $("connectBtn");
const tokenHint = $("tokenHint");
const model = $("model");
const firmware = $("firmware");
const updated = $("updated");
const message = $("message");
const readings = $("readings");
const favorite = $("favorite");
const favoriteValue = $("favoriteValue");
const favoriteBtn = $("favoriteBtn");
const filterLife = $("filterLife");
const filterUsed = $("filterUsed");
const filterLeft = $("filterLeft");
const resetFilterBtn = $("resetFilterBtn");
const history = $("history");
const refreshHistoryBtn = $("refreshHistoryBtn");
const discovered = $("discovered");
const discoverBtn = $("discoverBtn");
const autoRefresh = $("autoRefresh");

const PREF_IP = "localhome.web.purifier.ip";
const MODE_LABELS = ["Auto", "Sleep", "Favorite", "Manual"];
const AIR_LABELS = [
  "Excellent",
  "Good",
  "Light",
  "Moderate",
  "Heavy",
  "Severe",
];
const SCREEN_LABELS = ["Off", "Dim", "Normal"];
const UNIT_LABELS = { 1: "Celsius", 2: "Fahrenheit" };
const KNOWN_MODELS = new Set([
  "zhimi.airp.mb5",
  "zhimi.airp.mb5a",
  "zhimi.airp.va2",
  "zhimi.airp.vb4",
  "xiaomi.airp.cpa4",
]);
const READING_ROWS = [
  ["Power", "power"],
  ["Mode", "mode"],
  ["Fan level", "fan_level"],
  ["PM2.5", "pm25", "µg/m³"],
  ["PM10", "pm10", "µg/m³"],
  ["Air quality", "air_quality"],
  ["AQI state", "aqi_state"],
  ["Temperature", "temperature", "°C"],
  ["Humidity", "humidity", "%"],
  ["Filter life", "filter_life", "%"],
  ["Average AQI", "average_aqi"],
  ["Purified volume", "purify_volume", "m³"],
  ["Motor speed", "motor_rpm", "rpm"],
];

let busy = false;
let autoTimer = null;
const state = {
  values: {},
  unsupported: new Set(),
  readOnly: false,
  properties: new Map(),
};

function formatReading(key, value) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "ON" : "OFF";
  if (key === "mode") return MODE_LABELS[value] ?? String(value);
  if (key === "air_quality" || key === "aqi_state") {
    return AIR_LABELS[value] ?? String(value);
  }
  if (key === "screen_brightness") {
    return SCREEN_LABELS[value] ?? String(value);
  }
  if (key === "temperature_unit") {
    return UNIT_LABELS[value] ?? String(value);
  }
  if (key === "fault") return value === 0 ? "None" : `Fault ${value}`;
  if (typeof value === "number" && !Number.isInteger(value)) {
    return value.toFixed(1);
  }
  return String(value);
}

function showMessage(text, error = false) {
  message.textContent = text;
  message.classList.toggle("error", error);
}

function savePrefs() {
  try {
    localStorage.setItem(PREF_IP, ip.value.trim());
  } catch (_) {
    // Storage can be unavailable in private mode.
  }
}

function loadPrefs() {
  try {
    const saved = localStorage.getItem(PREF_IP);
    if (saved) ip.value = saved;
  } catch (_) {
    // Storage can be unavailable in private mode.
  }
}

function requestBody(extra = {}) {
  const body = { ip: ip.value.trim(), ...extra };
  const value = token.value.trim();
  if (value) body.token = value;
  return body;
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
    // Keep the status code when the body is not JSON.
  }
  if (!response.ok) {
    throw new Error(data.error || `Request failed (${response.status})`);
  }
  return data;
}

async function getJson(path) {
  const response = await fetch(path);
  let data = {};
  try {
    data = await response.json();
  } catch (_) {
    // Keep the status code when the body is not JSON.
  }
  if (!response.ok) {
    throw new Error(data.error || `Request failed (${response.status})`);
  }
  return data;
}

function setBusy(value) {
  busy = value;
  connectBtn.disabled = value;
  discoverBtn.disabled = value;
  refreshHistoryBtn.disabled = value;
  resetFilterBtn.disabled = value;
  renderControls();
}

function renderReadings() {
  readings.innerHTML = "";
  for (const [label, key, unit] of READING_ROWS) {
    if (!(key in state.values) && !state.unsupported.has(key)) continue;
    const row = document.createElement("div");
    const term = document.createElement("dt");
    term.textContent = label;
    const value = document.createElement("dd");
    if (state.unsupported.has(key)) {
      value.textContent = "unsupported";
    } else {
      const raw = state.values[key];
      const formatted = formatReading(key, raw);
      value.textContent =
        unit && raw !== null && raw !== undefined
          ? `${formatted} ${unit}`
          : formatted;
    }
    row.append(term, value);
    readings.appendChild(row);
  }
  if (!readings.children.length) {
    const row = document.createElement("div");
    const term = document.createElement("dt");
    term.textContent = "No values";
    const value = document.createElement("dd");
    value.textContent = "—";
    row.append(term, value);
    readings.appendChild(row);
  }
}

function mark(selector, key, isActive) {
  document.querySelectorAll(selector).forEach((button) => {
    button.classList.toggle("active", isActive(button));
    button.disabled =
      busy ||
      state.readOnly ||
      !state.properties.has(key) ||
      state.unsupported.has(key);
  });
}

function renderControls() {
  const values = state.values;
  const props = state.properties;

  document.querySelectorAll("[data-control]").forEach((element) => {
    element.hidden = !props.has(element.dataset.control);
  });

  const modeProp = props.get("mode");
  const modeMax = modeProp ? Number(modeProp.maximum ?? 3) : 3;
  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.hidden = Number(button.dataset.mode) > modeMax;
  });

  mark("[data-power]", "power",
    (b) => values.power === (b.dataset.power === "true"));
  mark("[data-mode]", "mode",
    (b) => values.mode === Number(b.dataset.mode));
  mark("[data-fan]", "fan_level",
    (b) => values.fan_level === Number(b.dataset.fan));
  mark("[data-anion]", "anion",
    (b) => values.anion === (b.dataset.anion === "true"));
  mark("[data-child]", "child_lock",
    (b) => values.child_lock === (b.dataset.child === "true"));
  mark("[data-alarm]", "alarm",
    (b) => values.alarm === (b.dataset.alarm === "true"));
  mark("[data-screen]", "screen_brightness",
    (b) => values.screen_brightness === Number(b.dataset.screen));
  mark("[data-unit]", "temperature_unit",
    (b) => values.temperature_unit === Number(b.dataset.unit));

  const favoriteProp = props.get("favorite_level");
  const favoriteMax = favoriteProp ? Number(favoriteProp.maximum ?? 11) : 11;
  favorite.max = favoriteMax;
  if (Number(favorite.value) > favoriteMax) favorite.value = favoriteMax;
  const favoriteDisabled =
    busy ||
    state.readOnly ||
    !favoriteProp ||
    state.unsupported.has("favorite_level");
  favorite.disabled = favoriteDisabled;
  favoriteBtn.disabled = favoriteDisabled;
  resetFilterBtn.disabled = busy || state.readOnly;
  if (typeof values.favorite_level === "number") {
    favorite.value = values.favorite_level;
    favoriteValue.textContent = values.favorite_level;
  } else {
    favoriteValue.textContent = "—";
  }
}

function applyStatus(data) {
  state.values = data.values || {};
  state.unsupported = new Set(data.unsupported || []);
  state.properties = new Map(
    (data.properties || []).map((property) => [property.name, property]),
  );
  state.readOnly = !KNOWN_MODELS.has(data.model);
  model.textContent = data.model
    ? `${data.model}${state.readOnly ? " (read-only)" : ""}`
    : "—";
  firmware.textContent = data.firmware || "—";
  updated.textContent = data.received_at
    ? `Updated ${new Date(data.received_at * 1000).toLocaleTimeString()}`
    : "—";
  filterLife.textContent = state.values.filter_life ?? "—";
  filterUsed.textContent = state.values.filter_used_time ?? "—";
  filterLeft.textContent = state.values.filter_left_time ?? "—";
  renderReadings();
  renderControls();
}

async function refresh(silent = false) {
  if (busy) return;
  if (!ip.value.trim()) {
    showMessage("Enter the purifier's private IPv4 address.", true);
    return;
  }
  savePrefs();
  setBusy(true);
  try {
    const data = await api("/api/purifier/status", requestBody());
    applyStatus(data);
    if (!silent) showMessage("Status updated.");
    loadHistory();
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(false);
  }
}

async function setControl(name, value, confirmText) {
  if (busy) return;
  if (!ip.value.trim()) {
    showMessage("Enter the purifier's private IPv4 address.", true);
    return;
  }
  if (confirmText && !window.confirm(confirmText)) return;
  savePrefs();
  setBusy(true);
  try {
    const data = await api("/api/purifier/set", requestBody({ name, value }));
    applyStatus(data);
    if (data.applied === false) {
      showMessage(data.error || "The purifier did not apply that change.", true);
    } else {
      showMessage(`${name} updated.`);
    }
    loadHistory();
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(false);
  }
}

async function resetFilter() {
  if (busy) return;
  if (!ip.value.trim()) {
    showMessage("Enter the purifier's private IPv4 address.", true);
    return;
  }
  if (!window.confirm("Reset the filter counter? This cannot be undone.")) {
    return;
  }
  savePrefs();
  setBusy(true);
  try {
    const data = await api(
      "/api/purifier/filter/reset",
      requestBody({ confirm: true }),
    );
    applyStatus(data);
    if (data.applied === false) {
      showMessage(
        data.error || "The purifier did not reset the filter counter.",
        true,
      );
    } else {
      showMessage("Filter counter reset.");
    }
    loadHistory();
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(false);
  }
}

function renderHistory(items) {
  history.innerHTML = "";
  const rows = Array.isArray(items) ? items.slice().reverse() : [];
  if (!rows.length) {
    const item = document.createElement("li");
    item.textContent = "No readings yet.";
    history.appendChild(item);
    return;
  }
  for (const reading of rows) {
    const values = reading.values || {};
    const item = document.createElement("li");
    const when = reading.ts
      ? new Date(reading.ts * 1000).toLocaleString()
      : "—";
    const pm = values.pm25 ?? "—";
    const temp = values.temperature ?? "—";
    const humidity = values.humidity ?? "—";
    const life = values.filter_life ?? "—";
    item.textContent = `${when} · PM2.5 ${pm} · ${temp} °C · ${humidity} % · filter ${life} %`;
    history.appendChild(item);
  }
}

async function loadHistory() {
  try {
    const data = await getJson("/api/purifier/history?limit=20");
    renderHistory(data.readings || []);
  } catch (_) {
    // History is optional; do not replace the main status message.
  }
}

async function loadConfig() {
  try {
    const data = await getJson("/api/purifier/config");
    tokenHint.textContent = data.token_configured
      ? "A token is configured on this server; leave the token field blank."
      : "No server token configured; enter the device token (32 hex chars).";
  } catch (_) {
    tokenHint.textContent = "";
  }
}

async function discoverPurifiers() {
  if (busy) return;
  setBusy(true);
  discovered.innerHTML = "";
  try {
    const data = await getJson("/api/purifier/discover?timeout=3");
    const devices = data.devices || [];
    if (!devices.length) {
      const item = document.createElement("li");
      item.textContent = "No purifier answered the broadcast.";
      discovered.appendChild(item);
      showMessage("No purifier found; enter its address manually.", true);
      return;
    }
    for (const device of devices) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = device.address;
      button.addEventListener("click", () => {
        ip.value = device.address;
        savePrefs();
        showMessage(`Selected ${device.address}.`);
      });
      item.appendChild(button);
      discovered.appendChild(item);
    }
    showMessage(`Found ${devices.length} address(es).`);
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(false);
  }
}

function scheduleAutoRefresh() {
  if (autoTimer) {
    clearInterval(autoTimer);
    autoTimer = null;
  }
  if (!autoRefresh.checked) return;
  autoTimer = setInterval(() => {
    if (
      document.visibilityState === "visible" &&
      !busy &&
      ip.value.trim() &&
      Object.keys(state.values).length
    ) {
      refresh(true);
    }
  }, 15000);
}

function wire() {
  connectBtn.addEventListener("click", () => {
    savePrefs();
    refresh();
  });
  ip.addEventListener("change", savePrefs);

  document.querySelectorAll("[data-power]").forEach((button) => {
    button.addEventListener("click", () => {
      const value = button.dataset.power === "true";
      setControl("power", value, value ? undefined : "Turn the purifier off?");
    });
  });
  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("mode", Number(button.dataset.mode));
    });
  });
  document.querySelectorAll("[data-fan]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("fan_level", Number(button.dataset.fan));
    });
  });
  favoriteBtn.addEventListener("click", () => {
    setControl("favorite_level", Number(favorite.value));
  });
  document.querySelectorAll("[data-anion]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("anion", button.dataset.anion === "true");
    });
  });
  document.querySelectorAll("[data-child]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("child_lock", button.dataset.child === "true");
    });
  });
  document.querySelectorAll("[data-alarm]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("alarm", button.dataset.alarm === "true");
    });
  });
  document.querySelectorAll("[data-screen]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("screen_brightness", Number(button.dataset.screen));
    });
  });
  document.querySelectorAll("[data-unit]").forEach((button) => {
    button.addEventListener("click", () => {
      setControl("temperature_unit", Number(button.dataset.unit));
    });
  });
  resetFilterBtn.addEventListener("click", resetFilter);
  refreshHistoryBtn.addEventListener("click", loadHistory);
  discoverBtn.addEventListener("click", discoverPurifiers);
  autoRefresh.addEventListener("change", scheduleAutoRefresh);
}

loadPrefs();
loadConfig();
loadHistory();
wire();
renderControls();
