# Raw PFX Artifact Design

## Goal

Make the certificate workflow create an initial empty-password PFX when no current PFX Actions artifact exists. Store the PFX only as a GitHub Actions artifact for 60 days; never commit it or include it in GitHub Pages.

## Workflow behavior

Before certificate inspection, the workflow queries the repository's unexpired Actions artifacts for the exact name `valoutils-tools-windowsed-me-pfx`. This requires read-only `actions` permission. Certificate issuance is required when the public certificate needs renewal, a manual run requests forced renewal, or no matching PFX artifact exists.

After successful issuance, the renewal script writes `artifacts/localhostCert.pfx` with an empty password and validates its certificate chain and private key. The workflow uploads that raw file with 60-day retention. Existing matching artifacts may remain until GitHub expires them; the existence check succeeds when at least one unexpired artifact is available.

## Security and failure handling

The raw PFX contains the TLS private key. Anyone able to read repository Actions artifacts can download it. It must not be staged by Git, copied into `docs/`, or exposed through GitHub Pages. If issuance fails, the workflow preserves the previous public certificate, publishes an error status, and uploads no PFX.

## Tests

Shell tests verify raw PFX creation, its empty password, its certificate chain, and failure cleanup. Workflow tests verify artifact discovery, missing-artifact issuance, the raw filename, 60-day retention, and the absence of age encryption configuration. README tests verify setup and download instructions match the raw artifact workflow.
