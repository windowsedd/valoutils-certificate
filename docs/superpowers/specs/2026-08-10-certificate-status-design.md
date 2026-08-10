# ValoUtils certificate status repository design

## Goal

Create a separate GitHub repository that publishes the TLS certificate status for `valoutils-tools.windowsed.me` and renews the certificate through Let's Encrypt before it expires. GitHub Pages serves the public status site. GitHub Actions performs daily and manual checks, uses Cloudflare DNS-01 for issuance, commits public status updates, and deploys the site.

The domain may resolve to `127.0.0.1`, so the system must not use HTTP-01 validation.

## Repository layout

The repository will use these top-level paths:

```text
.
├── .github/workflows/certificate.yml
├── docs/
│   ├── index.html
│   ├── style.css
│   ├── script.js
│   ├── cert-status.json
│   └── certificate.pem
├── scripts/
│   ├── check-cert.sh
│   ├── renew-cert.sh
│   └── generate-status.sh
├── tests/
├── .gitignore
└── README.md
```

`docs/certificate.pem` starts as an empty tracked file. The first workflow run treats it as missing or invalid and requests the initial certificate.

## Repository configuration

The owner configures these GitHub settings:

- Secret `CF_API_TOKEN`: a Cloudflare API token scoped to the required zone with `Zone:DNS:Edit` permission.
- Variable `LETSENCRYPT_EMAIL`: the Let's Encrypt account and expiry-notice email address.
- Variable `PFX_AGE_RECIPIENT`: the public `age` recipient used to encrypt the generated PFX.
- GitHub Pages source: GitHub Actions.

GitHub supplies `GITHUB_TOKEN`. The workflow grants it only the permissions required to commit public files and deploy Pages.

## Certificate inspection

`scripts/check-cert.sh` accepts the certificate path and expected hostname. It uses OpenSSL to determine whether the file:

- contains a parseable X.509 certificate;
- is currently within its validity period;
- contains `valoutils-tools.windowsed.me` in the SAN extension; and
- has more than 30 full days remaining.

The script emits machine-readable fields for the workflow and status generator. It requests renewal when the certificate is absent, malformed, expired, hostname-mismatched, or has 30 days or less remaining. A manual run with `force_renew=true` also requests renewal. A normal manual run follows the same rules as a scheduled run.

## Renewal and validation

`scripts/renew-cert.sh` creates a temporary working directory and a temporary Cloudflare credentials file with mode `0600`. The file contains `CF_API_TOKEN`, and the script does not echo its contents. Certbot and `certbot-dns-cloudflare` request a production Let's Encrypt certificate for the single hostname. The plugin creates and removes the `_acme-challenge` TXT record.

The script validates every result before changing tracked files:

1. OpenSSL parses the leaf certificate and full chain.
2. The leaf SAN contains the exact hostname.
3. The certificate is currently valid.
4. The chain contains the leaf and at least one issuer certificate.
5. The public key derived from the private key matches the certificate public key.
6. OpenSSL creates a PKCS#12 file with the private key, full chain, hostname alias, and an empty internal password.
7. OpenSSL reopens the PFX with an empty password and verifies its certificate and key material.

Only then does the script replace `docs/certificate.pem` with the public full chain. It encrypts the raw PFX to `PFX_AGE_RECIPIENT`, deletes the raw PFX and private key material, and leaves the encrypted artifact for upload. The workflow retains the encrypted artifact for a short period.

## Status data

`scripts/generate-status.sh` writes `docs/cert-status.json` atomically. The JSON schema is:

```json
{
  "domain": "valoutils-tools.windowsed.me",
  "issuer": "Let's Encrypt",
  "valid_from": "2026-08-09T14:38:50Z",
  "valid_until": "2026-11-07T14:38:50Z",
  "days_remaining": 89,
  "status": "valid",
  "fingerprint_sha256": "9F:78:0C:81:D3:12:CC:61:18:4B:1D:47:C2:88:95:87:04:56:02:77:2E:68:16:75:8A:12:BC:77:E7:55:9A:30",
  "last_checked": "2026-08-10T04:40:00Z",
  "last_renewal": "2026-08-09T14:40:00Z"
}
```

The generator stores timestamps in UTC ISO-8601 form. It preserves the previous `last_renewal` value when a check does not renew the certificate and replaces it only after a successful renewal.

Status values follow these rules:

- `valid`: certificate has more than 30 days remaining.
- `renewal-soon`: certificate has 30 days or less remaining and renewal has not succeeded.
- `expired`: certificate validity has ended.
- `error`: parsing, validation, or renewal failed.

The workflow regenerates the file on every run, including checks that do not renew.

## Workflow and deployment

`.github/workflows/certificate.yml` runs once per day at a non-round minute and supports `workflow_dispatch`. The dispatch input `force_renew` is a boolean with a default of `false`.

The workflow performs these steps:

1. Check out the default branch and install the pinned runtime dependencies.
2. Inspect the tracked public certificate.
3. Renew only when the inspection or dispatch input requires it.
4. Generate status from the old certificate when no renewal occurs or from the validated new certificate after renewal.
5. Upload the encrypted PFX artifact after a successful renewal.
6. Commit `docs/certificate.pem` and `docs/cert-status.json` when their content changes, using the `github-actions[bot]` identity.
7. Upload the public site as a GitHub Pages artifact and deploy it in a dependent Pages job.

A concurrency group serializes runs. The push step rebases or retries safely if the default branch changes while the job runs. The workflow does not create empty commits.

If renewal fails, the workflow keeps the prior public certificate, writes an `error` status while preserving the prior renewal timestamp, commits and deploys that status, and then exits with failure. This ordering makes the public page report the failure while the Actions run still alerts maintainers.

## Website

The dependency-free site uses HTML, CSS, and JavaScript. JavaScript fetches `cert-status.json` with cache busting and renders:

- domain;
- certificate status;
- issuer;
- valid-from date;
- expiration date;
- days remaining;
- SHA-256 fingerprint;
- last check; and
- last successful renewal.

The JSON stays in UTC. The browser formats timestamps for `Asia/Taipei` and labels the timezone as UTC+8. CSS follows the operating-system light or dark preference, uses accessible contrast, and provides distinct green, amber, and red status treatments. A failed JSON request displays an unavailable state rather than empty certificate fields.

## Security controls

The repository must ignore raw PFX files, PKCS#12 files, private keys, Certbot state, and temporary credentials. Tests and workflow checks scan tracked files for forbidden private material.

The raw PFX has an empty password because the consuming application requires it. The empty password provides no protection. The workflow exposes the PFX only inside its temporary directory, encrypts it with `age`, and uploads only the encrypted form. The repository owner keeps the matching `age` identity outside GitHub and decrypts the downloaded artifact locally.

The public `certificate.pem`, certificate metadata, and `age` recipient contain no secret material and may be published.

## Tests and acceptance criteria

Local tests generate temporary certificates and do not contact Cloudflare or Let's Encrypt. They cover:

- valid matching certificate;
- missing and malformed certificate inputs;
- expired certificate;
- wrong SAN;
- renewal decisions above, below, and exactly at 30 days;
- private-key mismatch;
- status JSON generation and renewal timestamp preservation;
- empty-password PFX creation and reopening; and
- frontend rendering and unavailable-data behavior.

Before handoff, local verification checks shell syntax, runs the test suite, inspects the workflow structure, and scans tracked files for private keys or raw PFX data. Live issuance and Pages publication require the user to push the repository, configure its secret and variables, select GitHub Actions as the Pages source, and run the workflow.
