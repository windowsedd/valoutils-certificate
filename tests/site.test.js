import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  formatTaipei,
  lifePercentRemaining,
  statusViewModel,
} from "../docs/script.js";

test("maps certificate states to clear text labels", () => {
  assert.equal(statusViewModel({ status: "valid", days_remaining: 89 }).label, "Valid");
  assert.equal(statusViewModel({ status: "renewal-soon" }).label, "Renewal due");
  assert.equal(statusViewModel({ status: "expired" }).label, "Expired");
  assert.equal(statusViewModel({ status: "error" }).label, "Check failed");
});

test("returns an unavailable model when loading fails", () => {
  const model = statusViewModel(null, new Error("offline"));
  assert.equal(model.state, "error");
  assert.equal(model.label, "Unavailable");
  assert.match(model.message, /could not be loaded/i);
});

test("formats UTC timestamps for Asia Taipei", () => {
  assert.match(formatTaipei("2026-08-10T04:40:00Z"), /UTC\+8/);
  assert.equal(formatTaipei(""), "Not available");
  assert.equal(formatTaipei("invalid"), "Not available");
});

test("normalizes missing fields without hiding zero days", () => {
  const model = statusViewModel({ status: "expired", days_remaining: 0 });
  assert.equal(model.fields.daysRemaining, "0 days");
  assert.equal(model.fields.issuer, "Not available");
  assert.equal(model.fields.fingerprint, "Not available");
  assert.equal(model.fields.san, "Not available");
  assert.equal(model.fields.keyAlgorithm, "Not available");
});

test("joins SAN entries and keeps the key algorithm", () => {
  const model = statusViewModel({
    status: "valid",
    days_remaining: 89,
    san: ["valoutils-localhost.windowsed.me", "alt.windowsed.me"],
    key_algorithm: "RSA 2048",
  });
  assert.equal(model.fields.san, "valoutils-localhost.windowsed.me, alt.windowsed.me");
  assert.equal(model.fields.keyAlgorithm, "RSA 2048");
});

test("computes the remaining certificate lifetime percentage", () => {
  const now = Date.parse("2026-09-07T00:00:00Z");
  const data = {
    valid_from: "2026-08-09T00:00:00Z",
    valid_until: "2026-11-07T00:00:00Z",
    days_remaining: 61,
  };
  // 61 of 90 days remain.
  assert.equal(lifePercentRemaining(data, now), 68);
  assert.equal(lifePercentRemaining({}, now), null);
  assert.equal(
    lifePercentRemaining({ valid_from: "bogus", valid_until: "bogus" }, now),
    null,
  );
  // Past the end of life the percentage clamps to zero.
  assert.equal(lifePercentRemaining(data, Date.parse("2026-12-01T00:00:00Z")), 0);
});

test("page contains every certificate field and accessible live status", async () => {
  const html = await readFile(new URL("../docs/index.html", import.meta.url), "utf8");
  for (const id of [
    "domain",
    "status",
    "issuer",
    "key-algorithm",
    "valid-from",
    "expires",
    "san",
    "days-remaining",
    "fingerprint",
    "last-checked",
    "last-renewal",
  ]) {
    assert.match(html, new RegExp(`id=["']${id}["']`));
  }
  assert.match(html, /aria-live=["']polite["']/);
  assert.match(html, /certificate\.pem/);
  assert.match(html, /data-lifecycle-fill/);
  assert.match(html, /data-pfx-link/);
  assert.match(html, /href=["']\.\/valoutils\/localhost\.pfx["']/);
});

test("styles support themes, state classes, focus, and mobile layout", async () => {
  const css = await readFile(new URL("../docs/style.css", import.meta.url), "utf8");
  assert.match(css, /prefers-color-scheme:\s*dark/);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(css, /@media\s*\([^)]*max-width/);
  assert.match(css, /:focus-visible/);
  for (const state of ["valid", "renewal-soon", "expired", "error"]) {
    assert.match(css, new RegExp(`\\.status--${state}`));
  }
  assert.match(css, /\.lifecycle-fill/);
});
