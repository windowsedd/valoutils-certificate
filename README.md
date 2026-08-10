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

### 1. Create the Cloudflare token

Create a restricted Cloudflare API token with:

- Permission: `Zone → DNS → Edit`
- Zone resource: only the zone containing `windowsed.me`

Do not use the Cloudflare Global API Key.

### 2. Configure GitHub

In the repository settings, add:

| Type | Name | Value |
| --- | --- | --- |
| Actions secret | `CF_API_TOKEN` | Restricted Cloudflare token |
| Actions variable | `LETSENCRYPT_EMAIL` | Let's Encrypt account email |

Under **Settings → Pages → Build and deployment**, choose **GitHub Actions** as the source.

The workflow uses GitHub's automatic `GITHUB_TOKEN`. Repository Actions settings must allow workflows to create commits with that token.

### 3. Push and issue the first certificate

The repository starts with an empty `docs/certificate.pem`. Push the repository, open **Actions → Certificate Status**, and run the workflow. Leave `force_renew` disabled for the initial run; the missing certificate already triggers issuance.

After the run succeeds, GitHub Pages publishes the current status, certificate chain, and PFX.

## Renewal rules

Renewal starts when any condition is true:

- 3 days or fewer remain.
- The certificate is missing, expired, malformed, or not currently valid.
- The SAN does not match `valoutils-tools.windowsed.me`.
- The published PFX is missing, expired, malformed, or has the wrong SAN.
- A manual run sets `force_renew` to `true`.

A normal manual run does not force renewal. It follows the same checks as the daily schedule.

If renewal fails, the workflow keeps the previous public certificate, publishes an `error` status, deploys that status to Pages, and marks the Actions run as failed.

## Published files

These files are public and safe for GitHub Pages:

- `docs/certificate.pem`: public leaf certificate and Let's Encrypt chain.
- `docs/cert-status.json`: public certificate metadata and check timestamps.

The workflow also publishes `docs/valoutils/localhost.pfx` at:

`https://windowsedd.github.io/valoutils-certificate/valoutils/localhost.pfx`

The PFX contains the private key, hostname certificate, and full chain. It has an empty password because the consuming application requires one. Anyone can download and reuse this private key. Publishing it is an explicit project decision; do not use this certificate to protect secrets or authenticate a public production service.

The PFX is included in the temporary GitHub Pages deployment but ignored by Git, so it does not enter repository history. The Cloudflare token remains a GitHub Actions secret and must never be published.

## Download the PFX

```bash
curl --fail --location \
  --output localhost.pfx \
  https://windowsedd.github.io/valoutils-certificate/valoutils/localhost.pfx
```

The application can use this URL directly as its PFX download source.

## Local tests

The tests generate temporary local certificates and use a fake Certbot command. They never contact Let's Encrypt or Cloudflare.

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
