"use strict";

const IP_STORAGE = "localhome.web.hinen.ip";

const $ = (id) => document.getElementById(id);

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) {
    node.textContent = String(text);
  }
  if (className) {
    node.className = className;
  }
  return node;
}

function setMessage(text, kind) {
  const message = $("message");
  message.textContent = text || "";
  message.className = `message ${kind || ""}`.trim();
}

function setBusy(button, busy) {
  if (busy) {
    button.dataset.label = button.dataset.label || button.textContent;
    button.disabled = true;
    button.textContent = "Working…";
    return;
  }
  button.disabled = false;
  if (button.dataset.label) {
    button.textContent = button.dataset.label;
  }
}

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.error || `request failed (${response.status})`);
  }
  return data;
}

function ipValue() {
  const value = $("ip").value.trim();
  if (!value) {
    throw new Error("Enter the station's private IPv4 address.");
  }
  return value;
}

function rememberIp() {
  try {
    localStorage.setItem(IP_STORAGE, $("ip").value.trim());
  } catch (error) {
    // Private browsing may reject storage; the panel still works.
  }
}

function restoreIp() {
  try {
    const saved = localStorage.getItem(IP_STORAGE);
    if (saved) {
      $("ip").value = saved;
    }
  } catch (error) {
    // Ignore storage failures.
  }
}

function emptyRow(tbody, columns, text) {
  const row = document.createElement("tr");
  const cell = el("td", text, "empty");
  cell.colSpan = columns;
  row.append(cell);
  tbody.replaceChildren(row);
}

function renderDevices(payload) {
  const tbody = $("devices");
  const devices = payload.devices || [];
  if (!devices.length) {
    emptyRow(tbody, 6, "No Tuya device answered. Check the Wi-Fi network and retry.");
    return;
  }
  tbody.replaceChildren();
  for (const device of devices) {
    const row = document.createElement("tr");
    row.append(
      el("td", device.address),
      el("td", device.product_key || "—"),
      el("td", device.version || "—"),
      el("td", String(device.active)),
      el("td", device.encrypted ? "yes" : "no"),
      el("td", device.device_id_prefix || "—"),
    );
    tbody.append(row);
  }
  if (devices.length === 1) {
    $("ip").value = devices[0].address;
    rememberIp();
  }
}

function renderPorts(ports) {
  const wrap = document.createElement("div");
  wrap.append(el("h3", "Ports"));
  const table = document.createElement("table");
  const head = document.createElement("thead");
  const headRow = document.createElement("tr");
  headRow.append(el("th", "Port"), el("th", "State"));
  head.append(headRow);
  const body = document.createElement("tbody");
  for (const [port, open] of Object.entries(ports)) {
    const row = document.createElement("tr");
    row.append(
      el("td", port),
      el("td", open ? "open" : "closed", open ? "state-open" : "state-closed"),
    );
    body.append(row);
  }
  table.append(head, body);
  wrap.append(table);
  return wrap;
}

function renderJson(title, value) {
  const wrap = document.createElement("div");
  wrap.append(el("h3", title));
  const pre = el("pre", JSON.stringify(value, null, 2));
  wrap.append(pre);
  return wrap;
}

function renderLan(payload) {
  const container = $("lan");
  container.replaceChildren(
    renderPorts(payload.ports || {}),
    renderJson("HTTP", payload.http || {}),
    renderJson("TLS", payload.tls || {}),
    renderJson("SSDP", payload.ssdp || []),
    renderJson("mDNS", payload.mdns || {}),
  );
}

function formatValue(value) {
  if (typeof value === "string") {
    return value;
  }
  if (value === null) {
    return "null";
  }
  return JSON.stringify(value);
}

function renderDps(payload) {
  const tbody = $("dps");
  const dps = payload.dps || {};
  const keys = Object.keys(dps).sort((a, b) => {
    const left = Number(a);
    const right = Number(b);
    if (Number.isFinite(left) && Number.isFinite(right)) {
      return left - right;
    }
    return a.localeCompare(b);
  });
  if (!keys.length) {
    emptyRow(tbody, 2, "The station returned no data points.");
    return;
  }
  tbody.replaceChildren();
  for (const key of keys) {
    const row = document.createElement("tr");
    row.append(el("td", key), el("td", formatValue(dps[key])));
    tbody.append(row);
  }
  const received = payload.received_at
    ? new Date(payload.received_at * 1000).toLocaleString()
    : "unknown";
  $("received").textContent = `Received ${received} from ${payload.address}.`;
}

function renderBle(payload) {
  const container = $("ble-result");
  const devices = payload.devices || [];
  const wrap = document.createElement("div");
  if (!devices.length) {
    wrap.append(
      el(
        "p",
        payload.note ||
          "No BLE advertisements found. The station appears to use Wi-Fi/cloud.",
        "empty",
      ),
    );
  } else {
    const table = document.createElement("table");
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    headRow.append(
      el("th", "Name"),
      el("th", "Address"),
      el("th", "RSSI"),
      el("th", "Services"),
    );
    head.append(headRow);
    const body = document.createElement("tbody");
    for (const device of devices) {
      const row = document.createElement("tr");
      row.append(
        el("td", device.name || "—"),
        el("td", device.address),
        el("td", device.rssi ?? "—"),
        el("td", (device.service_uuids || []).join(", ") || "—"),
      );
      body.append(row);
    }
    table.append(head, body);
    wrap.append(table);
  }
  if (payload.note && devices.length) {
    wrap.append(el("p", payload.note, "muted"));
  }
  container.replaceChildren(wrap);
}

async function loadConfig() {
  try {
    const response = await fetch("/api/hinen/config");
    const config = await response.json();
    const parts = [];
    parts.push(
      config.local_key_configured
        ? "Local key loaded from the protected env file."
        : "No local key in the protected env file; enter it above for a one-off read.",
    );
    if (!config.tinytuya_available) {
      parts.push("Tuya discovery needs tinytuya.");
    }
    if (!config.bleak_available) {
      parts.push("BLE scan needs bleak.");
    }
    $("config").textContent = parts.join(" ");
  } catch (error) {
    $("config").textContent = "Could not read the panel configuration.";
  }
}

async function findDevice() {
  const button = $("find");
  setBusy(button, true);
  setMessage("Scanning the private network for Tuya devices…");
  try {
    const payload = await api("/api/hinen/discover", { timeout: 8 });
    renderDevices(payload);
    const count = (payload.devices || []).length;
    setMessage(
      count
        ? `Found ${count} Tuya device${count === 1 ? "" : "s"}.`
        : "No Tuya device answered.",
      count ? "ok" : "error",
    );
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    setBusy(button, false);
  }
}

async function checkLan() {
  const button = $("check");
  let ip;
  try {
    ip = ipValue();
  } catch (error) {
    setMessage(error.message, "error");
    return;
  }
  rememberIp();
  setBusy(button, true);
  setMessage("Checking the station's local services…");
  try {
    const payload = await api("/api/hinen/check", { ip });
    renderLan(payload);
    const open = Object.entries(payload.ports || {})
      .filter(([, value]) => value)
      .map(([port]) => port);
    setMessage(
      open.length ? `Open ports: ${open.join(", ")}.` : "No local ports open.",
      open.length ? "ok" : "",
    );
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    setBusy(button, false);
  }
}

async function readStatus() {
  const button = $("status");
  let ip;
  try {
    ip = ipValue();
  } catch (error) {
    setMessage(error.message, "error");
    return;
  }
  rememberIp();
  const body = { ip };
  const key = $("key").value.trim();
  if (key) {
    body.key = key;
  }
  setBusy(button, true);
  setMessage("Reading data points (read-only)…");
  try {
    const payload = await api("/api/hinen/status", body);
    renderDps(payload);
    setMessage("Read-only data points received.", "ok");
  } catch (error) {
    setMessage(error.message, "error");
    $("received").textContent = "";
  } finally {
    setBusy(button, false);
  }
}

async function scanBle() {
  const button = $("ble");
  setBusy(button, true);
  setMessage("Scanning BLE advertisements (read-only)…");
  try {
    const payload = await api("/api/hinen/ble/scan", { timeout: 8 });
    renderBle(payload);
    const count = (payload.devices || []).length;
    setMessage(
      count
        ? `Found ${count} BLE advertisement${count === 1 ? "" : "s"}.`
        : "No BLE advertisements found.",
      count ? "ok" : "",
    );
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    setBusy(button, false);
  }
}

$("find").addEventListener("click", findDevice);
$("check").addEventListener("click", checkLan);
$("status").addEventListener("click", readStatus);
$("ble").addEventListener("click", scanBle);
$("device-form").addEventListener("submit", (event) => {
  event.preventDefault();
  readStatus();
});
$("ip").addEventListener("change", rememberIp);

restoreIp();
loadConfig();
