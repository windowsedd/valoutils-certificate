import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const workflowUrl = new URL("../.github/workflows/certificate.yml", import.meta.url);

test("workflow supports daily and manual threshold-aware runs", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /cron:\s*["']23 4 \* \* \*["']/);
  assert.match(yaml, /workflow_dispatch:/);
  assert.match(yaml, /force_renew:[\s\S]*default:\s*false/);
  assert.match(yaml, /scripts\/check-cert\.sh/);
  assert.match(yaml, /steps\.inspect\.outputs\.renew/);

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

test("workflow renews, records failure status, and commits only public files", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /scripts\/renew-cert\.sh/);
  assert.match(yaml, /scripts\/generate-status\.sh/);
  assert.match(yaml, /CF_API_TOKEN:\s*\$\{\{ secrets\.CF_API_TOKEN \}\}/);
  assert.match(yaml, /LETSENCRYPT_EMAIL:\s*\$\{\{ vars\.LETSENCRYPT_EMAIL \}\}/);
  assert.match(yaml, /PFX_AGE_RECIPIENT:\s*\$\{\{ vars\.PFX_AGE_RECIPIENT \}\}/);
  assert.match(yaml, /github-actions\[bot\]/);
  assert.match(yaml, /git add docs\/certificate\.pem docs\/cert-status\.json/);
  assert.match(yaml, /git diff --cached --quiet/);
  assert.match(yaml, /Report renewal failure/);
});

test("workflow uploads only encrypted PFX and deploys Pages after failures", async () => {
  const yaml = await readFile(workflowUrl, "utf8");
  assert.match(yaml, /actions\/upload-artifact@v7/);
  assert.match(yaml, /valoutils-tools\.windowsed\.me\.pfx\.age/);
  assert.match(yaml, /retention-days:\s*7/);
  assert.doesNotMatch(yaml, /path:\s*[^\n]*\.pfx\s*$/m);
  assert.match(yaml, /actions\/configure-pages@v5/);
  assert.match(yaml, /actions\/upload-pages-artifact@v4/);
  assert.match(yaml, /actions\/deploy-pages@v4/);
  assert.match(yaml, /if:\s*always\(\)/);
});
