import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("README documents setup, automation, and the public PFX risk", async () => {
  const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");
  for (const required of [
    "CF_API_TOKEN",
    "LETSENCRYPT_EMAIL",
    "Zone → DNS → Edit",
    "force_renew",
    "3 days",
    "DNS-01",
    "docs/certificate.pem",
    "docs/cert-status.json",
    "https://windowsedd.github.io/valoutils-certificate/valoutils/localhost.pfx",
    "localhost.pfx",
    "GitHub Actions",
  ]) {
    assert.ok(readme.includes(required), `README is missing: ${required}`);
  }
  assert.match(readme, /empty password/i);
  assert.match(readme, /private key/i);
  assert.match(readme, /anyone.*download/i);
  assert.doesNotMatch(readme, /PFX_AGE_RECIPIENT|age --decrypt|\.pfx\.age/);
});
