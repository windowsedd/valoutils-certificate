import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("README documents setup, automation, and the security boundaries", async () => {
  const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");
  for (const required of [
    "valoutils-tools.windowsed.me",
    "CF_API_TOKEN",
    "LETSENCRYPT_EMAIL",
    ".secrets/cloudflare.ini",
    "dns_cloudflare_api_token",
    "Zone → DNS → Edit",
    "force_renew",
    "30 days",
    "DNS-01",
    "scripts/certificate.sh",
    "scripts/verify.sh",
    "docs/certificate.pem",
    "docs/cert-status.json",
    "pfx-output/valoutils-tools.windowsed.me.pfx",
    "https://valoutils-tools.windowsed.me/valoutils/localhost.pfx",
    "localhost.pfx",
    "letsencrypt/config",
    "GitHub Actions",
    "Troubleshooting",
  ]) {
    assert.ok(readme.includes(required), `README is missing: ${required}`);
  }
  assert.match(readme, /empty password/i);
  assert.match(readme, /private key/i);
  assert.match(readme, /CRLF/i);
  assert.match(readme, /anyone/i);
});

test("README keeps private material out of Git and avoids unsafe mechanisms", async () => {
  const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");
  assert.doesNotMatch(readme, /windowsedd\.github\.io/);
  assert.doesNotMatch(readme, /\/etc\/letsencrypt/);
  assert.doesNotMatch(readme, /PFX_AGE_RECIPIENT|age --decrypt|\.pfx\.age/);
});
