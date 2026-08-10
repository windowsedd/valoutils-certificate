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

export function statusViewModel(data, error = null) {
  if (error || !data || typeof data !== "object") {
    return {
      state: "error",
      label: "Unavailable",
      message: "Certificate status could not be loaded. Try again later.",
      fields: {
        domain: "Not available",
        issuer: "Not available",
        validFrom: "Not available",
        expires: "Not available",
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
    fields: {
      domain: displayValue(data.domain),
      issuer: displayValue(data.issuer),
      validFrom: formatTaipei(data.valid_from),
      expires: formatTaipei(data.valid_until),
      daysRemaining: hasDays ? `${data.days_remaining} days` : "Not available",
      fingerprint: displayValue(data.fingerprint_sha256),
      lastChecked: formatTaipei(data.last_checked),
      lastRenewal: formatTaipei(data.last_renewal),
    },
  };
}

function render(model) {
  const status = document.querySelector("#status");
  status.className = `status-badge status--${model.state}`;
  status.querySelector("[data-status-label]").textContent = model.label;
  document.querySelector("#status-message").textContent = model.message;

  const fields = {
    domain: model.fields.domain,
    issuer: model.fields.issuer,
    "valid-from": model.fields.validFrom,
    expires: model.fields.expires,
    "days-remaining": model.fields.daysRemaining,
    fingerprint: model.fields.fingerprint,
    "last-checked": model.fields.lastChecked,
    "last-renewal": model.fields.lastRenewal,
  };

  for (const [id, value] of Object.entries(fields)) {
    document.getElementById(id).textContent = value;
  }
}

async function loadStatus() {
  try {
    const response = await fetch(`./cert-status.json?ts=${Date.now()}`, {
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`Status request failed with HTTP ${response.status}`);
    }
    render(statusViewModel(await response.json()));
  } catch (error) {
    render(statusViewModel(null, error));
  }
}

if (typeof document !== "undefined") {
  void loadStatus();
}
