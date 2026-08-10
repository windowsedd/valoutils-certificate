import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { formatTaipei, statusViewModel } from "../docs/script.js";

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
});

test("page contains every certificate field and accessible live status", async () => {
  const html = await readFile(new URL("../docs/index.html", import.meta.url), "utf8");
  for (const id of [
    "domain",
    "status",
    "issuer",
    "valid-from",
    "expires",
    "days-remaining",
    "fingerprint",
    "last-checked",
    "last-renewal",
  ]) {
    assert.match(html, new RegExp(`id=["']${id}["']`));
  }
  assert.match(html, /aria-live=["']polite["']/);
  assert.match(html, /certificate\.pem/);
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
});
