const STATE_LABELS = Object.freeze({
  valid: "Valid",
  "renewal-soon": "Renewal due",
  expired: "Expired",
  error: "Check failed",
});

const STATE_MESSAGES = Object.freeze({
  valid: "The certificate is active and does not require renewal.",
  "renewal-soon": "The certificate has reached the renewal window.",
  expired: "The certificate is no longer valid.",
  error: "The latest automated certificate check failed.",
});

function displayValue(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "Not available";
}

function displayList(value) {
  return Array.isArray(value) && value.length > 0 ? value.join(", ") : "Not available";
}

export function formatTaipei(iso) {
  if (!iso || Number.isNaN(Date.parse(iso))) {
    return "Not available";
  }

  const formatted = new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    timeZone: "Asia/Taipei",
    timeZoneName: "shortOffset",
    hourCycle: "h23",
  }).format(new Date(iso));

  return formatted.replace("GMT+8", "UTC+8");
}

function formatShortTaipei(iso) {
  if (!iso || Number.isNaN(Date.parse(iso))) {
    return null;
  }
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    timeZone: "Asia/Taipei",
  }).format(new Date(iso));
}

// Percentage of the certificate lifetime still ahead, based on the current
// moment and the validity window in the status data. Returns null when the
// window is missing or malformed.
export function lifePercentRemaining(data, nowMs = Date.now()) {
  if (!data || typeof data !== "object") {
    return null;
  }
  const start = Date.parse(data.valid_from);
  const end = Date.parse(data.valid_until);
  if (Number.isNaN(start) || Number.isNaN(end) || end <= start) {
    return null;
  }
  const percent = Math.round(((end - nowMs) / (end - start)) * 100);
  return Math.min(100, Math.max(0, percent));
}

export function statusViewModel(data, error = null) {
  if (error || !data || typeof data !== "object") {
    return {
      state: "error",
      label: "Unavailable",
      message: "Certificate status could not be loaded. Try again later.",
      lifePercent: null,
      fields: {
        domain: "Not available",
        issuer: "Not available",
        keyAlgorithm: "Not available",
        validFrom: "Not available",
        expires: "Not available",
        san: "Not available",
        daysRemaining: "Not available",
        fingerprint: "Not available",
        lastChecked: "Not available",
        lastRenewal: "Not available",
      },
    };
  }

  const state = Object.hasOwn(STATE_LABELS, data.status) ? data.status : "error";
  const hasDays = Number.isFinite(data.days_remaining);

  return {
    state,
    label: STATE_LABELS[state],
    message: STATE_MESSAGES[state],
    lifePercent: lifePercentRemaining(data),
    fields: {
      domain: displayValue(data.domain),
      issuer: displayValue(data.issuer),
      keyAlgorithm: displayValue(data.key_algorithm),
      validFrom: formatTaipei(data.valid_from),
      expires: formatTaipei(data.valid_until),
      san: displayList(data.san),
      daysRemaining: hasDays ? `${data.days_remaining} days` : "Not available",
      fingerprint: displayValue(data.fingerprint_sha256),
      lastChecked: formatTaipei(data.last_checked),
      lastRenewal: formatTaipei(data.last_renewal),
    },
  };
}

function renderLifecycle(model, data) {
  const section = document.querySelector("#lifecycle");
  const fill = section?.querySelector("[data-lifecycle-fill]");
  const caption = section?.querySelector("[data-lifecycle-caption]");
  const start = section?.querySelector("[data-lifecycle-start]");
  const end = section?.querySelector("[data-lifecycle-end]");

  if (!section || !fill || !caption || !start || !end) {
    return;
  }

  section.dataset.state = model.state;

  if (model.lifePercent === null) {
    fill.style.width = "0%";
    caption.textContent = "Remaining lifetime is unavailable.";
  } else {
    fill.style.width = `${model.lifePercent}%`;
    const days = Number.isFinite(data?.days_remaining) ? data.days_remaining : null;
    caption.textContent =
      days === null
        ? `${model.lifePercent}% of the certificate lifetime remaining.`
        : `${days} days remaining — ${model.lifePercent}% of the certificate lifetime.`;
  }

  const startLabel = formatShortTaipei(data?.valid_from);
  const endLabel = formatShortTaipei(data?.valid_until);
  start.textContent = startLabel ?? "Not available";
  end.textContent = endLabel ?? "Not available";
}

function render(model, data) {
  const status = document.querySelector("#status");
  status.className = `status-badge status--${model.state}`;
  status.querySelector("[data-status-label]").textContent = model.label;
  document.querySelector("#status-message").textContent = model.message;
  document.body.dataset.state = model.state;

  const fields = {
    domain: model.fields.domain,
    issuer: model.fields.issuer,
    "key-algorithm": model.fields.keyAlgorithm,
    "valid-from": model.fields.validFrom,
    expires: model.fields.expires,
    san: model.fields.san,
    "days-remaining": model.fields.daysRemaining,
    fingerprint: model.fields.fingerprint,
    "last-checked": model.fields.lastChecked,
    "last-renewal": model.fields.lastRenewal,
  };

  for (const [id, value] of Object.entries(fields)) {
    document.getElementById(id).textContent = value;
  }

  renderLifecycle(model, data);
}

// The PFX download only exists after the first successful issuance; hide the
// link when it is not (yet) published instead of leading to a 404 page.
async function loadPfxAvailability() {
  const link = document.querySelector("[data-pfx-link]");
  if (!link) {
    return;
  }
  try {
    const response = await fetch("./valoutils/localhost.pfx", { method: "HEAD" });
    link.hidden = !response.ok;
  } catch {
    link.hidden = true;
  }
}

async function loadStatus() {
  void loadPfxAvailability();
  try {
    const response = await fetch(`./cert-status.json?ts=${Date.now()}`, {
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`Status request failed with HTTP ${response.status}`);
    }
    const data = await response.json();
    render(statusViewModel(data), data);
  } catch (error) {
    render(statusViewModel(null, error), null);
  }
}

if (typeof document !== "undefined") {
  void loadStatus();
}
