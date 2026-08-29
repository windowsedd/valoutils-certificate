#!/usr/bin/env bash
# Repository-state verification for the certificate project.
#
# Checks the live state of the repository (not synthetic fixtures; the test
# suite in tests/ does that): script syntax, line endings, ignore rules,
# public certificate, private key match, PFX, status JSON, and the workflow.
#
# usage: scripts/verify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOMAIN="valoutils-tools.windowsed.me"
PUBLIC_CERT="$BASE_DIR/docs/certificate.pem"
STATUS_JSON="$BASE_DIR/docs/cert-status.json"
PFX_FILE="$BASE_DIR/pfx-output/$DOMAIN.pfx"
LIVE_DIR="$BASE_DIR/letsencrypt/config/live/$DOMAIN"

failures=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

run_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

# 1. Shell scripts parse and use LF line endings.
script_ok=true
for script in "$BASE_DIR"/scripts/*.sh "$BASE_DIR"/tests/*.sh; do
  bash -n "$script" 2>/dev/null || script_ok=false
  if grep -q $'\r' "$script" 2>/dev/null; then
    script_ok=false
    fail "CRLF line endings in $script"
  fi
done
if [[ "$script_ok" == true ]]; then
  pass "Shell scripts pass bash -n and use LF endings"
fi

for text_file in "$BASE_DIR/.github/workflows/certificate.yml" "$BASE_DIR/README.md" \
  "$BASE_DIR"/docs/index.html "$BASE_DIR"/docs/style.css "$BASE_DIR"/docs/script.js; do
  run_check "LF endings in ${text_file##*/}" bash -c "! grep -q \$'\r' '$text_file'"
done

# 2. Private material and generated state are ignored by Git.
for ignored in ".secrets/cloudflare.ini" "letsencrypt/config/live/x/privkey.pem" \
  "pfx-output/$DOMAIN.pfx" "docs/valoutils/localhost.pfx" \
  "docs/cert-status.json" "secret.key" "secret.pfx"; do
  run_check "Git ignores $ignored" git -C "$BASE_DIR" check-ignore -q "$ignored"
done

run_check "No tracked private key or PFX files" \
  bash -c "! git -C '$BASE_DIR' ls-files | grep -Eq '(^|/)(privkey\.pem|.*\.(key|pfx|p12))$'"

run_check "No tracked Certbot state" \
  bash -c "! git -C '$BASE_DIR' ls-files | grep -Eq '(^|/)letsencrypt/'"

# 3. GitHub Pages contains no secret material beyond the intentional PFX.
if grep -rq 'PRIVATE KEY' "$BASE_DIR/docs" --include='*.pem' --include='*.json' \
  --include='*.js' --include='*.html' --include='*.css' 2>/dev/null; then
  fail "docs/ contains private key material outside the PFX bundle"
else
  pass "GitHub Pages contains no private key material outside the PFX bundle"
fi
run_check "No PFX tracked by Git" \
  bash -c "! git -C '$BASE_DIR' ls-files | grep -q '\.pfx$'"

# 4. Public certificate.
if [[ -s "$PUBLIC_CERT" ]]; then
  run_check "Public certificate parses" openssl x509 -in "$PUBLIC_CERT" -noout
  if openssl x509 -in "$PUBLIC_CERT" -noout -ext subjectAltName 2>/dev/null \
    | grep -Eq "DNS: *$DOMAIN"; then
    pass "Public certificate SAN contains $DOMAIN"
  else
    fail "Public certificate SAN does not contain $DOMAIN"
  fi
  if openssl x509 -in "$PUBLIC_CERT" -noout -issuer 2>/dev/null | grep -q "Let's Encrypt"; then
    pass "Public certificate issuer is Let's Encrypt"
  else
    fail "Public certificate issuer is not Let's Encrypt"
  fi
  run_check "Public certificate is not expired" \
    openssl x509 -in "$PUBLIC_CERT" -noout -checkend 0
  if openssl x509 -in "$PUBLIC_CERT" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
    pass "Public certificate has more than 30 days remaining"
  else
    fail "Public certificate is within the 30-day renewal window"
  fi
else
  printf 'SKIP: %s\n' "Public certificate checks ($PUBLIC_CERT is empty; run certificate.sh first)"
fi

# 5. Private key matches the certificate (local Certbot state only).
if [[ -s "$LIVE_DIR/cert.pem" && -s "$LIVE_DIR/privkey.pem" ]]; then
  cert_digest=$(openssl x509 -in "$LIVE_DIR/cert.pem" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256)
  key_digest=$(openssl pkey -in "$LIVE_DIR/privkey.pem" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256)
  if [[ "$cert_digest" == "$key_digest" ]]; then
    pass "Private key matches the live certificate"
  else
    fail "Private key does not match the live certificate"
  fi
else
  printf 'SKIP: %s\n' "Private key match ($LIVE_DIR has no local state; normal on CI)"
fi

# 6. PFX opens with an empty password and contains the key.
if [[ -s "$PFX_FILE" ]]; then
  run_check "PFX opens with an empty password" \
    openssl pkcs12 -in "$PFX_FILE" -passin pass: -info -noout
  run_check "PFX contains a private key" \
    bash -c "openssl pkcs12 -in '$PFX_FILE' -passin pass: -nocerts -nodes 2>/dev/null | openssl pkey -noout"
  run_check "PFX passes full validation" "$SCRIPT_DIR/check-pfx.sh" "$PFX_FILE" "$DOMAIN"
else
  printf 'SKIP: %s\n' "PFX checks ($PFX_FILE not generated yet)"
fi

# 7. Status JSON is valid.
if [[ -s "$STATUS_JSON" ]]; then
  run_check "cert-status.json is valid JSON" python -m json.tool "$STATUS_JSON"
  if python -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for key in ("domain", "status", "issuer", "valid_from", "valid_until",
            "days_remaining", "fingerprint_sha256", "san", "key_algorithm",
            "last_checked", "last_renewal"):
    assert key in data, key
' "$STATUS_JSON" >/dev/null 2>&1; then
    pass "cert-status.json contains every documented field"
  else
    fail "cert-status.json is missing documented fields"
  fi
else
  printf 'SKIP: %s\n' "Status JSON checks ($STATUS_JSON not generated yet)"
fi

# 8. Workflow sanity.
workflow="$BASE_DIR/.github/workflows/certificate.yml"
run_check "Workflow has a non-round daily cron" \
  grep -Eq 'cron: *["'"'"'][1-5]?[0-9] [1-5] \* \* \*["'"'"']' "$workflow"
run_check "Workflow calls scripts/certificate.sh" grep -q "scripts/certificate.sh" "$workflow"
run_check "Workflow uses the Cloudflare token secret" \
  grep -q 'CF_API_TOKEN: *\${{ secrets.CF_API_TOKEN }}' "$workflow"
run_check "Workflow restores and republishes the PFX" \
  bash -c "grep -q 'Restore published PFX' '$workflow' && grep -q 'Publish renewed PFX' '$workflow' && grep -q 'scripts/check-pfx.sh' '$workflow'"
run_check "Workflow commits only the public certificate" \
  bash -c "grep -q 'git add docs/certificate.pem' '$workflow' && ! grep -Eq 'git add[^#]*cert-status' '$workflow'"

printf '\n'
if (( failures > 0 )); then
  printf '%d verification check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All repository-state verification checks passed\n'
