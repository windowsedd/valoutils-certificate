#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
source tests/helpers.sh

domain="valoutils-tools.windowsed.me"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_chain "$tmp/source" "$domain" 10
make_chain "$tmp/wrong" "wrong.windowsed.me" 10
make_chain "$tmp/unrelated" "$domain" 10
mkdir -p "$tmp/bin"

cat > "$tmp/bin/certbot" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
config_dir=""
credentials=""
domain=""
while (($#)); do
  case "$1" in
    --config-dir) config_dir="$2"; shift 2 ;;
    --dns-cloudflare-credentials) credentials="$2"; shift 2 ;;
    -d) domain="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$config_dir" && -n "$credentials" && -n "$domain" ]]
mkdir -p "$config_dir/live/$domain"
cp "$FAKE_CERT_SOURCE" "$config_dir/live/$domain/cert.pem"
cp "$FAKE_CHAIN_SOURCE" "$config_dir/live/$domain/chain.pem"
cp "$FAKE_FULLCHAIN_SOURCE" "$config_dir/live/$domain/fullchain.pem"
cp "$FAKE_KEY_SOURCE" "$config_dir/live/$domain/privkey.pem"
printf '%s\n' "$credentials" > "$FAKE_RECORD_DIR/credentials-path.txt"
stat -c '%a' "$credentials" > "$FAKE_RECORD_DIR/credentials-mode.txt"
BASH

chmod +x "$tmp/bin/certbot"

run_renewal() {
  FAKE_CERT_SOURCE="${FAKE_CERT_SOURCE:-$tmp/source/cert.pem}" \
  FAKE_CHAIN_SOURCE="${FAKE_CHAIN_SOURCE:-$tmp/source/ca.pem}" \
  FAKE_FULLCHAIN_SOURCE="${FAKE_FULLCHAIN_SOURCE:-$tmp/source/fullchain.pem}" \
  FAKE_KEY_SOURCE="${FAKE_KEY_SOURCE:-$tmp/source/privkey.pem}" \
  FAKE_RECORD_DIR="$tmp" \
  CF_API_TOKEN="test-cloudflare-token" \
  LETSENCRYPT_EMAIL="operator@example.com" \
  PATH="$tmp/bin:$PATH" \
    scripts/renew-cert.sh "$domain" "$1" "$2"
}

run_renewal "$tmp/public.pem" "$tmp/localhost.pfx" > "$tmp/renewal.out"
assert_file_exists "$tmp/public.pem"
assert_file_exists "$tmp/localhost.pfx"
assert_eq "2" "$(grep -c 'BEGIN CERTIFICATE' "$tmp/public.pem")" "public chain length"
grep -Eq '^last_renewal=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$tmp/renewal.out" \
  || fail "renewal timestamp output is missing"
assert_eq "600" "$(<"$tmp/credentials-mode.txt")" "Cloudflare credential mode"
credentials_path=$(<"$tmp/credentials-path.txt")
[[ ! -e "$credentials_path" ]] || fail "temporary Cloudflare credentials were not removed"
openssl pkcs12 -in "$tmp/localhost.pfx" -passin pass: -info -noout >/dev/null 2>&1 \
  || fail "generated PFX cannot be reopened with an empty password"
assert_eq "2" "$(openssl pkcs12 -in "$tmp/localhost.pfx" -passin pass: -nokeys 2>/dev/null | grep -c 'BEGIN CERTIFICATE')" "PFX chain length"

printf 'existing public certificate\n' > "$tmp/existing.pem"
existing_hash=$(openssl dgst -sha256 "$tmp/existing.pem")
if FAKE_CERT_SOURCE="$tmp/wrong/cert.pem" \
   FAKE_CHAIN_SOURCE="$tmp/wrong/ca.pem" \
   FAKE_FULLCHAIN_SOURCE="$tmp/wrong/fullchain.pem" \
   FAKE_KEY_SOURCE="$tmp/wrong/privkey.pem" \
   run_renewal "$tmp/existing.pem" "$tmp/wrong.pfx" >/dev/null 2>&1; then
  fail "wrong-SAN renewal unexpectedly succeeded"
fi
assert_eq "$existing_hash" "$(openssl dgst -sha256 "$tmp/existing.pem")" "wrong-SAN public certificate"
[[ ! -e "$tmp/wrong.pfx" ]] || fail "wrong-SAN PFX exists"

if FAKE_KEY_SOURCE="$tmp/unrelated/privkey.pem" \
   run_renewal "$tmp/existing.pem" "$tmp/mismatch.pfx" >/dev/null 2>&1; then
  fail "private-key mismatch unexpectedly succeeded"
fi
assert_eq "$existing_hash" "$(openssl dgst -sha256 "$tmp/existing.pem")" "mismatched-key public certificate"

if FAKE_FULLCHAIN_SOURCE="$tmp/source/cert.pem" \
   run_renewal "$tmp/existing.pem" "$tmp/leaf-only.pfx" >/dev/null 2>&1; then
  fail "leaf-only chain unexpectedly succeeded"
fi
assert_eq "$existing_hash" "$(openssl dgst -sha256 "$tmp/existing.pem")" "leaf-only public certificate"

printf 'renew-cert tests passed\n'
