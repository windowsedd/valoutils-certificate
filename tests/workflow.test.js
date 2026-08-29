import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const workflowUrl = new URL("../.github/workflows/certificate.yml", import.meta.url);

test("workflow supports daily and manual threshold-aware runs", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /cron:\s*["']23 4 \* \* \*["']/);
  assert.match(yaml, /workflow_dispatch:/);
  assert.match(yaml, /force_renew:[\s\S]*default:\s*false/);
  assert.match(yaml, /scripts\/certificate\.sh/);
  assert.match(yaml, /--force-renew/);

  const minute = yaml.match(/cron:\s*["'](\d+)\s/)?.[1];
  assert.notEqual(minute, "0");
});

test("workflow limits permissions and serializes certificate operations", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /concurrency:[\s\S]*certificate-status/);
  assert.match(yaml, /contents:\s*write/);
  assert.match(yaml, /pages:\s*write/);
  assert.match(yaml, /id-token:\s*write/);
});

test("workflow renews through certbot and fails visibly on errors", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /Preflight credentials/);
  assert.match(
    yaml,
    /certbot==["']?[\d.]+["']?\s+["']?certbot-dns-cloudflare==["']?[\d.]+["']?/,
  );
  assert.match(yaml, /CF_API_TOKEN:\s*\$\{\{ secrets\.CF_API_TOKEN \}\}/);
  assert.match(yaml, /LETSENCRYPT_EMAIL:\s*\$\{\{ vars\.LETSENCRYPT_EMAIL \}\}/);
  assert.match(yaml, /continue-on-error:\s*true/);
  assert.match(yaml, /steps\.certificate\.outcome == 'failure'/);
});

test("workflow commits only meaningful public certificate changes", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /git add docs\/certificate\.pem/);
  assert.match(yaml, /git diff --cached --quiet/);
  assert.match(yaml, /github-actions\[bot\]/);
  assert.doesNotMatch(yaml, /git add[^#\n]*cert-status/);
});

test("workflow republishes the PFX and deploys the generated status", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /PFX_URL:\s*https:\/\/windowsedd\.github\.io\/valoutils-certificate\/valoutils\/localhost\.pfx/);
  assert.match(yaml, /Restore published PFX/);
  assert.match(yaml, /curl[\s\S]*\$PFX_URL/);
  assert.match(yaml, /scripts\/check-pfx\.sh[\s\S]*\$DOMAIN/);
  assert.match(yaml, /steps\.pfx\.outputs\.exists/);
  assert.match(yaml, /Publish renewed PFX/);
  assert.match(yaml, /cp pfx-output\/\*\.pfx docs\/valoutils\/localhost\.pfx/);
  assert.doesNotMatch(yaml, /PFX_AGE_RECIPIENT|\.pfx\.age|actions\/upload-artifact/);
  assert.doesNotMatch(yaml, /git add[^#\n]*localhost\.pfx/);
  assert.match(yaml, /actions\/configure-pages@v5/);
  assert.match(yaml, /actions\/upload-pages-artifact@v4/);
  assert.match(yaml, /path:\s*docs/);
  assert.match(yaml, /actions\/deploy-pages@v4/);
  assert.match(yaml, /if:\s*always\(\)/);
});
