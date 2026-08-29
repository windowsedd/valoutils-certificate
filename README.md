# ValoUtils Certificate

Automated Let's Encrypt TLS certificate management for `valoutils-tools.windowsed.me`, with a public GitHub Pages status dashboard.

The hostname can resolve to `127.0.0.1` (the ValoUtils desktop app serves local TLS on it), so certificates are always issued through **Cloudflare DNS-01** — never HTTP-01. A daily GitHub Actions workflow checks the current certificate, renews it through Let's Encrypt when it enters the 30-day renewal window, generates an empty-password PFX, and publishes the public certificate and live status to GitHub Pages.

## How it works

`scripts/certificate.sh` is the single entry point for the whole lifecycle:

```text
Locate project root (repo-relative paths only)
  ↓
Check for usable Certbot state in letsencrypt/config/live/
  ↓ (no usable state? decide from the committed docs/certificate.pem)
Certificate missing / broken / expired / <= 30 days remaining?
  ├── yes → issue or renew via Certbot + Cloudflare DNS-01
  │         (validate chain, SAN, validity, EKU, key match before publishing)
  └── no  → keep the existing certificate
  ↓
Generate pfx-output/valoutils-tools.windowsed.me.pfx (empty password, verified)
  ↓
Update docs/certificate.pem (public chain only)
  ↓
Regenerate docs/cert-status.json
  ↓
DONE
```

Renewal is never unconditional: a certificate with more than 30 days left is left alone unless `--force-renew` is passed.

## Architecture

```text
.github/workflows/certificate.yml   daily automation (schedule + manual dispatch)
.secrets/cloudflare.ini             local Cloudflare token (gitignored, you create it)
letsencrypt/                        local Certbot state: config/, work/, logs/ (gitignored)
pfx-output/                         local PFX output (gitignored)
scripts/certificate.sh              inspect / issue / renew / PFX / public files
scripts/generate-status.sh          builds docs/cert-status.json
scripts/check-cert.sh               certificate inspection primitive (JSON result)
scripts/check-pfx.sh                PFX validation primitive (empty password, chain, SAN, key)
scripts/verify.sh                   repository-state verification checklist
docs/                               GitHub Pages: dashboard + public certificate + status
tests/                              offline test suite (fake Certbot, no network)
```

### Design decisions

- **Repo-relative storage.** All Certbot state lives in `letsencrypt/{config,work,logs}` inside the repository, resolved from the script location — the current working directory never matters.
- **CI reissues instead of persisting private ACME state.** Runners are ephemeral and storing unencrypted private keys in Git is not acceptable, so CI keeps no Certbot state at all: the committed `docs/certificate.pem` (public only) is the persistent state, and a due renewal is simply a fresh DNS-01 issuance. This is the simplest secure option; no encrypted state blobs to rotate or recover.
- **`cert-status.json` is deployed, not committed.** The workflow regenerates the status on every run and ships it to Pages inside the deployment artifact. Git history only records meaningful certificate changes (issuances/renewals), not a daily `last_checked` churn commit.
- **The PFX is published but never committed.** The workflow includes the PFX in the GitHub Pages deployment (gitignored, so it never enters repository history) so the ValoUtils app can download it from a stable URL. Between renewals, CI restores the previously published PFX from that URL and republishes it; a missing or invalid published PFX forces a renewal, because producing a PFX requires the private key, which CI only has right after an issuance.

## Local prerequisites

Linux, WSL, or Git Bash for Windows (GNU coreutils required):

- `bash`, GNU `date`/`grep`/`sed`
- `openssl` 1.1.1 or 3.x
- `python3`
- `certbot` + `certbot-dns-cloudflare` (e.g. `python -m pip install certbot certbot-dns-cloudflare`)
- Node.js (only for the test suite)

## Cloudflare setup

Create a restricted Cloudflare API token:

- Permission: `Zone → DNS → Edit`
- Zone resource: only the zone containing `windowsed.me`

Do not use the Cloudflare Global API Key. The token is stored as `dns_cloudflare_api_token = <token>` and is never printed by any script.

### Local credentials: `.secrets/cloudflare.ini`

```bash
mkdir -p .secrets
cat > .secrets/cloudflare.ini <<'EOF'
dns_cloudflare_api_token = YOUR_CLOUDFLARE_TOKEN
EOF
chmod 600 .secrets/cloudflare.ini
```

`.secrets/` is gitignored. Never commit this file.

### CI credentials: `CF_API_TOKEN`

In the GitHub repository settings add:

| Type | Name | Value |
| --- | --- | --- |
| Actions secret | `CF_API_TOKEN` | Restricted Cloudflare token |
| Actions variable | `LETSENCRYPT_EMAIL` | Let's Encrypt account email |

The workflow writes the secret into a temporary credentials file at runtime (mode `600`), passes it to Certbot, and deletes it afterwards. Under **Settings → Pages → Build and deployment**, choose **GitHub Actions** as the source.

## Usage

### Initial certificate creation

```bash
scripts/certificate.sh
```

The script requires `CF_API_TOKEN` (or `.secrets/cloudflare.ini`) and prefers `LETSENCRYPT_EMAIL` for the Let's Encrypt account registration. Certbot state is created under `letsencrypt/`, the PFX under `pfx-output/`, and the public files under `docs/`.

### Certificate checking

```bash
scripts/certificate.sh          # prints the current status and refreshes docs/
scripts/verify.sh               # repository-state verification checklist
bash tests/run.sh               # offline test suite
```

### Automatic renewal

The workflow runs daily at 04:23 UTC (`cron: "23 4 * * *"`). Each run re-generates the status, renews only when the certificate is missing, broken, expired, or within 30 days of expiry, commits the public certificate only if it changed, and deploys Pages (including the fresh status) even when the check merely confirms the certificate is fine.

### Manual renewal / check

Run the workflow from the **Actions** tab with `force_renew` enabled to force a renewal, or locally:

```bash
scripts/certificate.sh --force-renew
```

## PFX generation

`scripts/certificate.sh` always generates `pfx-output/valoutils-tools.windowsed.me.pfx` from the current certificate and private key:

- empty password (`-passout pass:`)
- RSA 2048 private key included
- full Let's Encrypt chain included
- SAN `valoutils-tools.windowsed.me`, TLS server authentication

The bundle is verified with `scripts/check-pfx.sh` (opens with an empty password, chain verifies, SAN matches, key matches); a PFX failure fails the whole script. To re-verify an existing PFX:

```bash
scripts/check-pfx.sh pfx-output/valoutils-tools.windowsed.me.pfx valoutils-tools.windowsed.me
```

### PFX download

After the first successful issuance, the workflow publishes the PFX (gitignored, never committed) at:

```text
https://valoutils-tools.windowsed.me/valoutils/localhost.pfx
```

```bash
curl --fail --location --output localhost.pfx \
  https://valoutils-tools.windowsed.me/valoutils/localhost.pfx
```

The dashboard shows a **Download PFX** link once the file is live. On every run, CI restores the currently published PFX and republishes it, so the URL stays stable across renewals. If the download returns 404, no certificate has been issued yet — run the workflow once.

## GitHub Actions

`.github/workflows/certificate.yml` runs on a schedule and on manual dispatch:

1. Checkout, Python/Node setup, offline test suite.
2. Install `certbot` + `certbot-dns-cloudflare` (pinned).
3. Run `scripts/certificate.sh` with the `CF_API_TOKEN` secret; a failure is recorded but does not abort the run yet.
4. Commit `docs/certificate.pem` **only when it changed** (issuance/renewal), as `github-actions[bot]`.
5. Upload `docs/` as a Pages artifact (contains the freshly generated `cert-status.json`).
6. Fail the run visibly if the certificate step failed; the `deploy` job still publishes the updated status.

If renewal fails, the previous public certificate is kept, the status reflects the real state (`renewal-soon` while a still-valid certificate is in the window, `error` when inspection itself failed), and the Actions run is marked failed.

## GitHub Pages

Published from `docs/`:

- `index.html`, `style.css`, `script.js` — dashboard (dark/light, mobile friendly, no frameworks)
- `certificate.pem` — public leaf certificate + Let's Encrypt chain (safe to publish; contains no private key)
- `cert-status.json` — generated metadata, UTC ISO-8601 timestamps, rendered in Asia/Taipei by the dashboard
- `valoutils/localhost.pfx` — the PFX distribution copy (gitignored, never committed; present after the first successful issuance)

Status values: `valid` (> 30 days remaining), `renewal-soon` (inside the 30-day window without a successful renewal), `expired`, `error`.

## Security considerations

- The PFX contains the **private key with an empty password** and is downloadable by anyone from the Pages URL. This is an explicit project decision: the certificate exists for a loopback-oriented hostname and the app must be able to fetch it. Do not use this certificate to protect secrets or authenticate a public production service.
- The PFX is gitignored, so it never enters repository history; it is only included in the temporary Pages deployment.
- Public (committed/Pages): `docs/certificate.pem`, `docs/cert-status.json`, dashboard files, `valoutils/localhost.pfx`. Private (local only): `letsencrypt/`, `pfx-output/`, `.secrets/`.
- The Cloudflare token has `Zone → DNS → Edit` scope only, is passed to CI as a secret, is written to a `600` temp file at runtime, and is never printed or logged.

## Custom Certbot directory layout

```text
letsencrypt/
├── config/
│   ├── accounts/            Let's Encrypt account registration
│   └── live/valoutils-tools.windowsed.me/
│       ├── cert.pem         leaf certificate
│       ├── chain.pem        issuer chain
│       ├── fullchain.pem    leaf + chain (published to docs/certificate.pem)
│       └── privkey.pem      private key (local only)
├── work/
└── logs/
```

All paths are anchored to the repository root (`BASE_DIR` from the script location) and independent of both the current working directory and the system Certbot directory.

## Troubleshooting

- **Certificate not found** — No certificate exists until the first successful issuance. Run `scripts/certificate.sh` with credentials configured; check `letsencrypt/config/live/valoutils-tools.windowsed.me/`. On CI, confirm `CF_API_TOKEN` and `LETSENCRYPT_EMAIL` are configured; the failing step logs a precise reason.
- **`env: 'bash\r': No such file or directory` / CRLF** — Line endings were converted on checkout. `.gitattributes` forces LF; re-clone, or run `git config core.autocrlf false` and `git checkout -- .` (or `dos2unix scripts/*.sh`).
- **Cloudflare authentication failure** — Verify the token has `Zone → DNS → Edit` for the `windowsed.me` zone, that it has not expired, and that `cloudflare.ini` uses the exact key `dns_cloudflare_api_token`. Try the token against the Cloudflare API directly.
- **DNS propagation timeouts** — Certbot waits 30 seconds for the TXT record. Cloudflare DNS is normally fast; if your zone uses unusual settings, raise `--dns-cloudflare-propagation-seconds` in `scripts/certificate.sh` and retry.
- **Certbot renewal failure** — Read `letsencrypt/logs/letsencrypt.log`. Common causes: Let's Encrypt rate limits (5 duplicate certificates per week — after repeated failed attempts, wait before retrying), a corrupted local state directory (`rm -rf letsencrypt/` and run again), or a missing account email on first registration (`LETSENCRYPT_EMAIL`).
- **PFX generation failure** — The script fails if the bundle cannot be produced or verified. Check that `letsencrypt/config/live/.../privkey.pem` matches `cert.pem` (`scripts/verify.sh` reports this), that `openssl` supports PKCS#12 export, and run `scripts/check-pfx.sh` on any existing file to see the exact failure.
- **Renewal ran but Pages still shows old data** — Pages deploys even on failure; check the workflow's *Report certificate failure* step and the deployed `cert-status.json` status field.
