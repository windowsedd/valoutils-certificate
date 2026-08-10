# ValoUtils Certificate Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone GitHub Pages repository that checks and renews the TLS certificate for `valoutils-tools.windowsed.me` through Let's Encrypt and Cloudflare DNS-01.

**Architecture:** Focused Bash scripts inspect, renew, validate, and serialize certificate state. One scheduled/manual GitHub Actions workflow runs those scripts, commits public outputs, uploads an age-encrypted PFX artifact after renewal, and deploys the static `docs/` site through GitHub Pages.

**Tech Stack:** Bash 4+, OpenSSL 3, jq, Certbot 5.7.0, certbot-dns-cloudflare 5.7.0, age, HTML, CSS, JavaScript, Node.js 24 test runner, GitHub Actions, GitHub Pages

## Global Constraints

- Manage only `valoutils-tools.windowsed.me`.
- Use Let's Encrypt production issuance with Cloudflare DNS-01; never use HTTP-01.
- Renew when the certificate is missing, malformed, expired, hostname-mismatched, forced, or has 30 days or less remaining.
- Store UTC timestamps as ISO-8601 strings and display them in `Asia/Taipei`.
- Keep the last valid `docs/certificate.pem` when renewal fails.
- Never commit or publish a private key, raw PFX, PKCS#12 file, Cloudflare credential file, or Certbot state.
- The PFX must include the private key and full chain, use an empty internal password, carry the hostname alias, and reopen successfully before encryption.
- Encrypt the PFX to `PFX_AGE_RECIPIENT` and upload only the `.pfx.age` result with seven-day retention.
- Every Bash entry point starts with `set -euo pipefail`.
- The workflow runs daily at minute 23 and supports `workflow_dispatch` with `force_renew=false`.

---

## File map

- `scripts/check-cert.sh`: inspect a public certificate and print one JSON decision object.
- `scripts/generate-status.sh`: create `docs/cert-status.json` atomically while preserving `last_renewal`.
- `scripts/renew-cert.sh`: issue into temporary storage, validate all outputs, create and encrypt the PFX, then replace the public certificate.
- `docs/index.html`: semantic status-page shell.
- `docs/style.css`: responsive light/dark visual system and state colors.
- `docs/script.js`: fetch, normalize, format, and render status data.
- `tests/helpers.sh`: assertion helpers and temporary CA/leaf generation.
- `tests/check-cert.test.sh`: inspection and threshold cases.
- `tests/generate-status.test.sh`: JSON and timestamp cases.
- `tests/renew-cert.test.sh`: mocked Certbot/age success and failure cases.
- `tests/site.test.js`: frontend model, markup, and failure-state cases.
- `tests/workflow.test.js`: static contract checks for the Actions workflow.
- `tests/run.sh`: complete local test entry point.
- `.github/workflows/certificate.yml`: test, check, conditional renewal, commit, artifact, failure reporting, and Pages deployment.
- `.gitignore`: private-material and local-tool exclusions.
- `README.md`: setup, operation, security, PFX recovery, and troubleshooting.

---

### Task 1: Certificate inspection and threshold decisions

**Files:**
- Create: `tests/helpers.sh`
- Create: `tests/check-cert.test.sh`
- Create: `scripts/check-cert.sh`

**Interfaces:**
- Consumes: `scripts/check-cert.sh CERTIFICATE_PATH EXPECTED_DOMAIN`
- Consumes: optional `CHECK_NOW_EPOCH` for deterministic expiry tests.
- Produces: JSON with `parseable`, `hostname_valid`, `currently_valid`, `expired`, `days_remaining`, `renewal_required`, and `reason`.

- [ ] **Step 1: Add certificate fixture and assertion helpers**

Create `tests/helpers.sh` with strict mode, `assert_eq`, `assert_file_exists`, and this reusable chain generator:

```bash
make_chain() {
  local output_dir="$1" domain="$2" days="$3"
  mkdir -p "$output_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=ValoUtils Test CA" \
    -keyout "$output_dir/ca.key" -out "$output_dir/ca.pem" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$output_dir/privkey.pem" -out "$output_dir/leaf.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$domain" > "$output_dir/extensions.cnf"
  openssl x509 -req -in "$output_dir/leaf.csr" -CA "$output_dir/ca.pem" \
    -CAkey "$output_dir/ca.key" -CAcreateserial -days "$days" \
    -extfile "$output_dir/extensions.cnf" -out "$output_dir/cert.pem" >/dev/null 2>&1
  cat "$output_dir/cert.pem" "$output_dir/ca.pem" > "$output_dir/fullchain.pem"
}
```

- [ ] **Step 2: Write failing inspection tests**

Create `tests/check-cert.test.sh`. Generate a 31-day matching certificate, a 30-day matching certificate, and a wrong-host certificate. Assert:

```bash
result=$(scripts/check-cert.sh "$tmp/valid/fullchain.pem" "$domain")
assert_eq "false" "$(jq -r .renewal_required <<<"$result")"
assert_eq "valid" "$(jq -r .reason <<<"$result")"

result=$(scripts/check-cert.sh "$tmp/threshold/fullchain.pem" "$domain")
assert_eq "true" "$(jq -r .renewal_required <<<"$result")"
assert_eq "renewal-threshold" "$(jq -r .reason <<<"$result")"

result=$(scripts/check-cert.sh "$tmp/wrong/fullchain.pem" "$domain")
assert_eq "true" "$(jq -r .renewal_required <<<"$result")"
assert_eq "hostname-mismatch" "$(jq -r .reason <<<"$result")"

result=$(scripts/check-cert.sh "$tmp/missing.pem" "$domain")
assert_eq "missing" "$(jq -r .reason <<<"$result")"
```

Set `CHECK_NOW_EPOCH` to one second after the 31-day certificate's `notAfter` value and assert `expired=true`, `currently_valid=false`, and `reason=expired`. Write random text to a PEM file and assert `reason=parse-error`.

- [ ] **Step 3: Run the test and confirm the missing-script failure**

Run: `bash tests/check-cert.test.sh`

Expected: FAIL because `scripts/check-cert.sh` does not exist.

- [ ] **Step 4: Implement `scripts/check-cert.sh`**

Parse the two positional arguments, use `openssl x509 -checkhost`, parse `notBefore` and `notAfter` with GNU `date`, calculate floor days remaining, and emit JSON through `jq -n`. Use `CHECK_NOW_EPOCH=${CHECK_NOW_EPOCH:-$(date -u +%s)}`. Apply decision precedence in this order: missing, parse-error, hostname-mismatch, not-yet-valid, expired, renewal-threshold, valid.

The successful JSON shape must be:

```bash
jq -n \
  --argjson parseable "$parseable" \
  --argjson hostname_valid "$hostname_valid" \
  --argjson currently_valid "$currently_valid" \
  --argjson expired "$expired" \
  --argjson days_remaining "$days_remaining" \
  --argjson renewal_required "$renewal_required" \
  --arg reason "$reason" \
  '{parseable:$parseable,hostname_valid:$hostname_valid,currently_valid:$currently_valid,expired:$expired,days_remaining:$days_remaining,renewal_required:$renewal_required,reason:$reason}'
```

- [ ] **Step 5: Run focused tests**

Run: `bash tests/check-cert.test.sh`

Expected: PASS with a final `check-cert tests passed` line.

- [ ] **Step 6: Commit the inspection unit**

```bash
git add scripts/check-cert.sh tests/helpers.sh tests/check-cert.test.sh
git commit -m "feat: inspect certificate renewal state"
```

---

### Task 2: Atomic public status generation

**Files:**
- Create: `tests/generate-status.test.sh`
- Create: `scripts/generate-status.sh`
- Create: `docs/cert-status.json`
- Create: `docs/certificate.pem`

**Interfaces:**
- Consumes: `scripts/generate-status.sh CERTIFICATE_PATH OUTPUT_PATH DOMAIN [STATUS_OVERRIDE] [RENEWAL_ISO]`.
- Consumes: optional `STATUS_NOW` ISO-8601 value for deterministic tests.
- Produces: the exact public JSON schema from the design, written through a same-directory temporary file and atomic `mv`.

- [ ] **Step 1: Write failing status tests**

Create `tests/generate-status.test.sh`. Generate matching 31-day and 30-day chains, set `fixed_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)` and `STATUS_NOW=$fixed_now`, and assert all keys exist:

```bash
scripts/generate-status.sh "$tmp/valid/fullchain.pem" "$tmp/status.json" "$domain"
jq -e --arg now "$fixed_now" '
  .domain == "valoutils-tools.windowsed.me" and
  .status == "valid" and
  (.issuer | length > 0) and
  (.valid_from | endswith("Z")) and
  (.valid_until | endswith("Z")) and
  (.days_remaining | type == "number") and
  (.fingerprint_sha256 | test("^([0-9A-F]{2}:){31}[0-9A-F]{2}$")) and
  .last_checked == $now and
  .last_renewal == ""
' "$tmp/status.json"
```

Run it again with renewal value `2026-08-09T14:40:00Z`, then without that argument, and assert the second run preserves the prior renewal value. Assert a 30-day certificate yields `renewal-soon`, a clock after `notAfter` yields `expired`, and override `error` yields `error` while retaining any parseable metadata.

- [ ] **Step 2: Run the status test and confirm failure**

Run: `bash tests/generate-status.test.sh`

Expected: FAIL because `scripts/generate-status.sh` does not exist.

- [ ] **Step 3: Implement status generation**

Use `openssl x509` for issuer, start date, end date, and SHA-256 fingerprint. Convert OpenSSL dates with `date -u -d "$value" +%Y-%m-%dT%H:%M:%SZ`. Read the existing renewal value safely:

```bash
previous_renewal=""
if [[ -s "$output_path" ]] && jq -e . "$output_path" >/dev/null 2>&1; then
  previous_renewal=$(jq -r '.last_renewal // ""' "$output_path")
fi
last_renewal=${renewal_iso:-$previous_renewal}
```

Write JSON with `jq -n`, create the temporary file inside `dirname "$output_path"`, validate it with `jq -e`, and move it over the destination. For a missing or malformed certificate, emit empty issuer/date/fingerprint fields, `days_remaining=0`, and status `error` unless an explicit status override was supplied.

- [ ] **Step 4: Add initial public files**

Create an empty tracked `docs/certificate.pem`. Generate `docs/cert-status.json` with the domain, empty certificate fields, `days_remaining: 0`, `status: "error"`, and empty timestamps so Pages has valid JSON before the first workflow run.

- [ ] **Step 5: Run focused tests and validate initial JSON**

Run: `bash tests/generate-status.test.sh && jq -e . docs/cert-status.json`

Expected: PASS and jq exits 0.

- [ ] **Step 6: Commit the status unit**

```bash
git add scripts/generate-status.sh tests/generate-status.test.sh docs/cert-status.json docs/certificate.pem
git commit -m "feat: generate public certificate status"
```

---

### Task 3: Safe Certbot renewal and encrypted PFX delivery

**Files:**
- Create: `tests/renew-cert.test.sh`
- Create: `scripts/renew-cert.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: `scripts/renew-cert.sh DOMAIN PUBLIC_CERT_PATH ENCRYPTED_PFX_PATH`.
- Consumes environment variables `CF_API_TOKEN`, `LETSENCRYPT_EMAIL`, and `PFX_AGE_RECIPIENT`.
- Invokes `certbot` and `age` from `PATH`, which lets tests provide controlled fakes.
- Produces: validated public full chain at `PUBLIC_CERT_PATH`, encrypted PFX at `ENCRYPTED_PFX_PATH`, and one `last_renewal=<UTC ISO-8601>` line on stdout.

- [ ] **Step 1: Write a fake Certbot and failing renewal test**

Create `tests/renew-cert.test.sh`. Generate a valid chain, then put test binaries in `$tmp/bin`. The fake `certbot` parses `--config-dir` and copies the fixture to `live/$domain/{cert,chain,fullchain,privkey}.pem`. The fake `age` parses `-o` and copies its input to the requested encrypted output while recording the recipient. Prepend `$tmp/bin` to `PATH`, export non-secret test values, run renewal, and assert:

```bash
assert_file_exists "$tmp/public.pem"
assert_file_exists "$tmp/certificate.pfx.age"
assert_eq "2" "$(grep -c 'BEGIN CERTIFICATE' "$tmp/public.pem")"
grep -q '^last_renewal=.*Z$' "$tmp/renewal.out"
grep -q '^age1testrecipient$' "$tmp/age-recipient.txt"
```

Replace fake Certbot output with a wrong-SAN chain and assert renewal fails, the pre-existing public certificate checksum stays unchanged, and no encrypted artifact exists. Repeat the private-key mismatch case with an unrelated key, then repeat with a leaf-only `fullchain.pem`.

- [ ] **Step 2: Run the renewal test and confirm failure**

Run: `bash tests/renew-cert.test.sh`

Expected: FAIL because `scripts/renew-cert.sh` does not exist.

- [ ] **Step 3: Implement temporary credential and Certbot execution**

Validate the three required environment variables before creating files. Use `mktemp -d`, a cleanup trap, and `umask 077`. Write:

```bash
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$work_dir/cloudflare.ini"
chmod 600 "$work_dir/cloudflare.ini"
certbot certonly --non-interactive --agree-tos --email "$LETSENCRYPT_EMAIL" \
  --preferred-challenges dns-01 --authenticator dns-cloudflare \
  --dns-cloudflare-credentials "$work_dir/cloudflare.ini" \
  --dns-cloudflare-propagation-seconds 60 \
  --config-dir "$work_dir/config" --work-dir "$work_dir/work" \
  --logs-dir "$work_dir/logs" --cert-name "$domain" -d "$domain"
```

Do not add `--force-renewal`; the workflow owns the renewal decision and each temporary Certbot directory has no renewal state.

- [ ] **Step 4: Implement certificate, chain, key, EKU, and PFX validation**

Require all four Certbot outputs. Validate SAN with `openssl x509 -checkhost "$domain"`, current validity with both epoch bounds, at least two `BEGIN CERTIFICATE` blocks in `fullchain.pem`, and server-auth EKU with:

```bash
openssl x509 -in "$cert" -noout -ext extendedKeyUsage | grep -Eq 'TLS Web Server Authentication|serverAuth'
```

Hash both public keys in DER form and compare them:

```bash
cert_key_hash=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
private_key_hash=$(openssl pkey -in "$private_key" -pubout -outform DER | openssl dgst -sha256)
[[ "$cert_key_hash" == "$private_key_hash" ]]
```

Create and reopen the PFX:

```bash
openssl pkcs12 -export -inkey "$private_key" -in "$cert" -certfile "$chain" \
  -out "$raw_pfx" -name "$domain" -passout pass:
openssl pkcs12 -in "$raw_pfx" -passin pass: -info -noout >/dev/null
```

Encrypt with `age -r "$PFX_AGE_RECIPIENT" -o "$encrypted_tmp" "$raw_pfx"`. Move the encrypted result and public full chain into place only after every validation passes. Print the renewal timestamp. The cleanup trap removes all private material.

- [ ] **Step 5: Add repository exclusions**

Create `.gitignore` with:

```gitignore
*.key
*.pfx
*.p12
privkey.pem
.certbot/
.tmp/
cloudflare.ini
node_modules/
```

The `.pfx.age` suffix remains allowed because it contains ciphertext, but the workflow uploads it without committing it.

- [ ] **Step 6: Run renewal and tracked-secret tests**

Run:

```bash
bash tests/renew-cert.test.sh
git ls-files | grep -E '\.(pfx|p12|key)$|(^|/)privkey\.pem$' && exit 1 || true
```

Expected: renewal tests pass and the tracked-secret scan prints nothing.

- [ ] **Step 7: Commit the renewal unit**

```bash
git add scripts/renew-cert.sh tests/renew-cert.test.sh .gitignore
git commit -m "feat: renew certificate with encrypted PFX output"
```

---

### Task 4: Responsive GitHub Pages status site

**Files:**
- Create: `package.json`
- Create: `tests/site.test.js`
- Create: `docs/index.html`
- Create: `docs/style.css`
- Create: `docs/script.js`
- Create: `docs/.nojekyll`

**Interfaces:**
- `statusViewModel(data, error = null) -> { state, label, fields, message }` is exported from `docs/script.js` for Node tests.
- `formatTaipei(iso) -> string` is exported and returns `Not available` for empty or invalid input.
- Browser bootstrap fetches `./cert-status.json?ts=<milliseconds>` with `{cache: "no-store"}`.

- [ ] **Step 1: Write failing frontend contract tests**

Create `package.json` with `"type": "module"` and `"test:site": "node --test tests/site.test.js"`. In `tests/site.test.js`, import Node's `test`, `assert`, and file APIs. Assert:

```js
assert.equal(statusViewModel({ status: "valid", days_remaining: 89 }).label, "Valid");
assert.equal(statusViewModel({ status: "renewal-soon" }).label, "Renewal due");
assert.equal(statusViewModel(null, new Error("offline")).state, "error");
assert.match(formatTaipei("2026-08-10T04:40:00Z"), /UTC\+8/);
assert.equal(formatTaipei(""), "Not available");
```

Read `docs/index.html` and assert it includes IDs for domain, status, issuer, valid-from, expiry, days, fingerprint, last-check, and last-renewal. Read CSS and assert it includes `prefers-color-scheme: dark`, a mobile media query, and selectors for all four status classes.

- [ ] **Step 2: Run the site test and confirm failure**

Run: `node --test tests/site.test.js`

Expected: FAIL because the site files do not exist.

- [ ] **Step 3: Implement the data model and browser renderer**

Export a `STATE_LABELS` map for `valid`, `renewal-soon`, `expired`, and `error`. `statusViewModel` must normalize absent fields to `Not available`, preserve numeric zero for days remaining, and return the unavailable message `Certificate status could not be loaded.` when passed an error.

Guard browser startup with `if (typeof document !== "undefined")`. Fetch with cache busting, update text via `textContent`, set the status element class to the allowlisted state, and catch failures into the unavailable model. Never insert fetched values through `innerHTML`.

- [ ] **Step 4: Implement semantic markup and responsive styling**

Build one header, a prominent status summary, and a responsive grid of definition-list cards. Include a direct public-certificate download link. Use CSS custom properties for light defaults and override them inside `@media (prefers-color-scheme: dark)`. Add `aria-live="polite"` to the status summary and visible focus styles to links.

- [ ] **Step 5: Run frontend tests**

Run: `node --test tests/site.test.js`

Expected: all frontend tests pass.

- [ ] **Step 6: Commit the site**

```bash
git add package.json tests/site.test.js docs/index.html docs/style.css docs/script.js docs/.nojekyll
git commit -m "feat: add certificate status page"
```

---

### Task 5: Scheduled renewal and Pages deployment workflow

**Files:**
- Create: `tests/workflow.test.js`
- Create: `.github/workflows/certificate.yml`
- Create: `tests/run.sh`
- Modify: `package.json`

**Interfaces:**
- Workflow triggers: daily cron `23 4 * * *` and manual boolean input `force_renew` defaulting to `false`.
- Repository configuration: secret `CF_API_TOKEN`; variables `LETSENCRYPT_EMAIL` and `PFX_AGE_RECIPIENT`.
- Certificate job output: Pages artifact plus optional `artifacts/valoutils-tools.windowsed.me.pfx.age`.
- Deploy job consumes the Pages artifact even when renewal reported an error.

- [ ] **Step 1: Write failing workflow contract tests**

Create `tests/workflow.test.js` and read the YAML as text. Assert exact presence of the schedule, `workflow_dispatch`, false force default, `permissions`, `concurrency`, the three scripts, guarded renewal, bot identity, non-empty-commit check, seven-day encrypted artifact, `actions/configure-pages@v5`, `actions/upload-pages-artifact@v4`, and `actions/deploy-pages@v4`. Extract the cron minute and assert `minute !== "0"`.

- [ ] **Step 2: Add the complete test runner**

Create executable `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
bash tests/check-cert.test.sh
bash tests/generate-status.test.sh
bash tests/renew-cert.test.sh
node --test tests/site.test.js tests/workflow.test.js
```

Set package scripts to `"test": "bash tests/run.sh"` and `"test:site": "node --test tests/site.test.js"`.

- [ ] **Step 3: Run workflow tests and confirm failure**

Run: `node --test tests/workflow.test.js`

Expected: FAIL because `.github/workflows/certificate.yml` does not exist.

- [ ] **Step 4: Implement triggers, permissions, and inspection**

Create `.github/workflows/certificate.yml` with `contents: write` on the certificate job and `contents: read`, `pages: write`, and `id-token: write` on the deployment job. Use `actions/checkout@v6`, `actions/setup-python@v6` with Python 3.12, run `bash tests/run.sh`, inspect the certificate, and write `renew` plus `reason` to `$GITHUB_OUTPUT`. Set renewal true when the JSON says so or the dispatch input equals true.

- [ ] **Step 5: Implement conditional issuance and failure-safe status**

Install `certbot==5.7.0`, `certbot-dns-cloudflare==5.7.0`, and `age` only when renewal is required. Run renewal with `continue-on-error: true` and the three secret/variable values in its step environment. Generate status as follows:

```bash
if [[ "${{ steps.inspect.outputs.renew }}" == "true" ]]; then
  if [[ "${{ steps.renew.outcome }}" == "success" ]]; then
    renewal_iso=$(sed -n 's/^last_renewal=//p' artifacts/renewal.out)
    scripts/generate-status.sh docs/certificate.pem docs/cert-status.json "$DOMAIN" "" "$renewal_iso"
  else
    scripts/generate-status.sh docs/certificate.pem docs/cert-status.json "$DOMAIN" error
  fi
else
  scripts/generate-status.sh docs/certificate.pem docs/cert-status.json "$DOMAIN"
fi
```

Upload only `artifacts/valoutils-tools.windowsed.me.pfx.age` with `actions/upload-artifact@v7`, `if-no-files-found: error`, and `retention-days: 7` after successful renewal.

- [ ] **Step 6: Implement bot commit and Pages artifact upload**

Configure `github-actions[bot]` and `41898282+github-actions[bot]@users.noreply.github.com`. Stage only the two public output files. Choose commit text based on renewal success, skip when `git diff --cached --quiet`, and retry `git pull --rebase` plus `git push` up to three times.

Run `actions/configure-pages@v5` and `actions/upload-pages-artifact@v4` with `path: docs`. Place a final failure step after upload:

```yaml
- name: Report renewal failure
  if: steps.inspect.outputs.renew == 'true' && steps.renew.outcome == 'failure'
  run: exit 1
```

- [ ] **Step 7: Implement a failure-tolerant Pages deploy job**

Set `needs: certificate`, `if: always() && needs.certificate.result != 'cancelled'`, environment `github-pages`, and deploy through `actions/deploy-pages@v4`. This lets the page publish the new `error` state while the certificate job remains visibly failed.

- [ ] **Step 8: Run workflow and full local tests**

Run: `bash tests/run.sh`

Expected: every shell and Node test passes.

- [ ] **Step 9: Commit automation**

```bash
git add .github/workflows/certificate.yml tests/workflow.test.js tests/run.sh package.json
git commit -m "feat: automate certificate renewal and Pages deployment"
```

---

### Task 6: Operator documentation and final security verification

**Files:**
- Create: `README.md`
- Modify: `.gitignore`
- Test: all files in repository

**Interfaces:**
- Documents repository setup, Cloudflare scope, Pages source, manual and forced runs, encrypted PFX download/decryption, and recovery behavior.
- Produces a repository ready to push as its own `main` branch.

- [ ] **Step 1: Write the README acceptance checklist first**

Create a temporary checklist in the implementation notes and verify the final README contains exact strings for `CF_API_TOKEN`, `LETSENCRYPT_EMAIL`, `PFX_AGE_RECIPIENT`, `Zone → DNS → Edit`, `force_renew`, `30 days`, `DNS-01`, `docs/certificate.pem`, `docs/cert-status.json`, `.pfx.age`, `age --decrypt`, and `GitHub Actions` as the Pages source.

- [ ] **Step 2: Write the operator README**

Explain the data flow and setup in this order:

1. Generate an age identity locally with `age-keygen -o age-identity.txt` and obtain its recipient with `age-keygen -y age-identity.txt`.
2. Create a zone-scoped Cloudflare token with DNS edit permission.
3. Add the secret and two repository variables.
4. Select GitHub Actions under Settings → Pages.
5. Run the Certificate Status workflow without force for initial issuance.
6. Download the seven-day `.pfx.age` Actions artifact and decrypt locally with `age --decrypt -i age-identity.txt -o valoutils-tools.windowsed.me.pfx valoutils-tools.windowsed.me.pfx.age`.

State that the decrypted PFX has an empty password, contains a private key, and must remain outside Git, Pages, chat, and ordinary file sharing. Cover daily checks, the threshold, force behavior, failure status, artifact expiry, and how to rotate the age recipient.

- [ ] **Step 3: Run documentation and secret scans**

Run:

```bash
for value in CF_API_TOKEN LETSENCRYPT_EMAIL PFX_AGE_RECIPIENT force_renew DNS-01 docs/certificate.pem docs/cert-status.json .pfx.age; do
  grep -Fq "$value" README.md || { echo "README missing $value"; exit 1; }
done
git ls-files | grep -E '\.(pfx|p12|key)$|(^|/)privkey\.pem$' && exit 1 || true
grep -RInE --exclude='*.md' 'dns_cloudflare_api_token[[:space:]]*=[[:space:]]*[A-Za-z0-9_-]{20,}' . && exit 1 || true
```

Expected: all README checks pass and both secret scans print nothing.

- [ ] **Step 4: Run complete verification**

Run:

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/run.sh
jq -e . docs/cert-status.json
git diff --check
git status --short
```

Expected: syntax checks, tests, JSON validation, and whitespace checks pass. Only the intended README or plan changes remain before the final commit.

- [ ] **Step 5: Commit documentation and normalize the branch name**

```bash
git add README.md .gitignore docs/superpowers/plans/2026-08-10-certificate-status.md
git commit -m "docs: add certificate status setup guide"
git branch -M main
```

- [ ] **Step 6: Record live setup limits for handoff**

Do not attempt issuance without the repository secret and variables. Report that the user must create and push the GitHub repository, configure `CF_API_TOKEN`, `LETSENCRYPT_EMAIL`, and `PFX_AGE_RECIPIENT`, select GitHub Actions as the Pages source, and trigger the first manual run. The first run must replace the initial empty public certificate with a validated Let's Encrypt full chain.
