#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
source tests/helpers.sh

domain="valoutils-localhost.windowsed.me"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_chain "$tmp/fresh" "$domain" 60
make_chain "$tmp/old" "$domain" 20
make_chain "$tmp/quiet" "$domain" 40
make_chain "$tmp/wrong" "wrong.windowsed.me" 60
make_chain "$tmp/unrelated" "$domain" 60
mkdir -p "$tmp/bin"

cat > "$tmp/bin/certbot" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

config_dir=""
credentials=""
domain=""
key_type=""
force_renewal=false
args=("$@")
for arg in "${args[@]}"; do
  case "$arg" in
    --force-renewal) force_renewal=true ;;
  esac
done
while (($#)); do
  case "$1" in
    --config-dir) config_dir="$2"; shift 2 ;;
    --dns-cloudflare-credentials) credentials="$2"; shift 2 ;;
    --cert-name) domain="$2"; shift 2 ;;
    --key-type) key_type="$2"; shift 2 ;;
    -d) domain="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -n "$config_dir" && -n "$credentials" && -n "$domain" ]] || exit 1
[[ "$key_type" == "rsa" ]] || exit 1
if [[ "${CERTBOT_REQUIRE_FORCE_RENEWAL:-0}" == "1" && "$force_renewal" != true ]]; then
  exit 1
fi
if [[ -n "${CERTBOT_FAIL:-}" ]]; then
  exit 1
fi

mkdir -p "$config_dir/live/$domain"
cp "$FAKE_CERT_SOURCE" "$config_dir/live/$domain/cert.pem"
cp "$FAKE_CHAIN_SOURCE" "$config_dir/live/$domain/chain.pem"
cp "$FAKE_FULLCHAIN_SOURCE" "$config_dir/live/$domain/fullchain.pem"
cp "${CERTBOT_KEY_SOURCE:-$FAKE_KEY_SOURCE}" "$config_dir/live/$domain/privkey.pem"
printf '%s\n' "${args[*]}" > "$FAKE_RECORD_DIR/args.txt"
printf '%s\n' "$credentials" > "$FAKE_RECORD_DIR/credentials-path.txt"
stat -c '%a' "$credentials" > "$FAKE_RECORD_DIR/credentials-mode.txt"
touch "$FAKE_RECORD_DIR/certbot-called"
BASH

chmod +x "$tmp/bin/certbot"

seed_live() {
  local base="$1"
  local source_dir="$2"
  local live="$base/letsencrypt/config/live/$domain"
  mkdir -p "$live" "$base/docs"
  cp "$source_dir/cert.pem" "$live/cert.pem"
  cp "$source_dir/ca.pem" "$live/chain.pem"
  cp "$source_dir/fullchain.pem" "$live/fullchain.pem"
  cp "$source_dir/privkey.pem" "$live/privkey.pem"
}

run_certificate() {
  local base="$1"
  shift
  FAKE_CERT_SOURCE="${FAKE_CERT_SOURCE:-$tmp/fresh/cert.pem}" \
  FAKE_CHAIN_SOURCE="${FAKE_CHAIN_SOURCE:-$tmp/fresh/ca.pem}" \
  FAKE_FULLCHAIN_SOURCE="${FAKE_FULLCHAIN_SOURCE:-$tmp/fresh/fullchain.pem}" \
  FAKE_KEY_SOURCE="${FAKE_KEY_SOURCE:-$tmp/fresh/privkey.pem}" \
  FAKE_RECORD_DIR="$tmp" \
  CERTIFICATE_BASE_DIR="$base" \
  CF_API_TOKEN="${CF_API_TOKEN:-test-cloudflare-token}" \
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-operator@example.com}" \
  PATH="$tmp/bin:$PATH" \
    scripts/certificate.sh "$@"
}

# Case 1: nothing exists anywhere; the script issues a new certificate.
base="$tmp/case-issue"
run_certificate "$base" > "$base.out" 2>&1
assert_file_exists "$base/docs/certificate.pem"
cmp -s "$base/docs/certificate.pem" "$tmp/fresh/fullchain.pem" \
  || fail "issued public certificate is not the new full chain"
assert_file_exists "$base/pfx-output/$domain.pfx"
openssl pkcs12 -in "$base/pfx-output/$domain.pfx" -passin pass: -info -noout >/dev/null 2>&1 \
  || fail "issued PFX cannot be reopened with an empty password"
assert_eq "2" "$(openssl pkcs12 -in "$base/pfx-output/$domain.pfx" -passin pass: -nokeys 2>/dev/null | grep -c 'BEGIN CERTIFICATE')" "issued PFX chain length"
[[ -e "$tmp/certbot-called" ]] || fail "certbot was not invoked for the missing certificate"
status_json=$(<"$base/docs/cert-status.json")
assert_eq "valid" "$(json_get "$status_json" status)" "issued status"
python -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); assert data["san"] == [sys.argv[2]], data["san"]' \
  "$base/docs/cert-status.json" "$domain" || fail "issued status SAN list is wrong"
credentials_path=$(<"$tmp/credentials-path.txt")
[[ ! -e "$credentials_path" ]] || fail "temporary Cloudflare credentials were not removed"
assert_eq "600" "$(<"$tmp/credentials-mode.txt")" "Cloudflare credential mode"

# Case 2: a fresh public certificate and no Certbot state; nothing happens.
base="$tmp/case-keep"
mkdir -p "$base/docs"
cp "$tmp/quiet/fullchain.pem" "$base/docs/certificate.pem"
public_hash=$(openssl dgst -sha256 "$base/docs/certificate.pem")
rm -f "$tmp/certbot-called"
run_certificate "$base" > "$base.out" 2>&1
[[ ! -e "$tmp/certbot-called" ]] || fail "certbot ran even though the certificate is not due"
assert_eq "$public_hash" "$(openssl dgst -sha256 "$base/docs/certificate.pem")" "keep-path public certificate"
[[ ! -e "$base/pfx-output/$domain.pfx" ]] || fail "keep-path without a private key generated a PFX"
assert_eq "valid" "$(json_get "$(<"$base/docs/cert-status.json")" status)" "keep-path status"

# Case 3: a 20-day live certificate is inside the 30-day window; renews.
base="$tmp/case-renew"
seed_live "$base" "$tmp/old"
cp "$tmp/old/fullchain.pem" "$base/docs/certificate.pem"
rm -f "$tmp/certbot-called"
run_certificate "$base" > "$base.out" 2>&1
[[ -e "$tmp/certbot-called" ]] || fail "certbot was not invoked inside the renewal window"
cmp -s "$base/docs/certificate.pem" "$tmp/fresh/fullchain.pem" \
  || fail "renewal did not publish the new full chain"
assert_file_exists "$base/pfx-output/$domain.pfx"
assert_eq "valid" "$(json_get "$(<"$base/docs/cert-status.json")" status)" "renewed status"
last_renewal=$(json_get "$(<"$base/docs/cert-status.json")" last_renewal)
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$last_renewal" \
  || fail "renewed status has no renewal timestamp"

# Case 4: --force-renew on a perfectly valid certificate forces issuance.
base="$tmp/case-force"
seed_live "$base" "$tmp/fresh"
cp "$tmp/fresh/fullchain.pem" "$base/docs/certificate.pem"
rm -f "$tmp/certbot-called" "$tmp/args.txt"
CERTBOT_REQUIRE_FORCE_RENEWAL=1 run_certificate "$base" --force-renew > "$base.out" 2>&1
[[ -e "$tmp/certbot-called" ]] || fail "forced renewal did not invoke certbot"
grep -q -- '--force-renewal' "$tmp/args.txt" || fail "forced renewal did not pass --force-renewal to certbot"

# Case 5: certbot failure keeps the old public certificate and fails the run.
base="$tmp/case-fail"
seed_live "$base" "$tmp/old"
cp "$tmp/old/fullchain.pem" "$base/docs/certificate.pem"
public_hash=$(openssl dgst -sha256 "$base/docs/certificate.pem")
rm -f "$tmp/certbot-called"
if CERTBOT_FAIL=1 run_certificate "$base" > "$base.out" 2>&1; then
  fail "certbot failure unexpectedly succeeded"
fi
assert_eq "$public_hash" "$(openssl dgst -sha256 "$base/docs/certificate.pem")" "failed renewal public certificate"
assert_eq "renewal-soon" "$(json_get "$(<"$base/docs/cert-status.json")" status)" "failed renewal status"

# Case 6: a wrong-SAN issuance fails validation and is not published.
base="$tmp/case-san"
seed_live "$base" "$tmp/old"
cp "$tmp/old/fullchain.pem" "$base/docs/certificate.pem"
public_hash=$(openssl dgst -sha256 "$base/docs/certificate.pem")
if FAKE_CERT_SOURCE="$tmp/wrong/cert.pem" \
   FAKE_CHAIN_SOURCE="$tmp/wrong/ca.pem" \
   FAKE_FULLCHAIN_SOURCE="$tmp/wrong/fullchain.pem" \
   run_certificate "$base" > "$base.out" 2>&1; then
  fail "wrong-SAN issuance unexpectedly succeeded"
fi
assert_eq "$public_hash" "$(openssl dgst -sha256 "$base/docs/certificate.pem")" "wrong-SAN public certificate"
[[ ! -e "$base/pfx-output/$domain.pfx" ]] || fail "wrong-SAN issuance produced a PFX"

# Case 7: a mismatched private key fails validation and is not published.
base="$tmp/case-key"
seed_live "$base" "$tmp/old"
cp "$tmp/old/fullchain.pem" "$base/docs/certificate.pem"
public_hash=$(openssl dgst -sha256 "$base/docs/certificate.pem")
if CERTBOT_KEY_SOURCE="$tmp/unrelated/privkey.pem" \
   run_certificate "$base" > "$base.out" 2>&1; then
  fail "mismatched-key issuance unexpectedly succeeded"
fi
assert_eq "$public_hash" "$(openssl dgst -sha256 "$base/docs/certificate.pem")" "mismatched-key public certificate"

# Case 8: missing Cloudflare credentials fail with a clear error before certbot.
base="$tmp/case-creds"
rm -f "$tmp/certbot-called"
if CF_API_TOKEN="" LETSENCRYPT_EMAIL="operator@example.com" \
  CERTIFICATE_BASE_DIR="$base" PATH="$tmp/bin:$PATH" \
  FAKE_RECORD_DIR="$tmp" \
  FAKE_CERT_SOURCE="$tmp/fresh/cert.pem" \
  FAKE_CHAIN_SOURCE="$tmp/fresh/ca.pem" \
  FAKE_FULLCHAIN_SOURCE="$tmp/fresh/fullchain.pem" \
  FAKE_KEY_SOURCE="$tmp/fresh/privkey.pem" \
  scripts/certificate.sh > "$base.out" 2>&1; then
  fail "missing credentials unexpectedly succeeded"
fi
[[ ! -e "$tmp/certbot-called" ]] || fail "certbot ran without Cloudflare credentials"
grep -q "Cloudflare credentials are required" "$base.out" \
  || fail "missing-credential error message is missing"

printf 'certificate tests passed\n'
