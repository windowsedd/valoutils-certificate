# Raw PFX Artifact Implementation Plan

> **For AI agent workers:** Required sub-skill: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Track progress with checkbox (`- [ ]`) syntax.

**Goal:** Create and retain a raw `localhostCert.pfx` Actions artifact for 60 days whenever no usable PFX artifact exists.

**Architecture:** Change the renewal script from an age-encrypted output contract to a validated raw-PFX output contract. Add an Actions API lookup before inspection and combine its result with the existing certificate/force checks. Keep private material restricted to the runner and Actions artifact storage.

**Tech stack:** Bash, OpenSSL, GitHub Actions YAML, Node.js test runner

---

## Files

- Modify `scripts/renew-cert.sh`: produce a validated raw PFX at the requested output path.
- Modify `tests/renew-cert.test.sh`: specify and verify the raw-output contract.
- Modify `.github/workflows/certificate.yml`: detect the artifact, trigger issuance when absent, and upload it for 60 days.
- Modify `tests/workflow.test.js`: specify artifact detection and raw upload behavior.
- Modify `README.md`: document the raw artifact workflow and access risk.
- Modify `tests/readme.test.js`: enforce the new documentation contract.

### Task 1: Raw PFX renewal output

- [ ] Update `tests/renew-cert.test.sh` to call `scripts/renew-cert.sh` with `localhostCert.pfx`, remove the fake `age` command and recipient, assert that OpenSSL opens the output with an empty password, and retain the SAN/key/chain failure cases.
- [ ] Run `bash tests/renew-cert.test.sh` and confirm it fails because the current script requires `PFX_AGE_RECIPIENT` and emits encrypted output.
- [ ] Update `scripts/renew-cert.sh` to atomically move the validated raw PFX to the requested output path without invoking age.
- [ ] Run `bash tests/renew-cert.test.sh` and confirm it passes.

### Task 2: Missing-artifact workflow trigger

- [ ] Update `tests/workflow.test.js` to require `actions: read`, `actions/github-script`, the exact artifact name lookup, an `artifact-missing` renewal reason, `artifacts/localhostCert.pfx`, 60-day retention, and no `PFX_AGE_RECIPIENT` or `.pfx.age` path.
- [ ] Run `node --test tests/workflow.test.js` and confirm the new assertions fail against the old workflow.
- [ ] Update `.github/workflows/certificate.yml` to query unexpired artifacts, feed the result into inspection, install no age package, create `artifacts/localhostCert.pfx`, and upload it for 60 days after successful issuance.
- [ ] Run `node --test tests/workflow.test.js` and confirm it passes.

### Task 3: Documentation and full verification

- [ ] Update `tests/readme.test.js` to require `localhostCert.pfx`, `60 days`, and the Actions-access warning while rejecting age setup instructions.
- [ ] Run `node --test tests/readme.test.js` and confirm the new assertions fail.
- [ ] Rewrite the relevant `README.md` setup, security, and download sections for the raw PFX artifact.
- [ ] Run `bash tests/run.sh` and confirm the complete suite passes.
- [ ] Run `git status --short` and `git diff --check`; verify no `.pfx`, `.p12`, `.key`, or private-key file is tracked.
- [ ] Commit the implementation with `git commit -m "feat: create raw PFX artifact when missing"`.
