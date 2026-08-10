# Public PFX Implementation Plan

> **For AI agent workers:** Required sub-skill: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Track progress with checkbox (`- [ ]`) syntax.

**Goal:** Create and publish `docs/valoutils/localhost.pfx` whenever the current public PFX is missing or invalid.

**Architecture:** Change the renewal script from an age-encrypted output contract to a validated raw-PFX output contract. At the start of a run, fetch the currently deployed PFX and combine its validation result with the existing certificate/force checks. Include the PFX in the Pages artifact while keeping it out of Git history.

**Tech stack:** Bash, OpenSSL, GitHub Actions YAML, Node.js test runner

---

## Files

- Modify `scripts/renew-cert.sh`: produce a validated raw PFX at the requested output path.
- Modify `tests/renew-cert.test.sh`: specify and verify the raw-output contract.
- Modify `.github/workflows/certificate.yml`: fetch the public PFX, trigger issuance when absent, and include it in Pages.
- Modify `tests/workflow.test.js`: specify public-PFX detection and Pages behavior.
- Modify `README.md`: document the raw artifact workflow and access risk.
- Modify `tests/readme.test.js`: enforce the new documentation contract.

### Task 1: Raw PFX renewal output

- [x] Update `tests/renew-cert.test.sh` to call `scripts/renew-cert.sh` with `localhost.pfx`, remove the fake `age` command and recipient, assert that OpenSSL opens the output with an empty password, and retain the SAN/key/chain failure cases.
- [x] Run `bash tests/renew-cert.test.sh` and confirm it fails because the current script requires `PFX_AGE_RECIPIENT` and emits encrypted output.
- [x] Update `scripts/renew-cert.sh` to atomically move the validated raw PFX to the requested output path without invoking age.
- [x] Run `bash tests/renew-cert.test.sh` and confirm it passes.

### Task 2: Missing-public-PFX workflow trigger

- [x] Update `tests/workflow.test.js` to require a download from `$PFX_URL`, strict PFX validation, a `pfx-missing` renewal reason, `docs/valoutils/localhost.pfx`, and no `PFX_AGE_RECIPIENT`, `.pfx.age`, or PFX Actions artifact.
- [x] Run `node --test tests/workflow.test.js` and confirm the new assertions fail against the old workflow.
- [x] Add `scripts/check-pfx.sh` with behavioral tests, then update `.github/workflows/certificate.yml` to fetch and validate the deployed PFX, feed the result into inspection, create `docs/valoutils/localhost.pfx`, and include it in the Pages upload.
- [x] Run `node --test tests/workflow.test.js` and the PFX shell tests, and confirm they pass.

### Task 3: Documentation and full verification

- [x] Update `tests/readme.test.js` to require the exact public URL, `localhost.pfx`, and the public-private-key warning while rejecting age and PFX artifact instructions.
- [x] Run `node --test tests/readme.test.js` and confirm the new assertions fail.
- [x] Rewrite the relevant `README.md` setup, security, and download sections for the raw PFX artifact.
- [x] Run `bash tests/run.sh` and confirm the complete suite passes.
- [x] Run `git status --short` and `git diff --check`; verify no `.pfx`, `.p12`, `.key`, or private-key file is tracked.
- [x] Commit the implementation with `git commit -m "feat: publish PFX when missing"`.
