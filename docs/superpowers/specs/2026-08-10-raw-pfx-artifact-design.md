# Public PFX Design

## Goal

Make the certificate workflow create an initial empty-password PFX when no usable PFX exists and publish it first at `https://windowsedd.github.io/valoutils-certificate/valoutils/localhost.pfx` through GitHub Pages. A custom Pages domain can be wired later.

## Workflow behavior

Before certificate inspection, the workflow attempts to download the currently published PFX into `docs/valoutils/localhost.pfx`. It verifies that the file is a readable empty-password PKCS#12 bundle. Certificate issuance is required when the public certificate needs renewal, a manual run requests forced renewal, or the published PFX is missing or invalid.

After successful issuance, the renewal script writes `docs/valoutils/localhost.pfx` with an empty password and validates its certificate chain and private key. The Pages deployment includes that file at `/valoutils/localhost.pfx`. Git continues to track only the public PEM and status JSON, so the PFX does not enter Git history.

## Security and failure handling

The raw PFX contains the TLS private key and is intentionally public. Anyone can download and reuse it. It must not be staged by Git, but it is intentionally copied into the temporary Pages deployment. If issuance fails while a previously published PFX was downloaded successfully, the workflow retains that PFX in the Pages deployment; otherwise the URL remains unavailable.

## Tests

Shell tests verify raw PFX creation, its empty password, its certificate chain, and failure cleanup. Workflow tests verify public-PFX download, missing-PFX issuance, the Pages path, and the absence of age encryption or PFX artifact configuration. README tests verify the public URL and security warning.
