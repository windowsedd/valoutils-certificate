# ValoUtils Certificate Status

This repository publishes the TLS certificate status for `valoutils-tools.windowsed.me` through GitHub Pages. A daily GitHub Actions workflow checks the stored public certificate and renews it through Let's Encrypt when 3 days or fewer remain.

The hostname may resolve to `127.0.0.1`. Certificate issuance therefore uses Cloudflare DNS-01 and does not depend on an HTTP server at the hostname.

## How it works

The workflow runs every day at 04:23 UTC and can also be started manually. Each run:

1. Reads `docs/certificate.pem` with OpenSSL.
2. Checks parsing, validity, SAN, and remaining lifetime.
3. Renews through Certbot and Cloudflare DNS-01 when required.
4. Validates the new chain, TLS server-auth usage, private-key match, and PFX.
5. Writes the public full chain to `docs/certificate.pem` only after validation succeeds.
6. Regenerates `docs/cert-status.json` on every run.
7. Commits changed public files with the `github-actions[bot]` identity.
8. Deploys `docs/` through GitHub Pages.

The status site displays the domain, state, issuer, validity dates, days remaining, SHA-256 fingerprint, last check, and last successful renewal. JSON timestamps use UTC ISO-8601. The browser displays them in Asia/Taipei time.

## Repository setup

### 1. Create an age identity

Install [age](https://github.com/FiloSottile/age) on your computer, then generate an identity that never leaves your machine:

```bash
age-keygen -o age-identity.txt
age-keygen -y age-identity.txt
```

The second command prints a public recipient beginning with `age1`. Keep `age-identity.txt` private and backed up. Anyone who loses that identity cannot decrypt later PFX artifacts.

### 2. Create the Cloudflare token

Create a restricted Cloudflare API token with:

- Permission: `Zone → DNS → Edit`
- Zone resource: only the zone containing `windowsed.me`

Do not use the Cloudflare Global API Key.

### 3. Configure GitHub

In the repository settings, add:

| Type | Name | Value |
| --- | --- | --- |
| Actions secret | `CF_API_TOKEN` | Restricted Cloudflare token |
| Actions variable | `LETSENCRYPT_EMAIL` | Let's Encrypt account email |
| Actions variable | `PFX_AGE_RECIPIENT` | Public `age1...` recipient |

Under **Settings → Pages → Build and deployment**, choose **GitHub Actions** as the source.

The workflow uses GitHub's automatic `GITHUB_TOKEN`. Repository Actions settings must allow workflows to create commits with that token.

### 4. Push and issue the first certificate

The repository starts with an empty `docs/certificate.pem`. Push the repository, open **Actions → Certificate Status**, and run the workflow. Leave `force_renew` disabled for the initial run; the missing certificate already triggers issuance.

After the run succeeds, GitHub Pages publishes the current status and public certificate chain.

## Renewal rules

Renewal starts when any condition is true:

- 3 days or fewer remain.
- The certificate is missing, expired, malformed, or not currently valid.
- The SAN does not match `valoutils-tools.windowsed.me`.
- A manual run sets `force_renew` to `true`.

A normal manual run does not force renewal. It follows the same checks as the daily schedule.

If renewal fails, the workflow keeps the previous public certificate, publishes an `error` status, deploys that status to Pages, and marks the Actions run as failed.

## Public and private files

These files are public and safe for GitHub Pages:

- `docs/certificate.pem`: public leaf certificate and Let's Encrypt chain.
- `docs/cert-status.json`: public certificate metadata and check timestamps.

The workflow creates a PFX containing the private key, hostname certificate, and full chain. The PFX has an empty password because the consuming application requires one. An empty password does not protect the private key.

The raw PFX and private key exist only in the workflow's temporary directory. The workflow encrypts the PFX to `PFX_AGE_RECIPIENT`, uploads only the `.pfx.age` file as a seven-day Actions artifact, and removes the temporary material. Never commit or publish the decrypted PFX, private key, age identity, or Cloudflare token.

## Download and decrypt the PFX

After a successful renewal:

1. Open the successful workflow run in GitHub Actions.
2. Download the `valoutils-tools-windowsed-me-pfx` artifact.
3. Extract `valoutils-tools.windowsed.me.pfx.age` locally.
4. Decrypt it with your private age identity:

```bash
age --decrypt \
  -i age-identity.txt \
  -o valoutils-tools.windowsed.me.pfx \
  valoutils-tools.windowsed.me.pfx.age
```

Move the decrypted PFX directly into its protected application location. Delete extra copies after use. The encrypted GitHub artifact expires after seven days.

## Local tests

The tests generate temporary local certificates and use fake Certbot and age commands. They never contact Let's Encrypt or Cloudflare.

On Linux, macOS, or Git Bash for Windows, run:

```bash
bash tests/run.sh
```

The live issuance path can only run after the GitHub secret and variables are configured.

## Status values

| Status | Meaning |
| --- | --- |
| `valid` | More than 3 days remain. |
| `renewal-soon` | 3 days or fewer remain and renewal has not succeeded. |
| `expired` | The certificate validity period has ended. |
| `error` | Inspection, validation, or renewal failed. |
